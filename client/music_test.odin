package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"

import "../common/game"
import "../common/worldgen"
import "audio"

// The music director (M44), on a clock and seed of its own: no mixer, the
// test plays the app's part (a voice lives as long as its track is long).

// test_tracks: names and tags made for the tests, not the committed set.
@(private = "file")
TEST_TRACKS := [?]Music_Track {
	{
		name = "title",
		role = .Title,
		loop = true,
		seconds = 100,
		place = {"any"},
		time = {"any"},
		depth = {"any"},
		worlds = {"any"},
	},
	{
		name = "meadow",
		role = .Piece,
		seconds = 120,
		place = {"plains", "forest"},
		time = {"day", "dawn"},
		depth = {"surface"},
		worlds = {"home"},
	},
	{
		name = "night",
		role = .Piece,
		seconds = 150,
		place = {"any"},
		time = {"night"},
		depth = {"any"},
		worlds = {"any"},
	},
	{
		name = "deep",
		role = .Piece,
		seconds = 180,
		place = {"any"},
		time = {"any"},
		depth = {"cave"},
		worlds = {"any"},
	},
	{
		name = "far",
		role = .Piece,
		seconds = 130,
		place = {"desert", "mountains"},
		time = {"any"},
		depth = {"surface"},
		worlds = {"other"},
	},
	{
		name = "death",
		role = .Death,
		seconds = 5,
		place = {"any"},
		time = {"any"},
		depth = {"any"},
		worlds = {"any"},
	},
	{
		name = "discovery",
		role = .Discovery,
		seconds = 8,
		place = {"any"},
		time = {"any"},
		depth = {"any"},
		worlds = {"any"},
	},
}

// Sim: the app's part. A voice is alive until its track's seconds (a loop:
// until stopped) or its fade-out are over.
@(private = "file")
Sim :: struct {
	d:      Music_Director,
	input:  Music_Input,
	now:    f64,
	ends:   [MUSIC_SLOTS]f64,
	track:  [MUSIC_SLOTS]int,
	log:    [dynamic]string, // the decisions, one line each
	plays:  [dynamic]Music_Action, // every Play, in order
	stops:  int,
	fades:  [dynamic]Music_Action,
	last:   [dynamic]Music_Action, // the last step's actions
	danger: int, // pieces started while a piece was alive
}

@(private = "file")
sim_init :: proc(s: ^Sim, tracks: []Music_Track, seed: u64) {
	director_init(&s.d, tracks, seed)
	s.input.biome = 4
	s.input.time_of_day = 0.5
	s.input.world_home = true
	s.input.gap = 1
	s.log = make([dynamic]string, context.temp_allocator)
	s.plays = make([dynamic]Music_Action, context.temp_allocator)
	s.fades = make([dynamic]Music_Action, context.temp_allocator)
	s.last = make([dynamic]Music_Action, context.temp_allocator)
}

@(private = "file")
sim_in_world :: proc(s: ^Sim) {
	s.input.session, s.input.playing, s.input.loading = true, true, false
}

@(private = "file")
sim_step :: proc(s: ^Sim, dt: f32) {
	for slot in 0 ..< MUSIC_SLOTS {s.d.alive[slot] = s.ends[slot] > s.now}
	clear(&s.last)
	director_update(&s.d, s.input, dt, &s.last)
	s.input.died, s.input.arrived = false, false
	s.now += f64(dt)
	for a in s.last {
		slot := int(a.voice_slot)
		switch a.kind {
		case .Play:
			if slot == MUSIC_SLOT_PIECE && s.ends[slot] > s.now {s.danger += 1}
			tr := s.d.tracks[a.track]
			s.ends[slot] = math.INF_F64 if tr.loop else s.now + f64(tr.seconds)
			s.track[slot] = a.track
			append(&s.plays, a)
		case .Stop:
			s.ends[slot] = min(s.ends[slot], s.now + f64(a.seconds))
			s.stops += 1
		case .Fade:
			append(&s.fades, a)
		}
		names := [Music_Action_Kind]string {
			.Play = "play",
			.Fade = "fade",
			.Stop = "stop",
		}
		name := names[a.kind]
		append(&s.log, fmt.tprintf("%.1f %s %d %.2f", s.now, name, s.track[slot], a.gain))
	}
}

@(private = "file")
sim_run :: proc(s: ^Sim, seconds: f64, dt: f32 = 0.1) {
	for _ in 0 ..< int(seconds / f64(dt)) {sim_step(s, dt)}
}

@(test)
test_title_loops_then_fades :: proc(t: ^testing.T) {
	s: Sim
	sim_init(&s, TEST_TRACKS[:], 1)
	sim_run(&s, 600)
	testing.expect_value(t, len(s.plays), 1)
	testing.expect_value(t, s.plays[0].track, 0)
	testing.expect_value(t, s.plays[0].seconds, MUSIC_DEFAULTS.title_fade_in)
	testing.expect_value(t, s.stops, 0)
	// A session that is connecting: the title fades out over 3 s; nothing starts.
	s.input.session = true
	sim_step(&s, 0.1)
	testing.expect_value(t, len(s.last), 1)
	testing.expect_value(t, s.last[0].kind, Music_Action_Kind.Stop)
	testing.expect_value(t, s.last[0].seconds, MUSIC_DEFAULTS.title_fade_out)
	s.input.loading = true
	sim_run(&s, 120)
	testing.expect_value(t, len(s.plays), 1)
	testing.expect_value(t, s.stops, 1)
	free_all(context.temp_allocator)
}

@(test)
test_world_waits :: proc(t: ^testing.T) {
	d: Music_Director
	director_init(&d, TEST_TRACKS[:], 7)
	ranges := [4][2]f32 {
		{d.tuning.rare_min, d.tuning.rare_max},
		{d.tuning.normal_min, d.tuning.normal_max},
		{d.tuning.often_min, d.tuning.often_max},
		{d.tuning.constant_min, d.tuning.constant_max},
	}
	for gap in i32(0) ..< 4 {
		for _ in 0 ..< 1000 {
			d.first = true
			first := director_wait(&d, gap)
			if gap == 3 {
				testing.expect_value(t, first, 2)
			} else {
				testing.expectf(t, first >= 30 && first <= 90, "first wait %v", first)
			}
			later := director_wait(&d, gap)
			r := ranges[gap]
			testing.expectf(t, later >= r[0] && later <= r[1], "gap %d wait %v", gap, later)
		}
	}
	// Two hours of a world with the shortest gaps: one piece at a time, and
	// never the same twice running.
	s: Sim
	sim_init(&s, TEST_TRACKS[:], 3)
	s.input.gap = 3
	sim_in_world(&s)
	sim_run(&s, 7200, 0.5)
	pieces := 0
	last := -1
	for p in s.plays {
		if p.voice_slot != MUSIC_SLOT_PIECE {continue}
		pieces += 1
		testing.expectf(t, p.track != last, "piece %d twice in a row", p.track)
		last = p.track
	}
	testing.expect(t, pieces > 20, "music kept coming")
	testing.expect_value(t, s.danger, 0)
	free_all(context.temp_allocator)
}

// A reference of what fits, written apart from the director's.
@(private = "file")
best_fits :: proc(
	tracks: []Music_Track,
	biome: u8,
	time: f64,
	deep, home: bool,
) -> (
	best: [dynamic]int,
) {
	best = make([dynamic]int, context.temp_allocator)
	place := worldgen.BIOME_NAMES[worldgen.Biome(biome)]
	tname :=
		"night" if (time < 0.22 || time >= 0.78) else "dawn" if time < 0.30 else "day" if time < 0.70 else "dusk"
	want := [4]string{place, tname, "cave" if deep else "surface", "home" if home else "other"}
	top := -1
	for tr, i in tracks {
		if tr.role != .Piece {continue}
		lists := [4][]string{tr.place, tr.time, tr.depth, tr.worlds}
		score, ok := 0, true
		for l, k in lists {
			has_any, has_name := false, false
			for x in l {
				if x == "any" {has_any = true}
				if x == want[k] {has_name = true}
			}
			if !has_any && !has_name {ok = false}
			if has_name {score += 1}
		}
		if !ok {continue}
		if score > top {top = score; clear(&best)}
		if score == top {append(&best, i)}
	}
	return
}

@(test)
test_tracks_fit_the_place :: proc(t: ^testing.T) {
	d: Music_Director
	director_init(&d, TEST_TRACKS[:], 11)
	for biome in 0 ..< len(worldgen.Biome) {
		for time in ([?]f64{0.0, 0.1, 0.25, 0.5, 0.75, 0.9}) {
			for deep in ([?]bool{false, true}) {
				for home in ([?]bool{false, true}) {
					want := best_fits(TEST_TRACKS[:], u8(biome), time, deep, home)
					for _ in 0 ..< 8 {
						d.last = -1
						pick := director_pick(
							&d,
							{
								biome = u8(biome),
								time_of_day = time,
								depth = 12 if deep else 0,
								world_home = home,
							},
						)
						found := false
						for w in want {if w == pick {found = true}}
						if len(want) == 0 {found = pick >= 1 && pick <= 4} 	// none fits: any piece
						testing.expectf(
							t,
							found,
							"biome %d time %v deep %v home %v: picked %d, best %v",
							biome,
							time,
							deep,
							home,
							pick,
							want[:],
						)
					}
				}
			}
		}
	}
	// A world without biomes: only pieces tagged for any place.
	d.last = -1
	pick := director_pick(&d, {biome = game.NO_BIOME, time_of_day = 0.9, world_home = true})
	testing.expect_value(t, pick, 2)
	free_all(context.temp_allocator)
}

@(test)
test_pause_keeps_position :: proc(t: ^testing.T) {
	s: Sim
	sim_init(&s, TEST_TRACKS[:], 5)
	s.input.gap = 1
	sim_in_world(&s)
	sim_run(&s, 10)
	testing.expect(t, s.d.waiting && len(s.plays) == 0, "waiting for the first piece")
	left := s.d.wait_left
	s.input.paused = true
	sim_run(&s, 60)
	testing.expect_value(t, s.d.wait_left, left)
	testing.expect_value(t, len(s.plays), 0)
	s.input.paused = false
	// A piece playing while paused: not stopped, not started again.
	for len(s.plays) == 0 {sim_step(&s, 0.5)}
	plays, stops := len(s.plays), s.stops
	s.input.paused = true
	sim_run(&s, 60)
	testing.expect_value(t, len(s.plays), plays)
	testing.expect_value(t, s.stops, stops)
	testing.expect(t, s.d.on[MUSIC_SLOT_PIECE], "the piece plays on")
	free_all(context.temp_allocator)
}

@(test)
test_stingers :: proc(t: ^testing.T) {
	s: Sim
	sim_init(&s, TEST_TRACKS[:], 9)
	s.input.gap = 3
	sim_in_world(&s)
	for !s.d.on[MUSIC_SLOT_PIECE] {sim_step(&s, 0.5)}
	before := len(s.plays)
	s.input.died = true
	sim_step(&s, 0.5)
	testing.expect_value(t, len(s.last), 2)
	testing.expect_value(t, s.last[0].kind, Music_Action_Kind.Stop)
	testing.expect_value(t, s.last[0].seconds, MUSIC_DEFAULTS.stinger_fade)
	testing.expect_value(t, s.last[1].track, 5)
	testing.expect_value(t, s.last[1].gain, 1)
	// A second death during the stinger does not play another.
	s.input.died = true
	sim_step(&s, 0.5)
	testing.expect_value(t, len(s.plays), before + 1)
	// After it, a wait is drawn afresh and music goes on.
	sim_run(&s, 30)
	testing.expect(t, len(s.plays) > before + 1, "music came back")
	// An arrival plays the discovery stinger.
	for !s.d.on[MUSIC_SLOT_PIECE] {sim_step(&s, 0.5)}
	s.input.arrived = true
	sim_step(&s, 0.5)
	testing.expect_value(t, s.plays[len(s.plays) - 1].track, 6)
	free_all(context.temp_allocator)
}

// An arrival into an address seen before this run is quiet (the app decides).
@(test)
test_arrival_into_a_seen_address :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	s := new(Session)
	defer free(s)
	app.session = s
	defer app.session = nil
	s.state = .Playing
	home := game.address_derive(1)
	there := game.address_derive(2)
	s.home, s.welcome.address = home, home
	in_ := music_input(app)
	testing.expect(t, in_.world_home && in_.playing && !in_.arrived)
	s.arrivals += 1
	s.welcome.address = there
	testing.expect(t, music_input(app).arrived, "a world not seen before")
	s.arrivals += 1
	s.welcome.address = home
	in_ = music_input(app)
	testing.expect(t, !in_.arrived && in_.world_home, "home again: not an arrival")
	s.arrivals += 1
	s.welcome.address = there
	testing.expect(t, !music_input(app).arrived, "seen before")
	s.died += 1
	testing.expect(t, music_input(app).died)
	testing.expect(t, !music_input(app).died)
	delete(app.music.seen)
}

@(test)
test_layers :: proc(t: ^testing.T) {
	d: Music_Director
	director_init(&d, TEST_TRACKS[:], 1)
	out := make([dynamic]Music_Action, context.temp_allocator)
	director_set_layers(&d, {tracks = {1, 2, -1, -1}, levels = {1, 0.25, 1, 1}}, &out)
	testing.expect_value(t, len(out), 2)
	testing.expect_value(t, out[1].voice_slot, u8(MUSIC_SLOT_STEM + 1))
	testing.expect_value(t, out[1].gain, 0.25)
	testing.expect_value(t, out[1].seconds, 1)
	clear(&out)
	director_set_layers(&d, d.layers, &out)
	testing.expect_value(t, len(out), 0)
	free_all(context.temp_allocator)
}

// A looping track on Music and a full-scale effect on World: Music falls to
// 0.6 within 50 ms and returns within 1.2 s of the effect's end.
@(test)
test_duck_under_explosion :: proc(t: ^testing.T) {
	m := new(audio.Mixer)
	defer free(m)
	audio.mixer_init(m, 48000)
	square := make([]f32, 4800)
	defer delete(square)
	for &v, i in square {v = 0.5 if (i / 24) % 2 == 0 else -0.5}
	loud := make([]f32, 4800) // 0.1 s
	defer delete(loud)
	for &v, i in loud {v = 0.9 if (i / 24) % 2 == 0 else -0.9}
	music := audio.add_sound(m, {samples = square, rate = 48000})
	effect := audio.add_sound(m, {samples = loud, rate = 48000})
	audio.set_duck(
		m,
		0,
		{
			active = true,
			trigger = .Effects,
			target = .Music,
			threshold = 0.25,
			amount = 0.6,
			attack = 0.02,
			release = 1,
		},
	)
	an: audio.Analysis
	defer audio.analysis_destroy(&an)
	audio.analysis_attach(m, &an, {.Music})
	audio.play(m, {sound = music, gain = {1, 1}, bus = .Music, loop = true})
	audio.play(m, {sound = effect, gain = {1, 1}, bus = .World, start_frame = 48000})
	out: [2 * 480]f32
	for _ in 0 ..< 300 {
		audio.mix(m, out[:])
		audio.drain(m)
	}
	audio.analysis_finish(m, &an)
	x := an.audio[.Music][:]
	peak :: proc(x: []f32, from, to: f64) -> (p: f32) {
		for v in x[int(from * 48000) * 2:int(to * 48000) * 2] {p = max(p, abs(v))}
		return
	}
	before := peak(x, 0.5, 0.9)
	testing.expectf(t, before > 0.3, "the track plays (%v)", before)
	// 4800 frames of latency? The effect starts at frame 48000 (+ latency); look from
	// 50 ms after it to its end.
	start := 1.0 + f64(audio.latency(m)) / 48000
	ducked := peak(x, start + 0.05, start + 0.1)
	testing.expectf(t, ducked <= 0.65 * before, "ducked to %v of %v", ducked, before)
	back := peak(x, start + 0.1 + 1.2, start + 0.1 + 1.3)
	testing.expectf(t, back >= 0.85 * before, "back to %v of %v", back, before)
	free_all(context.temp_allocator)
}

HOUR_FILE :: "assets/baselines/audio/music_hour.decisions"

// The scripted hour: the title, a world (a walk into a cave, night, a death,
// a gate arrival), back to the title; the decisions the director makes are
// in assets/baselines/audio/music_hour.decisions (`build audio --accept
// music_hour` rewrites it).
@(test)
test_music_hour_golden :: proc(t: ^testing.T) {
	arena: virtual.Arena
	defer virtual.arena_destroy(&arena)
	tracks := music_tracks(&arena)
	s: Sim
	sim_init(&s, tracks, 0x4d_75_73_69_63)
	s.input.biome = 4
	s.input.gap = 2
	for s.now < 3600 {
		n := s.now
		switch {
		case n >= 3480:
			s.input.session = false
		case n >= 125:
			sim_in_world(&s)
			s.input.time_of_day = 0.9 if n >= 2100 else 0.5
			s.input.depth = 12 if n >= 1200 && n < 1500 else 0
		case n >= 120:
			s.input.session, s.input.loading, s.input.playing = true, true, false
		}
		s.input.died = n >= 2400 && n < 2400.25
		s.input.arrived = n >= 3000 && n < 3000.25
		sim_step(&s, 0.25)
	}
	text := strings.join(s.log[:], "\n", context.temp_allocator)
	text = strings.concatenate({text, "\n"}, context.temp_allocator)
	if ACCEPT == "music_hour" || ACCEPT == "all" {
		os.make_directory_all("assets/baselines/audio")
		if err := os.write_entire_file(HOUR_FILE, text); err != nil {
			testing.expectf(t, false, "cannot write %s: %v", HOUR_FILE, err)
		} else {
			log.infof("music hour accepted: %s", HOUR_FILE)
		}
		return
	}
	want, err := os.read_entire_file_from_path(HOUR_FILE, context.temp_allocator)
	if !testing.expectf(
		t,
		err == nil,
		"no %s (`build audio --accept music_hour` makes it)",
		HOUR_FILE,
	) {return}
	testing.expectf(
		t,
		string(want) == text,
		"the director's decisions changed (`build audio --accept music_hour` if meant):\n%s",
		text,
	)
	free_all(context.temp_allocator)
}
