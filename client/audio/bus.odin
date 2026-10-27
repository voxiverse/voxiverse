package audio

import "core:math"

// Buses: a tree the voices play into. Master <- Music, Ambience, Effects
// (<- World, Player, UI). Each has a gain, a mute, a low-pass, and a level
// that snapshots and ducking move; all of them are smoothed (a block of at
// most MAX_BLOCK frames at a time, linearly across it), so nothing clicks.
//
// The enum is the order buses are processed in (leaves first), so a bus is
// complete when the one it feeds is processed; a duck's trigger must come
// before its target.
Bus :: enum u8 {
	World, // sounds out in the world: blocks, creatures, blasts (the zero value)
	Player, // what the player does: steps, landings, hits
	UI,
	Effects,
	Ambience,
	Music,
	Master,
}

@(rodata)
BUS_PARENT := [Bus]Bus {
	.World    = .Effects,
	.Player   = .Effects,
	.UI       = .Effects,
	.Effects  = .Master,
	.Ambience = .Master,
	.Music    = .Master,
	.Master   = .Master,
}

@(private)
Bus_State :: struct {
	gain:       f32, // wanted (the user's slider)
	gain_now:   f32,
	mute:       bool,
	snap:       f32, // the snapshot's gain, wanted
	snap_now:   f32,
	snap_step:  f32, // per frame
	duck_now:   f32,
	level:      f32, // the product applied at the end of the last block
	cutoff:     f32, // Hz of the low-pass, wanted (open: no filter)
	cutoff_now: f32,
	cut_tau:    f32, // seconds
	open:       f32,
	filter:     [2]Svf,
	peak:       f32, // of the last block, after the gain
	send:       f32, // wanted level of this bus into the reverb
	send_now:   f32,
}

// Duck: while the trigger bus is louder than the threshold (linear peak) the
// target bus is lowered to `amount` times its level, reaching it in `attack`
// seconds and coming back in `release`.
Duck :: struct {
	active:    bool,
	trigger:   Bus,
	target:    Bus,
	threshold: f32,
	amount:    f32,
	attack:    f32,
	release:   f32,
	held:      f32, // where the envelope is (mixer state)
}

// Snapshot: bus settings crossfaded in together (Underwater, Paused,
// Death, Loading). cutoff 0 is open.
Snapshot :: struct {
	gain:   [Bus]f32,
	cutoff: [Bus]f32,
}

// snapshot_neutral changes nothing.
snapshot_neutral :: proc() -> (s: Snapshot) {
	for b in Bus {s.gain[b] = 1}
	return
}

@(private)
Bus_Cmd :: struct {
	bus:    Bus,
	which:  enum u8 {
		Gain,
		Mute,
		Cutoff,
		Send,
	},
	value:  f32,
	frames: u32,
}

@(private)
Duck_Cmd :: struct {
	index: int,
	duck:  Duck,
}

@(private)
Snapshot_Cmd :: struct {
	snap:   Snapshot,
	frames: u32,
}

// QUICK: seconds for a bus gain to move across its whole range.
@(private)
QUICK :: 0.02

@(private)
bus_defaults :: proc "contextless" (b: ^Bus_State, rate: f32) {
	b^ = {
		gain       = 1,
		gain_now   = 1,
		snap       = 1,
		snap_now   = 1,
		snap_step  = 1 / (QUICK * rate),
		duck_now   = 1,
		level      = 1,
		open       = rate / 2.2,
		cutoff     = rate / 2.2,
		cutoff_now = rate / 2.2,
		cut_tau    = 0.005,
	}
}

set_bus_gain :: proc(m: ^Mixer, bus: Bus, gain: f32, at: u64 = 0) {
	push(m, Bus_Cmd{bus, .Gain, clamp(gain, 0, 4), 0}, at)
}

set_bus_mute :: proc(m: ^Mixer, bus: Bus, mute: bool, at: u64 = 0) {
	push(m, Bus_Cmd{bus, .Mute, 1 if mute else 0, 0}, at)
}

// set_bus_cutoff: Hz of the bus's low-pass; 0 opens it.
set_bus_cutoff :: proc(m: ^Mixer, bus: Bus, hz: f32, at: u64 = 0) {
	push(m, Bus_Cmd{bus, .Cutoff, hz, 0}, at)
}

// set_bus_reverb: how much of the bus goes to the reverb (0 none, 1 as loud
// as the bus). The reverb's return joins Master.
set_bus_reverb :: proc(m: ^Mixer, bus: Bus, send: f32, at: u64 = 0) {
	push(m, Bus_Cmd{bus, .Send, clamp(send, 0, 4), 0}, at)
}

// set_duck defines duck rule `index` (0 ..< MAX_DUCKS).
set_duck :: proc(m: ^Mixer, index: int, d: Duck, at: u64 = 0) {
	assert(index >= 0 && index < MAX_DUCKS && d.trigger < d.target)
	push(m, Duck_Cmd{index, d}, at)
}

// set_snapshot crossfades the buses to a snapshot over `over` seconds.
set_snapshot :: proc(m: ^Mixer, s: Snapshot, over: f32, at: u64 = 0) {
	push(m, Snapshot_Cmd{s, seconds(m, over)}, at)
}

@(private)
bus_command :: proc "contextless" (m: ^Mixer, c: Bus_Cmd) {
	b := &m.buses[c.bus]
	switch c.which {
	case .Gain:
		b.gain = c.value
	case .Mute:
		b.mute = c.value != 0
	case .Cutoff:
		b.cutoff = c.value if c.value > 0 else b.open
		b.cut_tau = 0.005
	case .Send:
		b.send = c.value
	}
}

@(private)
apply_snapshot :: proc "contextless" (m: ^Mixer, c: Snapshot_Cmd) {
	for &b, i in m.buses {
		bus := Bus(i)
		b.snap = c.snap.gain[bus]
		if c.frames == 0 {
			b.snap_now = b.snap
		} else {
			b.snap_step = abs(b.snap - b.snap_now) / f32(c.frames)
		}
		b.cutoff = c.snap.cutoff[bus] if c.snap.cutoff[bus] > 0 else b.open
		b.cut_tau = max(0.005, f32(c.frames) / f32(m.rate) / 4)
	}
}

@(private)
approach :: proc "contextless" (now, target, max_move: f32) -> f32 {
	if now < target {return min(now + max_move, target)}
	return max(now - max_move, target)
}

// process_bus: the block's duck, gain and filter on one bus, summed into the
// bus it feeds.
@(private)
process_bus :: proc "contextless" (m: ^Mixer, which: Bus, n: int) {
	b := &m.buses[which]
	buf := m.bus_buf[which][:2 * n]
	rate := f32(m.rate)
	b.duck_now = 1
	for &d in m.ducks {
		if !d.active || d.target != which {continue}
		wanted: f32 = 1
		if m.buses[d.trigger].peak > d.threshold {wanted = d.amount}
		tau := d.attack if wanted < d.held else d.release
		k := 1 - math.exp(-f32(n) / (max(tau, 1e-4) * rate))
		d.held += (wanted - d.held) * k
		b.duck_now *= d.held
	}
	frames := f32(n)
	b.gain_now = approach(b.gain_now, 0 if b.mute else b.gain, frames / (QUICK * rate))
	b.snap_now = approach(b.snap_now, b.snap, b.snap_step * frames)
	start := b.level
	end := b.gain_now * b.snap_now * b.duck_now
	b.level = end
	if b.cutoff_now != b.cutoff {b.cutoff_now = glide(b.cutoff_now, b.cutoff, n, rate, b.cut_tau)}
	filtering := b.cutoff_now < b.open * 0.999
	if filtering {
		for c in 0 ..< 2 {svf_set(&b.filter[c], f64(b.cutoff_now), 0.7071, f64(rate))}
	}
	peak: f32
	d := (end - start) / frames
	for f in 0 ..< n {
		g := start + d * f32(f)
		l, r := buf[2 * f] * g, buf[2 * f + 1] * g
		if filtering {
			l = svf_lowpass(&b.filter[0], l)
			r = svf_lowpass(&b.filter[1], r)
		}
		buf[2 * f], buf[2 * f + 1] = l, r
		peak = max(peak, abs(l), abs(r))
	}
	if filtering {
		svf_flush(&b.filter[0])
		svf_flush(&b.filter[1])
	}
	b.peak = peak
	if b.send > 0 || b.send_now > 0 {
		s0 := b.send_now
		b.send_now = approach(b.send_now, b.send, frames / (QUICK * rate))
		ds := (b.send_now - s0) / frames
		for f in 0 ..< n {
			g := s0 + ds * f32(f)
			m.rev_in[2 * f] += buf[2 * f] * g
			m.rev_in[2 * f + 1] += buf[2 * f + 1] * g
		}
	}
	if which != .Master {
		parent := m.bus_buf[BUS_PARENT[which]][:2 * n]
		for i in 0 ..< 2 * n {parent[i] += buf[i]}
	}
}
