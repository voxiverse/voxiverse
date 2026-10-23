package audio

import "core:math"
import "core:sync"

// The mixer: plays sounds on a fixed pool of voices into interleaved
// stereo f32. It knows nothing of devices (device.odin feeds it to the
// sound card; tests call mix directly).
//
// Threads: the game thread registers sounds (before the device starts) and
// queues commands with play / set_volume; the audio thread runs mix, which
// takes the queued commands first. The command ring has one producer and
// one consumer and never blocks: when it is full, a play is dropped (and
// counted), as a sound effect that late would be wrong anyway.

MAX_VOICES :: 32
MAX_SOUNDS :: 256
COMMAND_RING :: 256 // power of two

Sound_Id :: distinct u16

// Sound: mono samples (-1..1) at their own rate; owned by whoever
// registered them, unchanged while the mixer may play them.
Sound :: struct {
	samples: []f32,
	rate:    u32,
}

// Play: one sound, once. gain: left and right (spatial position and
// loudness, see spatial_gain); pitch: playback speed (1 = as made).
Play :: struct {
	sound: Sound_Id,
	gain:  [2]f32,
	pitch: f32,
}

Mixer :: struct {
	rate:     u32, // output frames per second
	sounds:   [MAX_SOUNDS]Sound,
	count:    int,
	// Audio thread only:
	voices:   [MAX_VOICES]Voice,
	volume:   f32,
	// The command ring: written by the game thread, read by the audio thread.
	commands: [COMMAND_RING]Command,
	written:  u32, // (atomic) commands written ever
	read:     u32, // (atomic) commands read ever
	dropped:  u32, // (atomic) plays that found the ring full
	stats:    Stats, // (atomic fields) written by the audio thread
}

// Stats: what the mixer has done, for the debug overlay and the log.
Stats :: struct {
	voices: u32, // playing after the last mix
	played: u32, // sounds started, ever
	frames: u64, // frames mixed, ever
}

// stats reads the mixer's statistics from any thread.
stats :: proc(m: ^Mixer) -> Stats {
	return {
		voices = sync.atomic_load(&m.stats.voices),
		played = sync.atomic_load(&m.stats.played),
		frames = sync.atomic_load(&m.stats.frames),
	}
}

@(private)
Voice :: struct {
	active: bool,
	sound:  Sound_Id,
	pos:    f64, // in the sound's samples
	step:   f64, // sound samples per output frame
	gain:   [2]f32,
}

@(private)
Command :: union {
	Play,
	Set_Volume,
}

@(private)
Set_Volume :: struct {
	volume: f32,
}

mixer_init :: proc(m: ^Mixer, rate: u32) {
	m^ = {
		rate   = rate,
		volume = 1,
	}
}

// add_sound registers a sound (before the device starts); its id plays it.
add_sound :: proc(m: ^Mixer, s: Sound) -> Sound_Id {
	assert(m.count < MAX_SOUNDS && s.rate > 0)
	m.sounds[m.count] = s
	m.count += 1
	return Sound_Id(m.count - 1)
}

// play queues a sound to start at the next mix; false if dropped.
play :: proc(m: ^Mixer, p: Play) -> bool {
	assert(int(p.sound) < m.count)
	return push(m, p)
}

// set_volume sets the master volume (0..1) from the next mix on.
set_volume :: proc(m: ^Mixer, volume: f32) {
	push(m, Set_Volume{clamp(volume, 0, 1)})
}

@(private)
push :: proc(m: ^Mixer, c: Command) -> bool {
	w := sync.atomic_load_explicit(&m.written, .Relaxed)
	r := sync.atomic_load_explicit(&m.read, .Acquire)
	if w - r == COMMAND_RING {
		sync.atomic_add(&m.dropped, 1)
		return false
	}
	m.commands[w & (COMMAND_RING - 1)] = c
	sync.atomic_store_explicit(&m.written, w + 1, .Release)
	return true
}

// mix fills out (interleaved stereo, len = 2 * frames) with the next
// frames. Audio thread; no allocation, no locks.
mix :: proc "contextless" (m: ^Mixer, out: []f32) {
	take_commands(m)
	for &s in out {s = 0}
	frames := len(out) / 2
	for &v in m.voices {
		if !v.active {continue}
		samples := m.sounds[v.sound].samples
		last := f64(len(samples) - 1)
		g := v.gain * m.volume
		for f in 0 ..< frames {
			if v.pos >= last {
				v.active = false
				break
			}
			i := int(v.pos)
			t := f32(v.pos - f64(i))
			x := samples[i] + (samples[i + 1] - samples[i]) * t // linear between samples
			out[2 * f] += x * g[0]
			out[2 * f + 1] += x * g[1]
			v.pos += v.step
		}
	}
	for &s in out {s = soft_clip(s)}
	playing: u32
	for v in m.voices {if v.active {playing += 1}}
	sync.atomic_store(&m.stats.voices, playing)
	sync.atomic_add(&m.stats.frames, u64(frames))
}

@(private)
take_commands :: proc "contextless" (m: ^Mixer) {
	r := sync.atomic_load_explicit(&m.read, .Relaxed)
	w := sync.atomic_load_explicit(&m.written, .Acquire)
	for ; r != w; r += 1 {
		switch c in m.commands[r & (COMMAND_RING - 1)] {
		case Play:
			start(m, c)
		case Set_Volume:
			m.volume = c.volume
		}
	}
	sync.atomic_store_explicit(&m.read, r, .Release)
}

// start puts a sound on a free voice, or on the quietest one playing (a
// quiet sound lost is missed least).
@(private)
start :: proc "contextless" (m: ^Mixer, p: Play) {
	if len(m.sounds[p.sound].samples) < 2 || p.pitch <= 0 {return}
	chosen := -1
	quietest := max(f32)
	for v, i in m.voices {
		if !v.active {
			chosen = i
			break
		}
		if loud := v.gain[0] + v.gain[1]; loud < quietest {
			chosen, quietest = i, loud
		}
	}
	if !m.voices[chosen].active || p.gain[0] + p.gain[1] > quietest {
		m.voices[chosen] = {
			active = true,
			sound  = p.sound,
			step   = f64(m.sounds[p.sound].rate) / f64(m.rate) * f64(p.pitch),
			gain   = p.gain,
		}
		sync.atomic_add(&m.stats.played, 1)
	}
}

// soft_clip leaves quiet signals alone and bends loud ones under 1, so
// many sounds at once squash instead of crackling.
@(private)
soft_clip :: proc "contextless" (x: f32) -> f32 {
	KNEE :: 0.8
	a := abs(x)
	if a <= KNEE {return x}
	over := a - KNEE
	return math.sign(x) * (KNEE + (1 - KNEE) * over / (over + (1 - KNEE)))
}

// spatial_gain: left and right gains for a sound at offset (from the
// listener, in blocks) heard facing `right` (unit, horizontal): quieter
// with distance (silent beyond range) and panned by direction, never
// fully to one side.
spatial_gain :: proc(offset: [3]f32, right: [3]f32, volume: f32, range: f32) -> [2]f32 {
	d := math.sqrt(offset.x * offset.x + offset.y * offset.y + offset.z * offset.z)
	if d >= range {return {}}
	near := 1 - d / range
	loud := volume * near * near
	pan: f32 = 0
	if d > 0.001 {pan = (offset.x * right.x + offset.y * right.y + offset.z * right.z) / d}
	pan *= 0.7 * min(d / 2, 1) // close by, sounds come from everywhere
	// Constant power: left² + right² stays loud².
	angle := (pan + 1) * math.PI / 4
	return {loud * math.cos(angle), loud * math.sin(angle)} * math.SQRT_TWO
}
