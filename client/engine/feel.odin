package engine

import "core:math"

import "client:ui"
import "common:base"
import "common:game"

// The feel kit (docs/games.md, "Feel"): the short, small feedback a game's client part gives
// what happens in it, a line a call: a burst of particles, a flash on a creature, a shake or
// a kick of the view, a number floating up, a pulse at the screen's edge, a HUD element
// easing in (feel_hud draws what is the HUD's). It is
// presentation only: nothing is sent, saved or simulated, and the server never knows.
//
// Every effect is timed by the feel clock (Feel.clock), which follows the server's ticks as
// they are heard rather than the wall clock: it runs with the frames, never more than
// FEEL_LEAD ticks ahead of the newest tick heard nor FEEL_LAG behind it. So a world that
// stands still (paused) holds its effects where they are, and a screenshot script's `ticks
// <n>` (the server hurried) finds an effect as far through as the ticks put it, to within a
// tick or two, however long the frames took.

FEEL_LEAD :: 3 // ticks the feel clock may run ahead of the newest tick heard (the network's jitter)
FEEL_LAG :: 1 // ... and behind it (it catches up at once: a hurried server)

// Feel: the session's feedback under way.
Feel :: struct {
	clock:       f64, // ticks: the feel clock (feel_advance)
	burst_puffs: int, // live puffs bursts made (at most MAX_BURST_PUFFS)
	shaking:     f32, // how much the view shakes and kicks: the Screen shake setting, 0 under Reduce motion
	still:       bool, // Reduce motion: what eases in is simply there, what floats up stands
	numbers:     bool, // Damage numbers: the health a hit takes floats up from what it hit
	shakes:      [MAX_SHAKES]Shake,
	kicks:       [MAX_KICKS]Kick,
	floats:      [MAX_FLOATS]Float_Text,
	pulse:       Pulse,
}

// feel_advance: a frame of dt seconds on the feel clock (session_update, after the messages
// are taken: the newest tick heard bounds it), and the player's settings for the feel.
feel_advance :: proc(s: ^Session, settings: Settings, dt: f32) {
	f := &s.feel
	f.still = settings.reduce_motion
	f.numbers = settings.damage_numbers
	f.shaking = 0 if settings.reduce_motion else clamp(settings.screen_shake, 0, 1)
	f.clock += f64(dt) * game.TICK_RATE
	if c := &s.render_clock; c.heard {
		newest := f64(c.newest)
		f.clock = clamp(f.clock, newest - FEEL_LAG, newest + FEEL_LEAD)
	}
}

// feel_now: the feel clock's time for an effect that starts now: the tick of the message
// being taken, while one is (an effect of a hurried tick starts at its tick), else the clock.
feel_now :: proc(s: ^Session) -> f64 {
	return max(s.feel.clock, f64(s.rx.tick))
}

// feel_age: seconds on the feel clock since `from` (a feel_now), never less than 0.
feel_age :: proc(s: ^Session, from: f64) -> f32 {
	return f32(max(s.feel.clock - from, 0) / game.TICK_RATE)
}

// ---------------------------------------------------------------------------
// What the engine saw: the game's seen hook
// ---------------------------------------------------------------------------

// Seen: something the engine was told and showed that a game's client part may make felt
// (Game.seen), as it was taken: the server's own events, which a game's records need not
// repeat.
Seen :: union {
	Seen_Hurt,
	Seen_Death,
	Seen_Harm,
	Seen_Heal,
	Seen_Hit,
	Seen_Blast,
}

// Seen_Hurt: an entity the player knows was hurt (it flashes red): where its middle is
// drawn, and the health it lost (0: not told).
Seen_Hurt :: struct {
	id:     u32,
	kind:   game.Kind_Id,
	at:     [3]f64,
	amount: int,
}

// Seen_Death: an entity the player knew died (it bursts into pieces): where its middle was
// drawn, and the health it had left (what the last blow took).
Seen_Death :: struct {
	id:     u32,
	kind:   game.Kind_Id,
	at:     [3]f64,
	amount: int,
}

// Seen_Harm: the player was hurt: how much, and from which way (yaw; known false: from no
// place, a fall).
Seen_Harm :: struct {
	amount: f32,
	yaw:    f32,
	known:  bool,
}

// Seen_Heal: the player's health rose by amount while it lived (a respawn is none).
Seen_Heal :: struct {
	amount: f32,
}

// Seen_Hit: the player's shot hit another player (the hit marker).
Seen_Hit :: struct {
	kill:     bool,
	headshot: bool,
}

// Seen_Blast: something blew up (its smoke, debris and boom shown): where, and how far it
// reached (blocks).
Seen_Blast :: struct {
	at:     [3]f64,
	radius: f32,
}

// blast_shake: how hard a blast at `at` of `radius` shakes a view at `eyes` (0 ..= 1): a
// whole shake within its reach, dying away to nothing at four times it.
blast_shake :: proc(at, eyes: [3]f64, radius: f32) -> f32 {
	d := eyes - at
	distance := f32(math.sqrt(d.x * d.x + d.y * d.y + d.z * d.z))
	reach := max(radius, 1)
	return clamp(1 - (distance - reach) / (3 * reach), 0, 1)
}

// game_seen: the game's seen hook, if it has one.
@(private)
game_seen :: proc(s: ^Session, e: Seen) {
	if s.game.seen != nil {s.game.seen(s, e)}
}

// entity_middle: where the middle of an entity's box is drawn.
@(private)
entity_middle :: proc(s: ^Session, e: ^Other_Entity) -> [3]f64 {
	height := 0.5
	if info := game.kind_info(s.reg, e.kind); info != nil {height = f64(info.box[1]) / 2}
	return e.last_seen + {0, height, 0}
}

// ---------------------------------------------------------------------------
// Bursts: a handful of puffs flung out of a point
// ---------------------------------------------------------------------------

// Burst: what a burst of particles looks like (burst).
Burst :: enum u8 {
	Impact, // a blow landing: chips of what was hit (its colour, or a material's: block_colour)
	Sparks, // metal on metal, a shot on stone: quick bright specks
	Smoke, // a puff of smoke drifting up: a machine placed, a thing gone
	Sparkle, // a pickup, a purchase: specks rising and fading
	Death, // a creature undone: pieces flung up and falling
	Splash, // water thrown up
}

// MAX_BURST_PUFFS: the puffs bursts may have alive at once, of the MAX_PUFFS every effect
// shares: a burst past it makes fewer pieces, or none, so no game can crowd out the
// engine's own effects or slow the frame.
MAX_BURST_PUFFS :: 256

// Burst_Look: a preset's pieces: how many, how fast and how long, as ranges each piece
// draws from.
@(private = "file")
Burst_Look :: struct {
	pieces:  int,
	speed:   [2]f32, // blocks a second, outward
	lift:    [2]f32, // ... and upward
	life:    [2]f32, // seconds
	size:    [2]f32, // half-width, blocks
	spread:  f32, // the radius they start within, blocks
	gravity: f32, // blocks/s² (below 0: they rise)
	drag:    f32,
	color:   [4]u8, // when the call gives none
}

@(private = "file", rodata)
BURSTS := [Burst]Burst_Look {
	.Impact = {
		pieces = 8,
		speed = {1.5, 3},
		lift = {1, 2.5},
		life = {0.25, 0.45},
		size = {0.035, 0.06},
		spread = 0.1,
		gravity = 16,
		drag = 1,
		color = {200, 190, 170, 255},
	},
	.Sparks = {
		pieces = 10,
		speed = {3, 6},
		lift = {0.5, 2},
		life = {0.12, 0.28},
		size = {0.02, 0.035},
		spread = 0.05,
		gravity = 10,
		drag = 3,
		color = {255, 214, 110, 255},
	},
	.Smoke = {
		pieces = 6,
		speed = {0.3, 0.8},
		lift = {0.4, 1},
		life = {0.6, 1},
		size = {0.12, 0.2},
		spread = 0.2,
		drag = 2,
		color = {128, 124, 118, 255},
	},
	.Sparkle = {
		pieces = 10,
		speed = {0.3, 1},
		lift = {0.8, 1.6},
		life = {0.45, 0.75},
		size = {0.025, 0.045},
		spread = 0.25,
		gravity = -0.5,
		drag = 2.5,
		color = {255, 232, 130, 255},
	},
	.Death = {
		pieces = 16,
		speed = {1.5, 3.5},
		lift = {2, 4.5},
		life = {0.5, 0.8},
		size = {0.05, 0.08},
		spread = 0.3,
		gravity = 18,
		drag = 0.5,
		color = {150, 150, 150, 255},
	},
	.Splash = {
		pieces = 12,
		speed = {0.8, 2},
		lift = {2.5, 4},
		life = {0.4, 0.7},
		size = {0.035, 0.06},
		spread = 0.2,
		gravity = 20,
		drag = 0.5,
		color = {96, 146, 220, 255},
	},
}

// burst: a burst of particles at `at` as the preset kind looks, in color (zero: the preset's
// own; a material's dust: block_colour), scale times as far and as big (a boss's death);
// fewer pieces, or none, when bursts have MAX_BURST_PUFFS alive already.
burst :: proc(s: ^Session, at: [3]f64, kind: Burst, color := [4]u8{}, scale: f32 = 1) {
	look := BURSTS[kind]
	tint := color if color.a != 0 else look.color
	rng := base.cosmetic_rng()
	pieces := min(look.pieces, MAX_BURST_PUFFS - s.feel.burst_puffs)
	for _ in 0 ..< pieces {
		angle := base.rng_f32_range(rng, 0, math.TAU)
		out := base.rng_f32_range(rng, look.speed[0], look.speed[1]) * scale
		start := [3]f64 {
			f64(math.cos(angle) * look.spread * scale),
			f64(base.rng_f32_range(rng, -0.5, 0.5) * look.spread * scale),
			f64(math.sin(angle) * look.spread * scale),
		}
		// (each piece a shade lighter or darker, so a burst is not one flat colour)
		shade := base.rng_f32_range(rng, 0.85, 1.12)
		c := tint
		for k in 0 ..< 3 {c[k] = u8(clamp(f32(c[k]) * shade, 0, 255))}
		if !puff_add(
			s,
			{
				position = at + start,
				velocity = {
					math.cos(angle) * out,
					base.rng_f32_range(rng, look.lift[0], look.lift[1]) * scale,
					math.sin(angle) * out,
				},
				life = base.rng_f32_range(rng, look.life[0], look.life[1]),
				size = base.rng_f32_range(rng, look.size[0], look.size[1]) * scale,
				gravity = look.gravity,
				drag = look.drag,
				color = c,
				burst = true,
			},
		) {break}
		s.feel.burst_puffs += 1
	}
}

// ---------------------------------------------------------------------------
// Flashes on creatures
// ---------------------------------------------------------------------------

ENTITY_FLASH_SECONDS :: 0.25

// entity_flash: the entity drawn in color for a moment (ENTITY_FLASH_SECONDS): red as every
// creature is when hurt, white for a critical blow, gold for a level gained.
entity_flash :: proc(s: ^Session, id: u32, color: [4]u8) {
	if e, known := &s.entities[id]; known {
		e.flash_at, e.flash_color = feel_now(s), color
	}
}

// entity_flashing: the colour an entity is drawn in now, if it flashes.
@(private)
entity_flashing :: proc(s: ^Session, e: ^Other_Entity) -> (color: [4]u8, ok: bool) {
	if e.flash_color.a == 0 || feel_age(s, e.flash_at) >= ENTITY_FLASH_SECONDS {return}
	return e.flash_color, true
}

// ---------------------------------------------------------------------------
// The view: shakes and kicks
// ---------------------------------------------------------------------------

MAX_SHAKES :: 4 // shakes under way at once (one more takes the place of the one with least left)
SHAKE_MOVE :: 0.16 // blocks the view moves at a whole shake
SHAKE_TURN :: 1.1 * math.RAD_PER_DEG // ... and turns
MAX_KICKS :: 4
KICK_PEAK :: 0.05 // seconds a kick takes to its height (it settles over a few times that)
KICK_CAP :: 5.0 // degrees the kicks under way add up to at most

// Shake: a shake of the view under way: how hard (0 ..= 1), for how long, since when.
Shake :: struct {
	amount:  f32,
	seconds: f32,
	born:    f64,
}

// Kick: a jolt of the view's pitch under way: degrees up (down below 0), since when.
Kick :: struct {
	degrees: f32,
	born:    f64,
}

// shake: the view shakes, `amount` hard (0 ..= 1: 0.15 a blow taken, 0.4 a blast near, 1 the
// most there is) for `seconds`, dying away. Shakes under way add up, to a whole shake at
// most; the player's Screen shake setting scales them, and Reduce motion stills them.
shake :: proc(s: ^Session, amount: f32, seconds: f32) {
	if amount <= 0 || seconds <= 0 {return}
	f := &s.feel
	slot, least := 0, f32(max(f32))
	for sh, i in f.shakes {
		left := shake_amount(f, sh)
		if left < least {slot, least = i, left}
	}
	f.shakes[slot] = {min(amount, 1), seconds, feel_now(s)}
}

// kick: the view jolts up by `degrees` (down below 0) and settles, in a few tenths of a
// second: a gun's recoil, a landing, a collision. Kicks under way add up to KICK_CAP at most;
// the Screen shake setting scales them, and Reduce motion stills them.
kick :: proc(s: ^Session, degrees: f32) {
	f := &s.feel
	slot, oldest := 0, f64(max(f64))
	for k, i in f.kicks {
		if k.born < oldest {slot, oldest = i, k.born}
	}
	f.kicks[slot] = {degrees, feel_now(s)}
}

// shake_amount: what is left of a shake now, its amount dying away as the square of the time
// it has left (0: over).
@(private)
shake_amount :: proc(f: ^Feel, sh: Shake) -> f32 {
	if sh.seconds <= 0 {return 0}
	age := f32(max(f.clock - sh.born, 0) / game.TICK_RATE)
	left := 1 - age / sh.seconds
	return sh.amount * left * left if left > 0 else 0
}

// kick_curve: a kick's height t seconds on, as a fraction of its degrees: up to 1 at
// KICK_PEAK, then settling (t/peak · e^(1 - t/peak)).
@(private)
kick_curve :: proc(t: f32) -> f32 {
	x := t / KICK_PEAK
	return x * math.exp(1 - x)
}

// feel_shaking: how much the shakes under way add up to now (0 ..= 1).
feel_shaking :: proc(f: ^Feel) -> f32 {
	sum: f32
	for sh in f.shakes {sum += shake_amount(f, sh)}
	return min(sum, 1)
}

// feel_view: what the shakes and kicks under way do to the view now, scaled by the setting
// (0: nothing at all): a move (blocks) and a turn (yaw, pitch, roll: radians).
feel_view :: proc(f: ^Feel) -> (move: [3]f32, turn: [3]f32) {
	if f.shaking <= 0 {return}
	t := f32(f.clock / game.TICK_RATE)
	if amount := feel_shaking(f) * f.shaking; amount > 0 {
		// Sines at frequencies that do not line up: it reads as a tremble, not a sway.
		n := [3]f32 {
			math.sin(t * 37.1) * 0.6 + math.sin(t * 23.3 + 1.7) * 0.4,
			math.sin(t * 41.9 + 0.6) * 0.6 + math.sin(t * 29.7 + 2.9) * 0.4,
			math.sin(t * 33.7 + 4.1) * 0.6 + math.sin(t * 19.1 + 0.3) * 0.4,
		}
		move = n * SHAKE_MOVE * amount
		turn = {n.z, n.x, n.y} * SHAKE_TURN * amount
	}
	degrees: f32
	for k in f.kicks {
		if k.degrees == 0 {continue}
		degrees += k.degrees * kick_curve(f32(max(f.clock - k.born, 0) / game.TICK_RATE))
	}
	turn.y += clamp(degrees, -KICK_CAP, KICK_CAP) * f.shaking * math.RAD_PER_DEG
	return
}

// ---------------------------------------------------------------------------
// The HUD: floating text, the edge's pulse, tweens
// ---------------------------------------------------------------------------

MAX_FLOATS :: 24 // texts floating at once (one more takes the oldest's place)
FLOAT_TEXT_MAX :: 64 // bytes of one (cut at a whole letter): a quest's step done says its text
FLOAT_SECONDS :: 0.9
FLOAT_RISE :: 1.1 // blocks it rises
FLOAT_POP :: 0.15 // seconds it takes to pop to its size

// Float_Text: a few words in the world rising and fading: a hit's damage, "+5".
Float_Text :: struct {
	text:  [FLOAT_TEXT_MAX]u8,
	len:   int, // (0: a free slot)
	at:    [3]f64,
	color: [4]u8,
	scale: f32,
	born:  f64,
}

// float_text: text over `at` in the world, in color, scale times the HUD's text: it pops,
// rises a block and fades in under a second (FLOAT_SECONDS). At most MAX_FLOATS at once,
// the oldest giving way; under Reduce motion it stands and fades.
float_text :: proc(s: ^Session, at: [3]f64, text: string, color: [4]u8, scale: f32 = 1) {
	f := &s.feel
	slot, oldest := 0, f64(max(f64))
	for x, i in f.floats {
		if x.len == 0 {slot = i; break}
		if x.born < oldest {slot, oldest = i, x.born}
	}
	x := &f.floats[slot]
	x.len = copy(x.text[:], base.text_cut(text, FLOAT_TEXT_MAX))
	x.at, x.color, x.scale, x.born = at, color, scale, feel_now(s)
}

// MADE_COLOR: the colour of what made() says (a warm gold, as a reward reads).
MADE_COLOR :: [4]u8{250, 214, 110, 255}

// made: the player made something (a game's crafting done): a soft chime, and `text` ("+2
// Cord") floating up a little under the middle of its view, as a pickup reads.
made :: proc(s: ^Session, text: string) {
	c := &s.camera
	pitch := f64(c.pitch) - 0.12 // (just under where it looks: it rises as it fades)
	ahead := [3]f64 {
		-math.sin(f64(c.yaw)) * math.cos(pitch) * 2,
		math.sin(pitch) * 2,
		-math.cos(f64(c.yaw)) * math.cos(pitch) * 2,
	}
	append(&s.sounds, Sound_Event{.Made, .Air, c.position, 0.8, {}})
	float_text(s, c.position + ahead, text, MADE_COLOR, 1.2)
}

PULSE_SECONDS :: 0.45
PULSE_BANDS :: 8 // the edge's glow, in bands fading inward
PULSE_DEPTH :: 0.09 // ... as deep as this of the screen's height

// Pulse: the screen's edge glowing for a moment.
Pulse :: struct {
	color: [4]u8, // (alpha 0: none)
	born:  f64,
}

// pulse: the screen's edges glow in color for a moment (PULSE_SECONDS) and fade, strongest
// at the edge: red for harm taken, green for a heal. Its alpha is how strong (60 to 110
// reads without hiding anything); a new one replaces the one fading.
pulse :: proc(s: ^Session, color: [4]u8) {
	s.feel.pulse = {color, feel_now(s)}
}

// Tween: a HUD element's moment of easing in (a score that changed, a banner): started when
// its news comes, read each frame as the fraction done.
Tween :: struct {
	born:    f64,
	started: bool,
}

// tween_start: the tween begins now (again, if it was under way).
tween_start :: proc(t: ^Tween, s: ^Session) {
	t^ = {feel_now(s), true}
}

// tween_value: how far the tween is, 0 at its start to 1 after `seconds`, along the curve
// (ui.ease); 1 when never started, and at once under Reduce motion. A pop is
// `scale * (0.7 + 0.3 * tween_value(&t, s, 0.25, .Out_Back))`, a slide in `x - 40 * (1 - v)`.
tween_value :: proc(t: ^Tween, s: ^Session, seconds: f32, curve := ui.Ease.Out_Cubic) -> f32 {
	if !t.started || s.feel.still || seconds <= 0 {return 1}
	return ui.ease(curve, feel_age(s, t.born) / seconds)
}

// feel_hud: what the feel kit draws on the HUD (hud_draw, before the game's HUD): the texts
// floating over the world, then the edge's pulse.
feel_hud :: proc(s: ^Session, ctx: ^ui.Context) {
	f := &s.feel
	t := &ctx.theme
	for &x in f.floats {
		if x.len == 0 {continue}
		age := feel_age(s, x.born)
		if age >= FLOAT_SECONDS {
			x.len = 0
			continue
		}
		done := age / FLOAT_SECONDS
		rise, pop: f32 = 0, 1
		if !f.still {
			rise = FLOAT_RISE * ui.ease(.Out_Cubic, done)
			pop = 0.6 + 0.4 * ui.ease(.Out_Back, age / FLOAT_POP)
		}
		at, shown := world_point(s, ctx, x.at + {0, f64(rise), 0})
		if !shown {continue}
		fade := 1 - ui.ease(.In_Out, (done - 0.55) / 0.45)
		color, shadow := x.color, t.text_shadow
		color.a = u8(f32(color.a) * fade)
		shadow.a = u8(f32(shadow.a) * fade)
		size := t.font_size * 1.2 * x.scale * pop
		text := string(x.text[:x.len])
		r := ui.Rect{at.x - 80, at.y - size, 160, size * 2}
		ui.draw_text(ctx, {r.x + 2, r.y + 2, r.w, r.h}, text, size, shadow, .Center)
		ui.draw_text(ctx, r, text, size, color, .Center)
	}
	if f.pulse.color.a == 0 {return}
	age := feel_age(s, f.pulse.born)
	if age >= PULSE_SECONDS {
		f.pulse = {}
		return
	}
	strength := f32(f.pulse.color.a) * (1 - ui.ease(.Out_Quad, age / PULSE_SECONDS))
	band := ctx.screen.h * PULSE_DEPTH / PULSE_BANDS
	r := ctx.screen
	for k in 0 ..< PULSE_BANDS {
		inward := 1 - f32(k) / PULSE_BANDS
		color := f.pulse.color
		color.a = u8(strength * inward * inward)
		ui.stroke_rect(ctx, r, band, color)
		r = {r.x + band, r.y + band, r.w - 2 * band, r.h - 2 * band}
	}
}
