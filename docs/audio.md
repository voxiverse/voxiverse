# Audio

The audio engine, the sounds it plays and the tools that make and inspect them. The mixer, the
buses, the voices and the effects are our Odin (`client/audio`); the Ogg Vorbis decoder is
`common/ogg`; miniaudio opens the output device and does nothing else. Ground rule 2 in
[design.md](design.md) (handles, not pointers) applies to voices; determinism of the mixer is in
[determinism.md](determinism.md); switches and keys in the running game are in
[debugging.md](debugging.md#sound).

## Rules

| Area | Rule |
|---|---|
| Not used | FMOD, Wwise and OpenAL Soft: proprietary, or binaries beside the executable. |
| Device | miniaudio, through `client/audio/device.odin` only (a lint rejects `vendor:miniaudio` anywhere else). It is asked for 48 kHz stereo and converts if the card differs. The device callback runs on the card's thread at real-time priority and measures itself (duration, clock drift). No device (a server, CI) is not an error: the game runs silent. |
| Output | Stereo `f32`, 48 kHz (`DEVICE_RATE`). |
| Music codec | Ogg Vorbis, decoded at run time by `common/ogg`. Encoded only by the dev tool, with `oggenc` or `ffmpeg` found on the `PATH`; the encoded files are committed, so nobody else needs either. |
| Music sources | A text score (`assets/music/*.score`, diff-friendly) or a standard MIDI file (`.mid`) becomes one note list; `build music` renders either. Scores export to `.mid`. |
| Packaging | The release executable carries all music (`#load` in `client/music/data.odin`): the committed Ogg files are q5 stereo, about 0.8 MB a minute. |
| Loudness | Music is mastered to -20 LUFS integrated with a -1 dB true-peak ceiling (`tools/music/master.odin`). The master has a look-ahead limiter at -1 dBFS (a listener option can lower the ceiling to at most -0.1). A K-weighted loudness meter (BS.1770) is in the engine for tests and analysis. |
| Real time | The audio thread never allocates, locks or logs. The game thread and the audio thread talk through two lock-free rings (commands in, voice-end events out); a full command ring drops the command and counts it. |
| Cost | The mix of 64 real voices stays under 5% of one core: a 480-frame block (10 ms) is timed by the `audio` scenario of `build bench` in a release build (`BENCH_AUDIO_BUDGET`). |
| Sound effects | Synthesized at start-up by `client/sfx` (no recordings): layers of filtered noise bursts and decaying tones at 16 kHz, crushed to 8 bits, three variants of each sound, resampled to the device rate when registered. |

## The engine

- **Buses.** A tree: `Master` <- `Music`, `Ambience`, `Effects` (<- `World`, `Player`, `UI`).
  Per bus: gain, mute, a low-pass, a send to the reverb, and a **duck** level. A duck (up to
  `MAX_DUCKS` = 4) lowers a target bus while a trigger bus is louder than a threshold, with
  attack and release. A **snapshot** is a named set of bus gains and cut-offs (Underwater,
  Paused, Death, Loading) crossfaded in over a time. Everything that moves is smoothed across
  the block, so nothing clicks. Buses are processed leaves first.
- **Voices.** `MAX_VOICES` = 128 voices, `REAL_VOICES` = 64 of them mixed each block. A voice is
  a generational handle (`Voice_Id`) the game keeps to stop it, fade it, or change its gain,
  pitch or cut-off. Priority, then audibility, decides which voices are real; a virtual voice
  keeps its place in time (position, fades, loop) at no cost and resumes when it is audible
  again. A play carries a start frame for sample-accurate scheduling, an optional loop range,
  a fade-in and a per-voice low-pass. Resampling is a Kaiser-windowed sinc (32 taps a side,
  100 dB stop band) that stretches its kernel when the read step is above 1, so pitching up
  does not alias.
- **Sources.** Sounds in memory (mono, or stereo for music; any rate; up to `MAX_SOUNDS` = 1024,
  of which the last 128 are a pack's, replaced whenever the pack set changes; `sound_replace`
  swaps one sound's samples while the device runs: its voices fade out in 5 ms, the swap
  happens at a block's start, and a `Replaced` event on the return ring (`Voice_Event.kind`)
  says the old samples are free), and **streams**
  (music, long beds): a decoder thread fills a ring from an Ogg file in memory, an underrun is
  counted and never skipped over (the voice holds its place and is silent for that block),
  and a looping stream crossfades its end into its start with equal power inside the decoder.
  Offline (tests, capture replay) a stream decodes inline, so the output never depends on a
  thread's timing.
- **Effects.** State-variable low-pass filters (per bus and per voice), a feedback-delay-network reverb (8 delay lines
  mixed through a Hadamard matrix, damping, 6 early reflections, RT60 set live), a compressor
  on Master (the listener's Night option) and the look-ahead limiter with true-peak detection.
- **Spatial.** `spatial_gain` turns an offset from the listener and a facing into left and
  right gains: loudness falls with the square of the remaining distance, silent beyond the
  range, panned by direction but never fully to one side, and centred up close. Sounds in the
  world play where they happened, relative to the camera (`client/engine/sounds.odin`).
- **Listener options** (applied to Master before the limiter): mono, swap channels, headphone
  cross-feed (the other ear gets the lows), the Night compressor, and the limiter ceiling.
- **Events.** The session records what happened (`Sound_Kind`: break, place, step, land, hurt,
  die, launch, explosion, weapon shots, hit markers) and the app plays each frame's events as
  voices with a random pitch drawn on the game thread. A pack's sound sets (`assets/sounds/`: Ogg files by action, up to
  `SOUND_VARIANTS` variants) are used for the blocks that name them; an action a set gives no
  file takes the break sound's.
- **Music director** (`client/music`). A state machine the app feeds with the session, the place
  and the time; the app carries out its actions on the mixer, so tests need no mixer. It plays
  the title piece on the menus, lets the world's music come and go in waits and tracks (one at
  a time, chosen by the track's place, time, depth and world tags in its metadata `.json`),
  and punctuates deaths and discoveries with stingers. Every number is a `music.*` console
  variable.

## Music pipeline

`build music [<name>...] [--force] [--wav <dir>] [--midi]` renders `assets/music/*.score|*.mid`
to Ogg Vorbis with a metadata `.json` beside each (title, tags, length, and the hashes of the
score and the SoundFont, so a piece is re-rendered only when an input changes); `build music
--audition <name> [--from <s>]` plays one.

- The renderer is our own SoundFont 2 reader and sample renderer in Odin (`tools/music`; no
  FluidSynth): presets, instruments, key and velocity zones, loops, a volume envelope, pan,
  tuning and a low-pass filter, with the engine's reverb on the render, mastered to the target
  above, encoded with `oggenc` or `ffmpeg`.
- The fonts are downloaded, not committed, each pinned by the SHA-256 of its archive like glslang
  and unpacked into `build/tools/soundfont/<font>` (`7zz`, `7z`, `7za` or `bsdtar` for `.7z`, `tar`
  for `.tar.xz`). `VX_SOUNDFONT=<file.sf2>` renders the piano with another font. A score names
  its instruments, any number: `instrument harp font freepats_harp preset 0:0` (`font` is
  optional: the upright piano), and a piece is re-rendered when the font of any instrument it
  uses changes (a piece that uses only the upright keeps the hash it always had).
- **SFZ** is read in place by the renderer (`tools/music/sfz.odin`), not converted: `<control>`
  (`default_path`), `<global>`, `<master>`, `<group>` and `<region>` with inheritance; `sample`
  (PCM WAV, 16/24/32-bit or float, a stereo file mixed to mono), `lokey`, `hikey`, `key`,
  `pitch_keycenter`, `lovel`, `hivel`, `offset`, `end`, `loop_mode`, `loop_start`, `loop_end`,
  `ampeg_attack/hold/decay/sustain/release`, `volume`, `pan`, `tune`, `transpose`; other opcodes
  are ignored. Each `.sfz` file is a preset named by its file name (`preset cello_sustain`).
- `build music --audition-instruments [--wav <dir>]` renders the C2-C7 scale (C major, then a C7)
  of every preset of every font, at pp (32), mf (64) and ff (110), to
  `<font>.<preset>.wav` (default `build/music-out/instruments`), to listen to.

### The instruments

Every font is CC0 1.0 by its download page, read before it was pinned; the credit lines are in
`assets/music/CREDITS.txt`.

| Font name | What | Source |
|---|---|---|
| `piano` | Upright Piano KW (default) | FreePats |
| `felt` | the upright with a soft hammer: velocities compressed toward pp (`12 + 0.45 v`), a low-pass that opens with velocity (500 + 40 v Hz), the first 150 ms starting 3 dB quieter, the release 1.6 times longer | made from `piano` |
| `freepats_harp` | Concert Harp (small SF2) | FreePats |
| `freepats_bells` | Tubular Bells (small SF2) | FreePats |
| `freepats_timpani` | Timpani (SF2) | FreePats |
| `freepats_choir` | Synth Pad Choir (SF2) | FreePats |
| `freepats_sweep` | Sweep Pad (SF2) | FreePats |
| `freepats_bowed` | Synth Pad Bowed (SF2) | FreePats |
| `freepats_synthstrings` | Synth Strings 1 (SF2) | FreePats |
| `freepats_recorder` | Wooden Recorder (SF2) | FreePats |
| `freepats_ocarina` | Ocarina (SF2) | FreePats |
| `freepats_glass` | Glass (glasses of water) (SF2) | FreePats |

Planned, not yet pinned: the other FreePats fonts (Timpani, the synth pads, Recorder, Ocarina,
Glass) and the Versilian VSCO 2 Community Edition (SFZ, strings, flute, horn, celesta,
glockenspiel).
- `assets/music/CREDITS.txt` holds each source's credit line; the game's credits screen shows it.
  Read a download's license on its own page before committing anything rendered from it.

### Motifs and form in a score

Scores can state a figure once and develop it. Every existing score reads the same (a test
hashes the notes of each committed score).

- `motif <name> | g4:q a4:e b4:e d5:h |` declares a figure, on one line, anywhere before its
  use: notes, rests (`r:q`) and dynamic words, no chords, no pedal. A note with no velocity of
  its own takes the part's dynamic when played. The `|` only separates.
- `play <name> [ops]` is a line of its own in a part. The operations apply in the order
  written: `transpose <semitones>`, `degrees <n>` (along the piece's `key`, so in D dorian two
  degrees up takes d to f), `invert` (around the first note), `retrograde` (the notes reversed,
  each keeping its duration), `augment <n>` / `diminish <n>` (durations times or over n),
  `vary <seed>` (at most one note in four moves a scale degree, never the first or last, never a
  tied note; the same seed gives the same result). The figure fills bars by the meter; a note
  crossing a bar line is cut and tied.
- `section <name> [repeat <n>]` ... `end` records lines of a part without playing them;
  `form A A B A'` plays them in that order (`repeat` plays a section n times each time it is
  named). A name with a prime (`A'`) plays the section with `vary` applied to each of its
  `play` lines that has none (the seed comes from the line). A part that declares sections
  needs a `form`; sections do not nest.
- `cresc` / `dim` before a run of notes ramp their velocity linearly to the next dynamic word
  (`mp cresc c4:q d4 e4 f4 | f`); a note with its own `!velocity` stays out of the ramp.
- An articulation follows a note or chord, after its duration and tie: `^stacc` (half the
  length), `^ten` (full length, velocity +6), `^legato` (held 30 ms into the next note).

The ear (below) lists each motif a piece states: how many times, how many varied, and the bar of
each statement (a prime marks a varied one).

### The ear

An agent cannot listen, so `build music ear [<name>...] [--json]` reads each score (or `.mid`)
through the parser the renderer uses and prints what a listener reacts to, then a critique an
author can act on. Nothing is gated yet; `assets/baselines/music/ear.txt` is its output on every
score (rewrite it with `./build.sh music ear > assets/baselines/music/ear.txt`). `--json` writes
every measure and every critique line for tools.

- **The melody** is the part marked `melody` in the score (`part bells piano melody volume -6 dB`),
  else the part with the highest mean pitch; at each onset its highest note. `stepwise` (share of
  intervals of 2 semitones or less), `big_leaps` (over 9), `leap_recovered` (of leaps of 5 or more,
  the share followed by a step of at most 4 the other way; 1 when there are no leaps),
  `motif_return` (of the figures of three intervals with the ratios of their durations, the share
  heard again), `range` in semitones, and `longest_run` (intervals in one direction).
- **Surprise** (`expectation.odin`): the mean information content, in bits a note, of the melody's
  intervals under a variable-order (0 to 3) model with Witten-Bell interpolation, as IDyOM does;
  intervals are clamped to +-12 semitones, all maths is f64 and iteration order is fixed, so every
  OS gets the same number. The model is `assets/music/expectation.bin` (versioned binary, the
  counts per context and the names of the pieces it was trained on). A piece whose name is in that
  list is scored with its own counts subtracted, so no piece is scored by a model that saw it.
  `build music ear --train [<dir>]` trains on every `.mid` in the directory (default
  `tools/music/testdata/corpus`) and writes the file; today that is the calibration subset. A
  master of the subset scores lower surprise than its `scramble_in_key` copy (a test).
- **The whole.** A note under `ped` sounds until `unped`, at half weight after its written length.
  `harmony_fit`: in each half bar, the share of sounding weight inside the best chord (major,
  minor, diminished, sus4, dominant 7th, minor 7th; a 4-note chord pays 0.15 x 4/12 so it does
  not win by size); `strong_beat_clash`: melody notes starting on a half bar outside that chord.
  `roughness`: Sethares' sensory dissonance of each pair of sounding notes (6 harmonics,
  amplitudes 0.88^k, a pedalled tail at half loudness), the worst pair per slice, the
  beat-weighted mean and 95th percentile. `accomp_variety`: distinct bars (pitches and rhythm)
  over the non-empty bars of the parts that are not the melody.
- **The motifs** (only for scores that `play` any): `m: stated 4 times, 1 varied; bars 1 9 17 25'`.
- **The critique** lists, worst first, what the author can fix, with the score's line and column:
  `meadow.score:31:12: bar 7: leap of 10 semitones (b5 to d7) not answered` (leaps from 7
  semitones), `bars 1-52: no figure of the melody comes back`, `bars 9-40: the arp part plays one
  bar 32 times` (from 8 times), `bar 12 beat 1: c7 over G major (pedalled from bar 11)`. The text
  prints 30 lines a piece; `--json` has all.

**The calibration subset.** `tools/music/testdata/corpus/` holds six small public-domain MIDI files
(two Bach chorales, a Satie Gymnopedie, Greensleeves, two Chopin preludes); `SOURCES.txt` gives each
one's source page and licence (Public Domain or CC0 only). The tests read them with `midi_read`
and put two scramblers (`scramble.odin`) on them, each a pure function of a piece and a seed:
`scramble_shuffle` shuffles the pitches within each part and keeps rhythm and length;
`scramble_in_key` replaces each note by a random note of the piece's 7 commonest pitch classes
within 7 semitones of the original and keeps rhythm. Neither is used by `build music` yet.

## Tools

- `build audio` runs the audio baselines (`assets/baselines/audio/`: `burst`, `cave_walk`,
  `music_session`, `stress`, `title_to_world`, and the music director's `music_hour.decisions`);
  `--accept <scenario|all>` rewrites them and `--wav <dir>` renders each to a WAV to listen to.
  A baseline holds a checksum per OS (see determinism.md).
- A **capture** records everything the audio thread was told (each command with the frame it
  was applied on, and each mix call's size), so any mix can be made again bit for bit on the
  same build. The running game keeps the last minute or so in memory with a mixer-state
  snapshot every 15 s, and writes `captures/audio-<n>.vxac` on F9, with the `audio_capture`
  console command, and when the mixer underruns (rate-limited). `build audiodump` reads one:
  the timeline, the engine's decision for each voice, loudness, any bus as a WAV (`-report`,
  `-bus:`, `-wav:`).
- The **freeze-and-solo inspector** (dev builds, F8) replays the newest capture window through
  a mixer of its own and loops the last half second in place of the live output, listing the
  buses and the frozen voices with what the engine decided about each, a spectrum of Master
  and the device's counters. A button solos a voice, a second press mutes it, a third clears
  it. Streams are not replayed.
- `build sfx` reads the recipes (`assets/sounds/*.recipe`) and
  writes every variant to `build/sounds/<name>.<v>.wav` (24-bit mono, 48 kHz) and a
  `build/sounds/report.txt`: each measure of each variant against the target range of the
  sound's class, `ok` or `OUT`. It exits 1 if any is out. The same check runs as a unit test
  (`client/audio/synth/recipes_test.odin`).
- The **synth library** (`client/audio/synth`) is the next generation of effects, not yet
  wired into the game (the recipes in assets/sounds exist and are checked, the game still plays
  `client/sfx`): float at 48 kHz, no lo-fi stage. A **recipe** is text (`sound <name>`
  ... `end`; grammar and errors in `recipe.odin`'s header) of layers, each a source (noise,
  tone, click, modal, granular, formant, bubble), an envelope, a filter, a level and a delay,
  then the sound's EQ. `generate(sound, variant)` draws every range once per variant, in the
  order the values appear, from `base.rng_make(seed * 64 + variant)`; all maths is f64 on
  `base`'s sin, cos and exp, so a recipe gives the same samples on every OS (the tests hold
  hashes). `gain` is the sound's peak in dBFS (default -2). Water has no modal table: it is
  made of Minnaert bubbles.
- **Targets** (`assets/sounds/targets.txt`): one row per class of sound
  (`block_break`, `block_place`, `block_step`, `land`, `creature_hurt`, `creature_die`, `launch`,
  `boom`) and, for the block classes, one centroid range per material (the word of the sound's
  name before its first dot). Measured on each variant at 48 kHz with the sound's own gain:
  `peak` (sample peak, dBFS); `loud` (the loudest 400 ms momentary loudness, LUFS, of the sound
  padded with 400 ms of silence, one ear: playing it in both ears reads 3 LU more); `length`
  (to the end of the last 5 ms RMS frame above -60 dB re peak); `decay` (the peak to the first
  5 ms RMS frame under -30 dB re peak); `centroid` (Hz, of the whole sound); `low`, `mid`,
  `high` (energy below 250 Hz, 250-2500 Hz and above 2500 Hz, dB re the total; a row may give
  floors). The numbers are first estimates for the reference analysis to replace.
- Every layer of a recipe that begins at once starts 1.2 ms in (`delay 0.0012`): the sound's
  first millisecond is faded in to leave no click, and an onset inside it is mostly lost.
- The **null device** asks for a block every 10 ms by the wall clock and discards it, so CI's
  smoke run exercises the real callback path; the **file device** mixes as fast as it can and
  writes a WAV at close (at most 300 s), for scripted runs and listening to a scenario.
