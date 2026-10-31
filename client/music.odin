package client

import "core:encoding/json"
import "core:log"
import "core:mem/virtual"

import "client:audio"
import "common:base"
import "common:worldgen"

// The music director (M44): a state machine the app feeds with what is going
// on (the screen, the session, the place, the time) and whose actions the app
// carries out on the mixer (music_apply), so tests need no mixer. It plays the
// title's piece on the menus, lets the world's music come and go in
// waits and tracks (one at a time, picked to fit where the player is), and
// punctuates deaths and arrivals with stingers. The pieces and their tags are
// the committed assets/music (music_data.odin, M43b).

Music_Role :: enum u8 {
	Piece, // played in a world
	Title, // looped on the menus
	Death, // stinger
	Discovery, // stinger
}

// Music_Track: a piece and what its metadata says about where it fits (a
// dimension's list holds "any" or names). `seconds` is its length.
Music_Track :: struct {
	name:    string,
	role:    Music_Role,
	loop:    bool,
	seconds: f32,
	place:   []string,
	time:    []string,
	depth:   []string,
	worlds:  []string,
}

// Music_Info: the metadata file's part the director reads.
@(private = "file")
Music_Info :: struct {
	loop:    bool,
	seconds: f64,
	mood:    []string,
	place:   []string,
	time:    []string,
	depth:   []string,
	worlds:  []string,
}

// music_tracks reads the metadata of the committed pieces (MUSIC, in order)
// into arena (the caller destroys it when the tracks are done with).
music_tracks :: proc(arena: ^virtual.Arena) -> []Music_Track {
	allocator := virtual.arena_allocator(arena)
	tracks := make([]Music_Track, len(MUSIC), allocator)
	for f, i in MUSIC {
		info: Music_Info
		if err := json.unmarshal(transmute([]u8)f.json, &info, allocator = allocator); err != nil {
			log.errorf("music metadata name=%s error=%v", f.name, err)
		}
		role := Music_Role.Piece
		switch {
		case f.name == "title":
			role = .Title
		case f.name == "death":
			role = .Death
		case f.name == "discovery":
			role = .Discovery
		}
		tracks[i] = {
			f.name,
			role,
			info.loop,
			f32(info.seconds),
			info.place,
			info.time,
			info.depth,
			info.worlds,
		}
	}
	return tracks
}

// Music_Tuning: every number the director uses, tunable from the console
// (`music.*`). Waits and fades are seconds.
Music_Tuning :: struct {
	title_fade_in:  f32,
	title_fade_out: f32,
	first_min:      f32, // the first wait in a session
	first_max:      f32,
	rare_min:       f32, // the gap options' waits
	rare_max:       f32,
	normal_min:     f32,
	normal_max:     f32,
	often_min:      f32,
	often_max:      f32,
	constant_min:   f32,
	constant_max:   f32,
	track_fade_in:  f32,
	cave_depth:     f32, // blocks under the surface
	cave_gain:      f32,
	cave_fade:      f32,
	stinger_fade:   f32, // the playing piece's fade-out before a stinger
	leave_fade:     f32, // ... on leaving a world
}

@(rodata)
MUSIC_DEFAULTS := Music_Tuning {
	title_fade_in  = 2,
	title_fade_out = 3,
	first_min      = 30,
	first_max      = 90,
	rare_min       = 900,
	rare_max       = 1800,
	normal_min     = 300,
	normal_max     = 900,
	often_min      = 60,
	often_max      = 240,
	constant_min   = 2,
	constant_max   = 10,
	track_fade_in  = 4,
	cave_depth     = 8,
	cave_gain      = 0.6,
	cave_fade      = 4,
	stinger_fade   = 1,
	leave_fade     = 2,
}

@(rodata)
MUSIC_VARS := [?]base.Var {
	{field = "title_fade_in", help = "seconds the title's piece fades in", min = 0, max = 30},
	{
		field = "title_fade_out",
		help = "seconds it fades out when a world loads",
		min = 0,
		max = 30,
	},
	{
		field = "first_min",
		help = "the shortest first wait in a world (seconds)",
		min = 0,
		max = 7200,
	},
	{field = "first_max", help = "the longest first wait in a world", min = 0, max = 7200},
	{field = "rare_min", help = "shortest wait between pieces, gap Rare", min = 0, max = 7200},
	{field = "rare_max", help = "longest wait, gap Rare", min = 0, max = 7200},
	{field = "normal_min", help = "shortest wait, gap Normal", min = 0, max = 7200},
	{field = "normal_max", help = "longest wait, gap Normal", min = 0, max = 7200},
	{field = "often_min", help = "shortest wait, gap Often", min = 0, max = 7200},
	{field = "often_max", help = "longest wait, gap Often", min = 0, max = 7200},
	{field = "constant_min", help = "shortest wait, gap Constant", min = 0, max = 7200},
	{field = "constant_max", help = "longest wait, gap Constant", min = 0, max = 7200},
	{field = "track_fade_in", help = "seconds a piece fades in", min = 0, max = 30},
	{
		field = "cave_depth",
		help = "blocks under the surface that count as a cave",
		min = 0,
		max = 256,
	},
	{field = "cave_gain", help = "a piece's level in a cave", min = 0, max = 1},
	{field = "cave_fade", help = "seconds the level takes to change", min = 0, max = 30},
	{
		field = "stinger_fade",
		help = "seconds a piece fades out before a stinger",
		min = 0,
		max = 30,
	},
	{
		field = "leave_fade",
		help = "seconds a piece fades out on leaving a world",
		min = 0,
		max = 30,
	},
}

music_table :: proc() -> base.Var_Table {
	return {"music.", Music_Tuning, MUSIC_VARS[:], &MUSIC_DEFAULTS}
}

// The voices the director plays on: the title's piece, the world's piece, a
// stinger, and the stems of layered music.
MUSIC_SLOT_TITLE :: 0
MUSIC_SLOT_PIECE :: 1
MUSIC_SLOT_STINGER :: 2
MUSIC_SLOT_STEM :: 3
MUSIC_STEMS :: 4
MUSIC_SLOTS :: MUSIC_SLOT_STEM + MUSIC_STEMS

Music_Input :: struct {
	screen:      Screen,
	session:     bool, // a session exists (connecting, choosing, loading or playing)
	loading:     bool, // ... and its loading screen is up
	paused:      bool, // `world_paused`
	playing:     bool, // ... and it is playing
	biome:       u8, // worldgen.Biome ordinal under the player, 255: not Earth
	time_of_day: f64, // 0..1, noon at 0.5
	depth:       f32, // the column's top at the player minus the feet, blocks
	world_home:  bool, // the world we joined in
	died:        bool, // this frame: the player died
	arrived:     bool, // this frame: arrival through a gate or travel into a world not seen before this run
	explosion:   bool, // this frame: something blew up near (the mixer's duck answers it)
	gap:         i32, // the gap option: 0 Rare .. 3 Constant
}

Music_Action_Kind :: enum u8 {
	Play,
	Fade, // a voice's level, over seconds
	Stop, // fade out over seconds, then end
}

Music_Action :: struct {
	kind:       Music_Action_Kind,
	track:      int, // into the track list (Play)
	voice_slot: u8,
	gain:       f32,
	seconds:    f32,
}

// Music_Layered: stems of one piece that fade by a parameter (unused as yet).
Music_Layered :: struct {
	tracks: [MUSIC_STEMS]int, // -1: no stem
	levels: [MUSIC_STEMS]f32,
}

Music_Director :: struct {
	tracks:     []Music_Track,
	tuning:     Music_Tuning,
	rng:        base.Rng,
	clock:      f64, // seconds, not while paused
	on:         [MUSIC_SLOTS]bool, // what the director has started and not stopped
	alive:      [MUSIC_SLOTS]bool, // set by the app before each update: the voice still plays
	in_session: bool,
	first:      bool, // the session's first wait is still to be drawn
	waiting:    bool,
	wait_left:  f32,
	last:       int, // the last piece played (-1: none)
	cave:       bool, // the piece's level is the cave's
	leave_left: f32, // seconds until the title may start again
	layers:     Music_Layered,
}

director_init :: proc(d: ^Music_Director, tracks: []Music_Track, seed: u64) {
	d^ = {
		tracks = tracks,
		tuning = MUSIC_DEFAULTS,
		rng    = base.rng_make(seed),
		first  = true,
		last   = -1,
	}
}

@(private = "file")
emit :: proc(out: ^[dynamic]Music_Action, a: Music_Action) {
	append(out, a)
}

// director_wait: the next wait, in seconds.
director_wait :: proc(d: ^Music_Director, gap: i32) -> f32 {
	t := &d.tuning
	lo, hi: f32
	if d.first {
		d.first = false
		if gap == 3 {return 2}
		lo, hi = t.first_min, t.first_max
	} else {
		switch gap {
		case 0:
			lo, hi = t.rare_min, t.rare_max
		case 2:
			lo, hi = t.often_min, t.often_max
		case 3:
			lo, hi = t.constant_min, t.constant_max
		case:
			lo, hi = t.normal_min, t.normal_max
		}
	}
	return base.rng_f32_range(&d.rng, lo, max(lo, hi))
}

// fits: whether tags suit value, and whether by name (not "any").
@(private = "file")
fits :: proc(tags: []string, value: string) -> (fit, named: bool) {
	for t in tags {
		if t == value {return true, value != "any"}
	}
	for t in tags {
		if t == "any" {return true, false}
	}
	return false, false
}

music_time_name :: proc(t: f64) -> string {
	switch {
	case t >= 0.78 || t < 0.22:
		return "night"
	case t < 0.30:
		return "dawn"
	case t < 0.70:
		return "day"
	}
	return "dusk"
}

// director_pick: the piece for this place and moment: among those fitting
// every dimension, those fitting the most by name; none: any but the last.
director_pick :: proc(d: ^Music_Director, in_: Music_Input) -> int {
	place := "any"
	if int(in_.biome) <
	   len(worldgen.Biome) {place = worldgen.BIOME_NAMES[worldgen.Biome(in_.biome)]}
	time := music_time_name(in_.time_of_day)
	depth := "cave" if in_.depth >= d.tuning.cave_depth else "surface"
	world := "home" if in_.world_home else "other"
	best := -1
	picks := make([dynamic]int, context.temp_allocator)
	all := make([dynamic]int, context.temp_allocator)
	for t, i in d.tracks {
		if t.role != .Piece {continue}
		append(&all, i)
		if i == d.last {continue}
		score := 0
		ok := true
		for dim in ([4]struct {
				tags:  []string,
				value: string,
			}{{t.place, place}, {t.time, time}, {t.depth, depth}, {t.worlds, world}}) {
			fit, named := fits(dim.tags, dim.value)
			if !fit {ok = false; break}
			if named {score += 1}
		}
		if !ok {continue}
		if score > best {best = score; clear(&picks)}
		if score == best {append(&picks, i)}
	}
	if len(picks) == 0 {
		for i in all {if i != d.last {append(&picks, i)}}
	}
	if len(picks) == 0 {picks = all}
	if len(picks) == 0 {return -1}
	return picks[base.rng_int_max(&d.rng, len(picks))]
}

@(private = "file")
stinger_track :: proc(d: ^Music_Director, role: Music_Role) -> int {
	for t, i in d.tracks {if t.role == role {return i}}
	return -1
}

// director_update advances the director by dt seconds and appends what the
// app must do. The app sets d.alive first.
director_update :: proc(
	d: ^Music_Director,
	in_: Music_Input,
	dt: f32,
	out: ^[dynamic]Music_Action,
) {
	t := &d.tuning
	if !in_.paused {d.clock += f64(dt)}
	for slot in 0 ..< MUSIC_SLOTS {
		if d.on[slot] && !d.alive[slot] {d.on[slot] = false}
	}
	stop :: proc(d: ^Music_Director, out: ^[dynamic]Music_Action, slot: int, seconds: f32) {
		if !d.on[slot] {return}
		d.on[slot] = false
		emit(out, {kind = .Stop, voice_slot = u8(slot), seconds = seconds})
	}

	if !in_.session {
		if d.in_session {
			// Back from a world: what plays fades out, then the title comes.
			d.in_session = false
			d.first, d.waiting, d.cave = true, false, false
			for slot in 1 ..< MUSIC_SLOTS {
				if d.on[slot] {d.leave_left = t.leave_fade}
				stop(d, out, slot, t.leave_fade)
			}
		}
		if d.leave_left > 0 {
			d.leave_left -= dt
		} else if !d.on[MUSIC_SLOT_TITLE] {
			if title := 0; len(d.tracks) > 0 {
				d.on[MUSIC_SLOT_TITLE] = true
				emit(
					out,
					{
						kind = .Play,
						track = title,
						voice_slot = MUSIC_SLOT_TITLE,
						gain = 1,
						seconds = t.title_fade_in,
					},
				)
			}
		}
		return
	}
	d.in_session = true
	d.leave_left = 0
	stop(d, out, MUSIC_SLOT_TITLE, t.title_fade_out)
	if !in_.playing || in_.loading {return}

	// In a world.
	for role in ([?]struct {
			role: Music_Role,
			on:   bool,
		}{{.Death, in_.died}, {.Discovery, in_.arrived}}) {
		if !role.on || d.on[MUSIC_SLOT_STINGER] {continue}
		track := stinger_track(d, role.role)
		if track < 0 {continue}
		stop(d, out, MUSIC_SLOT_PIECE, t.stinger_fade)
		d.on[MUSIC_SLOT_STINGER] = true
		d.waiting = false
		emit(out, {kind = .Play, track = track, voice_slot = MUSIC_SLOT_STINGER, gain = 1})
	}
	// In a cave a piece is quieter.
	if d.on[MUSIC_SLOT_PIECE] {
		cave := in_.depth >= t.cave_depth
		if cave != d.cave {
			d.cave = cave
			emit(
				out,
				{
					kind = .Fade,
					voice_slot = MUSIC_SLOT_PIECE,
					gain = t.cave_gain if cave else 1,
					seconds = t.cave_fade,
				},
			)
		}
	}
	if !d.on[MUSIC_SLOT_PIECE] && !d.on[MUSIC_SLOT_STINGER] && !d.waiting {
		d.waiting = true
		d.wait_left = director_wait(d, in_.gap)
	}
	if d.waiting && !in_.paused {
		d.wait_left -= dt
		if d.wait_left <= 0 {
			d.waiting = false
			if track := director_pick(d, in_); track >= 0 {
				d.last, d.cave = track, in_.depth >= t.cave_depth
				d.on[MUSIC_SLOT_PIECE] = true
				gain: f32 = t.cave_gain if d.cave else 1
				emit(
					out,
					{
						kind = .Play,
						track = track,
						voice_slot = MUSIC_SLOT_PIECE,
						gain = gain,
						seconds = t.track_fade_in,
					},
				)
			}
		}
	}
}

// director_set_layers moves the stems to their levels (over a second).
director_set_layers :: proc(
	d: ^Music_Director,
	layers: Music_Layered,
	out: ^[dynamic]Music_Action,
) {
	for i in 0 ..< MUSIC_STEMS {
		if layers.tracks[i] < 0 ||
		   layers.levels[i] == d.layers.levels[i] &&
			   layers.tracks[i] == d.layers.tracks[i] {continue}
		emit(
			out,
			{
				kind = .Fade,
				track = layers.tracks[i],
				voice_slot = u8(MUSIC_SLOT_STEM + i),
				gain = layers.levels[i],
				seconds = 1,
			},
		)
	}
	d.layers = layers
}

// Music_Player: what the app keeps to carry the director's actions out.
Music_Player :: struct {
	sounds: [dynamic]audio.Sound_Id, // each track's stream
	voices: [MUSIC_SLOTS]audio.Voice_Id,
}

// music_apply carries out actions on the mixer (bus Music).
music_apply :: proc(
	p: ^Music_Player,
	m: ^audio.Mixer,
	tracks: []Music_Track,
	actions: []Music_Action,
) {
	for a in actions {
		v := &p.voices[a.voice_slot]
		switch a.kind {
		case .Play:
			v^ = audio.play(
				m,
				{
					sound = p.sounds[a.track],
					gain = {a.gain, a.gain},
					pitch = 1,
					bus = .Music,
					loop = tracks[a.track].loop,
					fade_in = a.seconds,
				},
			)
		case .Fade:
			audio.fade_voice(m, v^, a.gain, a.seconds)
		case .Stop:
			audio.stop(m, v^, a.seconds)
		}
	}
}

// music_alive tells the director which of its voices still play.
music_alive :: proc(p: ^Music_Player, m: ^audio.Mixer, d: ^Music_Director) {
	for slot in 0 ..< MUSIC_SLOTS {d.alive[slot] = audio.alive(m, p.voices[slot])}
}

// music_streams registers every piece as a stream of the mixer (before the
// device starts); false if one cannot be decoded.
music_streams :: proc(
	p: ^Music_Player,
	m: ^audio.Mixer,
	tracks: []Music_Track,
	inline := false,
) -> bool {
	for f, i in MUSIC {
		id, ok := audio.add_stream(
			m,
			f.ogg,
			loop = tracks[i].loop,
			crossfade = 0.1 if tracks[i].loop else 0,
			inline = inline,
		)
		if !ok {return false}
		audio.set_sound_name(m, id, f.name)
		append(&p.sounds, id)
	}
	return true
}

music_player_destroy :: proc(p: ^Music_Player) {
	delete(p.sounds)
	p^ = {}
}
