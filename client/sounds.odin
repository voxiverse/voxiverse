package client

import "core:math"
import "core:math/rand"

import "../audio"
import "../game"
import "sfx"

// Sounds: the synthesized effects (client/sfx), made once at startup and
// played through the App's mixer. A session only records what happened
// (Sound_Event: an edit, a step, a landing); the App plays the events of
// each frame where they happened, relative to the camera.

Sound_Kind :: enum u8 {
	Break,
	Place,
	Step,
	Land,
	Entity_Hurt,
	Entity_Die,
	Launch,
	Explosion,
}

Sound_Event :: struct {
	kind:     Sound_Kind,
	block:    game.Block, // what broke, was placed or was stepped on
	position: [3]f64, // where (blocks)
	volume:   f32, // 0..1
}

Sound_Bank :: struct {
	block:   [sfx.Material][sfx.Action][sfx.VARIANTS]audio.Sound_Id,
	player:  [sfx.Player_Sound][sfx.VARIANTS]audio.Sound_Id,
	critter: [sfx.Critter_Sound][sfx.VARIANTS]audio.Sound_Id,
	blast:   [sfx.Blast_Sound][sfx.VARIANTS]audio.Sound_Id,
	samples: [dynamic][]f32, // owned
}

SOUND_RANGE :: 24 // blocks: further sounds are not heard
STRIDE :: 1.8 // blocks walked per footstep
LAND_MIN_SPEED :: 5 // blocks/s: softer landings make no sound
LAND_LOUD_SPEED :: 20 // ... and this hard is as loud as it gets

// sounds_init makes every sound and registers it with m.
sounds_init :: proc(b: ^Sound_Bank, m: ^audio.Mixer) {
	add :: proc(b: ^Sound_Bank, m: ^audio.Mixer, samples: []f32) -> audio.Sound_Id {
		append(&b.samples, samples)
		return audio.add_sound(m, {samples, sfx.RATE})
	}
	for mat in sfx.Material {
		for a in sfx.Action {
			for v in 0 ..< sfx.VARIANTS {b.block[mat][a][v] = add(b, m, sfx.block_sound(mat, a, v))}
		}
	}
	for p in sfx.Player_Sound {
		for v in 0 ..< sfx.VARIANTS {b.player[p][v] = add(b, m, sfx.player_sound(p, v))}
	}
	for c in sfx.Critter_Sound {
		for v in 0 ..< sfx.VARIANTS {b.critter[c][v] = add(b, m, sfx.critter_sound(c, v))}
	}
	for x in sfx.Blast_Sound {
		for v in 0 ..< sfx.VARIANTS {b.blast[x][v] = add(b, m, sfx.blast_sound(x, v))}
	}
}

sounds_destroy :: proc(b: ^Sound_Bank) {
	for s in b.samples {delete(s)}
	delete(b.samples)
	b^ = {}
}

// sounds_play plays a session's events of this frame, heard from view.
sounds_play :: proc(b: ^Sound_Bank, m: ^audio.Mixer, events: []Sound_Event, view: View) {
	right := [3]f32{math.cos(view.yaw), 0, -math.sin(view.yaw)}
	for e in events {
		d := e.position - view.position
		range: f32 = 4 * SOUND_RANGE if e.kind == .Explosion else SOUND_RANGE // explosions carry
		gain := audio.spatial_gain({f32(d.x), f32(d.y), f32(d.z)}, right, e.volume, range)
		if gain == {} {continue}
		pitch := rand.float32_range(0.9, 1.1)
		variant := rand.int_max(sfx.VARIANTS)
		switch e.kind {
		case .Entity_Hurt:
			audio.play(m, {b.critter[.Hurt][variant], gain, pitch})
		case .Entity_Die:
			audio.play(m, {b.critter[.Die][variant], gain, pitch})
		case .Launch:
			audio.play(m, {b.blast[.Launch][variant], gain, pitch})
		case .Explosion:
			audio.play(m, {b.blast[.Boom][variant], gain, pitch * 0.9})
		case .Land:
			audio.play(m, {b.player[.Land][variant], gain, pitch})
			if mat, ok := sfx.material_of(e.block); ok {
				audio.play(m, {b.block[mat][.Step][variant], gain, pitch})
			}
		case .Break, .Place, .Step:
			mat, ok := sfx.material_of(e.block)
			if !ok {continue}
			action: sfx.Action =
				.Break if e.kind == .Break else (.Place if e.kind == .Place else .Step)
			audio.play(m, {b.block[mat][action][variant], gain, pitch})
		}
	}
}

// movement_sounds: footsteps every STRIDE blocks walked and landings
// (louder the harder), from the tick the prediction just ran. Flying is
// silent.
@(private)
movement_sounds :: proc(s: ^Session) {
	was, now := s.prediction.previous, s.prediction.state
	if now.flying || was.flying {
		s.walked = 0
		return
	}
	feet := now.position
	under, solid := block_under(s, feet)
	if !was.on_ground && now.on_ground {
		speed := -was.velocity.y
		if speed >= LAND_MIN_SPEED && solid {
			loud := clamp((speed - LAND_MIN_SPEED) / (LAND_LOUD_SPEED - LAND_MIN_SPEED), 0.25, 1)
			append(&s.sounds, Sound_Event{.Land, under, feet, loud})
		}
		s.walked = 0
	}
	if now.on_ground {
		d := now.position - was.position
		s.walked += f32(math.sqrt(d.x * d.x + d.z * d.z))
		if s.walked >= STRIDE {
			s.walked -= STRIDE
			if solid {append(&s.sounds, Sound_Event{.Step, under, feet, 1})}
		}
	}
}

// block_under: the block the player stands on (under the middle of the
// feet, else under a corner of them, at the edge of a drop).
@(private)
block_under :: proc(s: ^Session, feet: [3]f64) -> (game.Block, bool) {
	y := i32(math.floor(feet.y - 0.05))
	h := f64(game.PLAYER_WIDTH) / 2
	for o in ([?][2]f64{{0, 0}, {-h, -h}, {h, -h}, {-h, h}, {h, h}}) {
		b, _ := world_block(
			&s.world,
			{i32(math.floor(feet.x + o.x)), y, i32(math.floor(feet.z + o.y))},
		)
		if game.block_collides(b) {return b, true}
	}
	return .Air, false
}
