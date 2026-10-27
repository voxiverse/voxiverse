package music_tool

import "core:slice"

// The note list: what a score and a MIDI file both become, and what the
// renderer plays. Times are ticks, PPQ to the quarter note.

PPQ :: 480

Note :: struct {
	start:    u32,
	length:   u32,
	key:      u8,
	velocity: u8,
	part:     u8,
}

Pedal :: struct {
	at:   u32,
	part: u8,
	down: bool,
}

Tempo :: struct {
	at:  u32,
	bpm: f64,
}

Meter :: struct {
	at:       u32,
	num, den: u8,
}

Part :: struct {
	name:      string,
	bank:      u16,
	program:   u8,
	volume_db: f32,
	pan:       f32,
}

Piece :: struct {
	title:                   string,
	parts:                   [dynamic]Part,
	notes:                   [dynamic]Note,
	pedals:                  [dynamic]Pedal,
	tempos:                  [dynamic]Tempo,
	meters:                  [dynamic]Meter,
	key, mode:               string,
	moods:                   [dynamic]string,
	place, time, depth:      [dynamic]string,
	worlds:                  [dynamic]string,
	loop:                    bool,
	seed:                    u64,
	humanize_ms:             f32,
	humanize_vel:            u8,
	reverb_rt60, reverb_wet: f32,
	end:                     u32, // ticks: the end of the last bar (the loop point)
}

// piece_defaults is what a piece without a header says (every MIDI file).
piece_defaults :: proc() -> (p: Piece) {
	p.reverb_rt60 = 1.8
	p.reverb_wet = 0.2
	return
}

// meter_bar_ticks is the length of one bar of a meter.
meter_bar_ticks :: proc(m: Meter) -> u32 {
	return u32(m.num) * (4 * PPQ / u32(m.den))
}

// piece_finish sorts the lists into their canonical order and makes sure
// there is a tempo and a meter at tick 0.
piece_finish :: proc(p: ^Piece) {
	slice.stable_sort_by(p.notes[:], proc(a, b: Note) -> bool {
		if a.start != b.start {return a.start < b.start}
		if a.part != b.part {return a.part < b.part}
		return a.key < b.key
	})
	slice.stable_sort_by(p.pedals[:], proc(a, b: Pedal) -> bool {
		if a.at != b.at {return a.at < b.at}
		if a.part != b.part {return a.part < b.part}
		return !a.down && b.down
	})
	slice.stable_sort_by(p.tempos[:], proc(a, b: Tempo) -> bool {return a.at < b.at})
	slice.stable_sort_by(p.meters[:], proc(a, b: Meter) -> bool {return a.at < b.at})
	if len(p.tempos) == 0 || p.tempos[0].at != 0 {
		inject_at(&p.tempos, 0, Tempo{0, p.tempos[0].bpm if len(p.tempos) > 0 else 120})
	}
	if len(p.meters) == 0 || p.meters[0].at != 0 {
		inject_at(
			&p.meters,
			0,
			Meter {
				0,
				p.meters[0].num if len(p.meters) > 0 else 4,
				p.meters[0].den if len(p.meters) > 0 else 4,
			},
		)
	}
}

// ticks_to_seconds maps ticks through the tempo map.
ticks_to_seconds :: proc(p: ^Piece, tick: f64) -> f64 {
	secs: f64
	at: f64
	bpm := 120.0
	for t in p.tempos {
		if f64(t.at) >= tick {break}
		secs += (f64(t.at) - at) * 60 / (bpm * PPQ)
		at = f64(t.at)
		bpm = t.bpm
	}
	return secs + (tick - at) * 60 / (bpm * PPQ)
}
