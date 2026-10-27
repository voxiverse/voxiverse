package client

import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:testing"

import "audio"
import "sfx"

// M32b's quality baselines: four scripted scenarios rendered offline, their
// numbers compared with assets/baselines/audio/<scenario>.txt (client/audio/baseline.odin
// says what is measured and how much may move). A sound retuned without
// accepting its baseline fails here; `build audio --accept <scenario|all>`
// reruns these tests with -define:VX_AUDIO_ACCEPT=<scenario|all>, which
// rewrites the files instead (with -define:VX_AUDIO_WAV_DIR=<dir> each
// scenario's master goes to a WAV there too, and its capture to a .vxac for
// `build audiodump`), and the diff is reviewed like code.

BASELINE_DIR :: "assets/baselines/audio"
ACCEPT :: #config(VX_AUDIO_ACCEPT, "")
WAV_DIR :: #config(VX_AUDIO_WAV_DIR, "") // `build audio -wav`: each scenario's master as a file
BASELINE_STREAM :: #load("audio/testdata/tone.ogg")
BASELINE_RATE :: 48000
BASELINE_BLOCK :: 480

Audio_Scenario :: enum {
	burst, // many materials broken at once
	cave_walk, // a field, into a cave, and out
	title_to_world, // the title's music, a click, the world fading in under it
	stress, // more voices than can be mixed
}

// scenario_run renders a scenario and measures it. `gain` scales the sounds
// (1 as scripted: a test changes it to see the baseline notice).
scenario_run :: proc(which: Audio_Scenario, gain: f32 = 1) -> audio.Baseline {
	m := new(audio.Mixer)
	defer free(m)
	audio.mixer_init(m, BASELINE_RATE)
	bank := new(Sound_Bank)
	defer {sounds_destroy(bank); free(bank)}
	sounds_init(bank, m)
	// The streams come after the effects in the sound table; a scenario without
	// music has only the effects, so `build audiodump` can replay its capture.
	music: audio.Sound_Id
	if which == .title_to_world || which == .stress {
		ok: bool
		music, ok = audio.add_stream(
			m,
			BASELINE_STREAM,
			loop = true,
			crossfade = 0.1,
			inline = true,
		)
		assert(ok)
	}
	defer audio.streams_close(m)
	if WAV_DIR != "" {audio.capture_start(m, 4096)}
	at :: proc(seconds: f64) -> u64 {return u64(seconds * BASELINE_RATE) + 4800}
	g := [2]f32{0.5, 0.45} * gain
	marks := make([dynamic]audio.Mark, context.temp_allocator)
	seconds: f64
	switch which {
	case .burst:
		seconds = 3
		n := 0
		for mat in sfx.Material {
			for k in 0 ..< 5 {
				when_s := 0.02 * f64(n)
				audio.play(
					m,
					{
						sound = bank.block[mat][.Break][k % sfx.VARIANTS],
						gain = g,
						pitch = 0.85 + 0.05 * f32(k),
						start_frame = at(when_s),
					},
				)
				n += 1
			}
		}
		audio.play(
			m,
			{sound = bank.block[.Glass][.Break][0], gain = g * 1.3, start_frame = at(1.5)},
		)
		append(&marks, audio.Mark{"glass_break", int(at(1.5)), int(at(2.9))})
	case .cave_walk:
		seconds = 9
		audio.set_reverb(m, 0.5, 0.5, 0.05, 0.1)
		audio.play(
			m,
			{
				sound = bank.block[.Grass][.Step][0],
				gain = g * 0.15,
				bus = .Ambience,
				loop = true,
				cutoff = 5000,
			},
		)
		for i in 0 ..< 16 {
			mat :=
				sfx.Material.Grass if i < 6 else sfx.Material.Stone if i < 12 else sfx.Material.Dirt
			audio.play(
				m,
				{
					sound = bank.block[mat][.Step][i % sfx.VARIANTS],
					gain = g * 0.7,
					bus = .Player,
					start_frame = at(0.5 * f64(i)),
				},
			)
		}
		// The cave: the ambience muffled and quieter, a long reverb on what is heard.
		cave := audio.snapshot_neutral()
		cave.gain[.Ambience] = 0.5
		cave.cutoff[.Ambience] = 700
		audio.set_snapshot(m, cave, 0.4, at(3))
		audio.set_reverb(m, 2.2, 0.4, 0.3, 0.2, at(3))
		audio.set_bus_reverb(m, .Player, 0.5, at(3))
		audio.set_snapshot(m, audio.snapshot_neutral(), 0.6, at(6))
		audio.set_reverb(m, 0.5, 0.5, 0.05, 0.1, at(6))
		audio.set_bus_reverb(m, .Player, 0, at(6))
	case .title_to_world:
		seconds = 8
		audio.set_duck(
			m,
			0,
			{
				active = true,
				trigger = .Effects,
				target = .Music,
				threshold = 0.02,
				amount = 0.5,
				attack = 0.01,
				release = 0.4,
			},
		)
		audio.play(m, {sound = music, gain = {0.7, 0.7} * gain, bus = .Music, fade_in = 1.5})
		audio.play(
			m,
			{sound = bank.player[.Land][0], gain = g, bus = .UI, pitch = 2, start_frame = at(2.5)},
		)
		audio.set_bus_gain(m, .Music, 0.4, at(4))
		audio.play(
			m,
			{
				sound = bank.block[.Grass][.Step][1],
				gain = g * 0.2,
				bus = .Ambience,
				loop = true,
				fade_in = 2,
				start_frame = at(4),
			},
		)
		for i in 0 ..< 4 {
			audio.play(
				m,
				{
					sound = bank.block[.Dirt][.Place][i % sfx.VARIANTS],
					gain = g,
					start_frame = at(5 + 0.6 * f64(i)),
				},
			)
		}
	case .stress:
		seconds = 3
		audio.set_reverb(m, 1.4, 0.5, 0.2, 0.2)
		audio.set_bus_reverb(m, .World, 0.3)
		buses := [4]audio.Bus{.World, .Player, .Ambience, .UI}
		kinds := [4]sfx.Material{.Stone, .Wood, .Sand, .Snow}
		for i in 0 ..< audio.REAL_VOICES + 8 {
			audio.play(
				m,
				{
					sound = bank.block[kinds[i % 4]][.Break][i % sfx.VARIANTS],
					gain = {0.02, 0.02} * gain,
					pitch = 0.8 + 0.4 * f32(i % 7) / 6,
					bus = buses[i % 4],
					loop = true,
					priority = u8(i % 3),
				},
			)
		}
		audio.play(m, {sound = music, gain = {0.4, 0.4} * gain, bus = .Music})
	}
	an: audio.Analysis
	defer audio.analysis_destroy(&an)
	audio.analysis_attach(m, &an, audio.BASELINE_BUSES)
	out: [2 * BASELINE_BLOCK]f32
	for _ in 0 ..< int(seconds * BASELINE_RATE) / BASELINE_BLOCK + 10 {
		audio.mix(m, out[:])
		audio.drain(m)
	}
	audio.analysis_finish(m, &an)
	if rec := audio.capture_stop(m); rec != nil {
		os.make_directory_all(WAV_DIR)
		audio.capture_save(m, rec, fmt.tprintf("%s/%v.vxac", WAV_DIR, which))
		audio.capture_destroy(rec)
	}
	if WAV_DIR != "" {
		name := fmt.tprintf("%s/%v.wav", WAV_DIR, which)
		write_wav(name, an.audio[.Master][:])
	}
	return audio.baseline_measure(fmt.tprintf("%v", which), &an, marks[:])
}

// write_wav: interleaved stereo at BASELINE_RATE as a 32-bit float WAV.
@(private = "file")
write_wav :: proc(path: string, x: []f32) {
	out := make([dynamic]byte, 0, 44 + 4 * len(x), context.temp_allocator)
	put :: proc(out: ^[dynamic]byte, v: u32, bytes: int) {
		for i in 0 ..< bytes {append(out, byte(v >> (8 * u32(i))))}
	}
	append(&out, "RIFF")
	put(&out, u32(36 + 4 * len(x)), 4)
	append(&out, "WAVEfmt ")
	put(&out, 16, 4)
	put(&out, 3, 2)
	put(&out, 2, 2)
	put(&out, BASELINE_RATE, 4)
	put(&out, BASELINE_RATE * 8, 4)
	put(&out, 8, 2)
	put(&out, 32, 2)
	append(&out, "data")
	put(&out, u32(4 * len(x)), 4)
	for v in x {put(&out, transmute(u32)v, 4)}
	os.make_directory_all(WAV_DIR)
	if err := os.write_entire_file(path, out[:]); err != nil {
		log.warnf("audio baseline: cannot write %s: %v", path, err)
	}
}

baseline_path :: proc(which: Audio_Scenario) -> string {
	return fmt.tprintf("%s/%v.txt", BASELINE_DIR, which)
}

@(test)
test_audio_baselines :: proc(t: ^testing.T) {
	for which in Audio_Scenario {
		name := fmt.tprintf("%v", which)
		got := scenario_run(which)
		defer audio.baseline_destroy(&got)
		path := baseline_path(which)
		old_text, err := os.read_entire_file_from_path(path, context.allocator)
		defer delete(old_text)
		old, have := audio.baseline_parse(string(old_text))
		defer if have {audio.baseline_destroy(&old)}
		if ACCEPT == "all" || ACCEPT == name {
			text: string
			if have {
				text = audio.baseline_format(got, old)
			} else {
				text = audio.baseline_format(got)
			}
			os.make_directory_all(BASELINE_DIR)
			if werr := os.write_entire_file(path, text); werr != nil {
				testing.expectf(t, false, "cannot write %s: %v", path, werr)
			} else {
				log.infof("audio baseline %s accepted: %s", name, path)
			}
			continue
		}
		if err != nil || !have {
			testing.expectf(
				t,
				false,
				"%s: no baseline at %s (`build audio --accept %s` makes it)",
				name,
				path,
				name,
			)
			continue
		}
		// (CI's logs carry every OS's checksums: a run's lines are committed
		// into the baselines as `checksum <key> <value>`)
		for c in got.checksums {
			log.infof("audio baseline %s checksum %s %016x", name, c.key, c.value)
		}
		problems := audio.baseline_compare(old, got)
		for p in problems {
			testing.expectf(
				t,
				false,
				"%s: %s (`build audio --accept %s` if the change is meant)",
				name,
				p,
				name,
			)
		}
		// Frames are compared too: a scenario that changed its length changed.
		testing.expect_value(t, got.frames, old.frames)
	}
}

// A sound made louder fails its baseline, and accepting it makes it pass.
@(test)
test_audio_baseline_notices_a_changed_gain :: proc(t: ^testing.T) {
	base := scenario_run(.burst)
	louder := scenario_run(.burst, 1.5)
	defer {audio.baseline_destroy(&base); audio.baseline_destroy(&louder)}
	problems := audio.baseline_compare(base, louder)
	testing.expect(t, len(problems) > 0, "3.5 dB louder must fail")
	found := false
	for p in problems {
		if strings.contains(p, "integrated loudness") {found = true}
	}
	testing.expect(t, found, "and the loudness is what it names")
	accepted, ok := audio.baseline_parse(audio.baseline_format(louder, base))
	defer audio.baseline_destroy(&accepted)
	testing.expect(t, ok)
	testing.expect_value(t, len(audio.baseline_compare(accepted, louder)), 0)
	// The same scenario twice is the same, to the sample.
	again := scenario_run(.burst)
	defer audio.baseline_destroy(&again)
	testing.expect_value(t, base.checksums[0].value, again.checksums[0].value)
}
