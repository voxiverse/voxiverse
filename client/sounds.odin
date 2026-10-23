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
	Jump,
	Land,
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
		gain := audio.spatial_gain({f32(d.x), f32(d.y), f32(d.z)}, right, e.volume, SOUND_RANGE)
		if gain == {} {continue}
		pitch := rand.float32_range(0.9, 1.1)
		variant := rand.int_max(sfx.VARIANTS)
		switch e.kind {
		case .Jump:
			audio.play(m, {b.player[.Jump][variant], gain, pitch})
		case .Land:
			audio.play(m, {b.player[.Land][variant], gain, pitch})
			if mat, ok := sfx.material_of(e.block); ok {
				audio.play(m, {b.block[mat][.Step][variant], gain, pitch})
			}
		case .Break, .Place, .Step:
			mat, ok := sfx.material_of(e.block)
			if !ok {continue}
			action := [Sound_Kind]sfx.Action {
				.Break = .Break,
				.Place = .Place,
				.Step  = .Step,
				.Jump  = .Step,
				.Land  = .Step,
			}
			audio.play(m, {b.block[mat][action[e.kind]][variant], gain, pitch})
		}
	}
}
