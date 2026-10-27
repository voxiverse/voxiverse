package music_tool

import "core:fmt"
import "core:slice"
import "core:strconv"
import "core:strings"

// The score parser (docs/history.md, M43, has the grammar). A score is read
// in one pass into per-part lists of bars, then the bars are played out in
// order (repeats expanded), each checked against the meter in force.

Token :: struct {
	text: string,
	col:  int, // 1-based byte column
}

Ev_Kind :: enum u8 {
	Note,
	Ped_Down,
	Ped_Up,
}

Ev :: struct {
	rel:       u32, // ticks from the bar's start
	length:    u32,
	key, vel:  u8,
	kind:      Ev_Kind,
	tie:       bool,
	line, col: int,
}

Bar :: struct {
	events:    [dynamic]Ev,
	length:    u32,
	line, col: int, // of the bar line that closed it
}

Part_Build :: struct {
	name:        string,
	line:        int,
	bars:        [dynamic]Bar,
	order:       [dynamic]int, // bar indices in the order they play
	cur:         Bar,
	dur:         u32,
	vel:         u8,
	repeat_from: int, // index into order; -1 outside a repeat
	repeat_line: int,
	repeat_col:  int,
}

Mark :: struct {
	bar, beat: int,
	num, den:  u8,
	bpm:       f64,
	line, col: int,
}

Parse :: struct {
	file:               string,
	p:                  Piece,
	err:                string,
	instruments:        [dynamic]Instrument_Decl,
	meter_marks:        [dynamic]Mark,
	tempo_marks:        [dynamic]Mark,
	positions_resolved: bool,
}

Instrument_Decl :: struct {
	name:    string,
	bank:    u16,
	program: u8,
}

@(private = "file")
fail :: proc(ps: ^Parse, line, col: int, format: string, args: ..any) -> bool {
	if ps.err == "" {
		ps.err = fmt.aprintf("%s:%d:%d: %s", ps.file, line, col, fmt.aprintf(format, ..args))
	}
	return false
}

// tokenize splits a line into words. `#` starts a comment where a word would
// start (inside a word it is a sharp); a `[...]` chord and a quoted string are
// one word.
tokenize :: proc(line: string) -> []Token {
	out: [dynamic]Token
	i := 0
	for i < len(line) {
		c := line[i]
		if c == ' ' || c == '\t' || c == '\r' {
			i += 1
			continue
		}
		if c == '#' {break}
		start := i
		if c == '"' {
			i += 1
			for i < len(line) && line[i] != '"' {i += 1}
			i = min(i + 1, len(line))
		} else {
			if c == '[' {
				for i < len(line) && line[i] != ']' {i += 1}
			}
			for i < len(line) && line[i] != ' ' && line[i] != '\t' && line[i] != '\r' {i += 1}
		}
		append(&out, Token{line[start:i], start + 1})
	}
	return out[:]
}

PITCH_CLASS := [7]int{9, 11, 0, 2, 4, 5, 7} // a b c d e f g

// parse_pitch reads `c#4` at the start of s: the MIDI key and the rest.
parse_pitch :: proc(s: string) -> (key: int, rest: string, ok: bool) {
	if len(s) < 2 || s[0] < 'a' || s[0] > 'g' {return}
	pc := PITCH_CLASS[s[0] - 'a']
	i := 1
	if s[i] ==
	   '#' {pc += 1; i += 1} else if s[i] == 'b' && i + 1 < len(s) && s[i + 1] >= '0' && s[i + 1] <= '9' {pc -= 1; i += 1}
	if i >= len(s) || s[i] < '0' || s[i] > '8' {return}
	key = 12 * (int(s[i] - '0') + 1) + pc
	if key < 0 || key > 127 {return}
	return key, s[i + 1:], true
}

BASE_TICKS :: "whqest"

// parse_duration reads `q`, `h.`, `e3`, `q.3` at the start of s.
parse_duration :: proc(s: string) -> (ticks: u32, rest: string, ok: bool) {
	if len(s) == 0 {return}
	at := strings.index_byte(BASE_TICKS, s[0])
	if at < 0 {return}
	ticks = u32(4 * PPQ) >> u32(at)
	rest = s[1:]
	if len(rest) > 0 && rest[0] == '.' {ticks = ticks * 3 / 2; rest = rest[1:]}
	if len(rest) > 0 && rest[0] == '3' {ticks = ticks * 2 / 3; rest = rest[1:]}
	return ticks, rest, true
}

DYNAMICS := [?]struct {
	name: string,
	vel:  u8,
}{{"pp", 33}, {"p", 49}, {"mp", 64}, {"mf", 80}, {"f", 96}, {"ff", 112}}

@(private = "file")
num_of :: proc(ps: ^Parse, line: int, t: Token) -> (v: f64, ok: bool) {
	v, ok = strconv.parse_f64(t.text)
	if !ok {fail(ps, line, t.col, "expected a number, found '%s'", t.text)}
	return
}

@(private = "file")
int_of :: proc(ps: ^Parse, line: int, t: Token) -> (v: int, ok: bool) {
	v, ok = strconv.parse_int(t.text, 10)
	if !ok {fail(ps, line, t.col, "expected a whole number, found '%s'", t.text)}
	return
}

// score_parse reads a score. On an error err is "file:line:col: message".
score_parse :: proc(src, file: string) -> (p: Piece, err: string, ok: bool) {
	ps := Parse {
		file = file,
		p    = piece_defaults(),
	}
	ok = parse_all(&ps, src)
	if !ok {return {}, ps.err, false}
	return ps.p, "", true
}

@(private = "file")
parse_all :: proc(ps: ^Parse, src: string) -> bool {
	builds: [dynamic]Part_Build
	cur: ^Part_Build
	line_no := 0
	rest := src
	last_line := 0
	for len(rest) > 0 || line_no == 0 {
		line: string
		if nl := strings.index_byte(rest, '\n'); nl >= 0 {
			line, rest = rest[:nl], rest[nl + 1:]
		} else {
			line, rest = rest, ""
		}
		line_no += 1
		last_line = line_no
		toks := tokenize(line)
		if len(toks) == 0 {continue}
		if toks[0].text == "part" {
			if cur != nil {part_end(ps, cur) or_return}
			resolve_positions(ps) or_return
			append(&builds, Part_Build{line = line_no, vel = 80, dur = PPQ, repeat_from = -1})
			cur = &builds[len(builds) - 1]
			part_start(ps, cur, toks, line_no) or_return
			continue
		}
		if cur == nil {
			header_line(ps, toks, line_no) or_return
		} else {
			music_line(ps, cur, toks, line_no) or_return
		}
		if len(rest) == 0 {break}
	}
	if cur != nil {part_end(ps, cur) or_return}
	resolve_positions(ps) or_return
	if len(builds) == 0 {return fail(ps, last_line, 1, "the score has no part")}
	return expand(ps, builds[:])
}

// resolve_positions turns the header's meter and tempo marks (bar and beat)
// into ticks, once all the headers are in.
@(private = "file")
resolve_positions :: proc(ps: ^Parse) -> bool {
	if ps.positions_resolved {return true}
	ps.positions_resolved = true
	slice.stable_sort_by(ps.meter_marks[:], proc(a, b: Mark) -> bool {return a.bar < b.bar})
	tick: u32
	bar := 1
	cur := Meter{0, 4, 4}
	for m in ps.meter_marks {
		tick += u32(m.bar - bar) * meter_bar_ticks(cur)
		bar = m.bar
		cur = Meter{tick, m.num, m.den}
		append(&ps.p.meters, cur)
	}
	for m in ps.tempo_marks {
		// The bar's start through the meter map, then the beat.
		t: u32
		b := 1
		in_force := Meter{0, 4, 4}
		for mt, i in ps.p.meters {
			if ps.meter_marks[i].bar > m.bar {break}
			t += u32(ps.meter_marks[i].bar - b) * meter_bar_ticks(in_force)
			b = ps.meter_marks[i].bar
			in_force = mt
		}
		t += u32(m.bar - b) * meter_bar_ticks(in_force)
		t += u32(m.beat - 1) * (4 * PPQ / u32(in_force.den))
		append(&ps.p.tempos, Tempo{t, m.bpm})
	}
	return true
}

@(private = "file")
position_of :: proc(ps: ^Parse, line: int, toks: []Token, at: int) -> (bar, beat: int, ok: bool) {
	if at >= len(toks) {
		fail(ps, line, toks[len(toks) - 1].col, "expected a position after 'at'")
		return
	}
	t := toks[at]
	beat = 1
	text := t.text
	if dot := strings.index_byte(text, '.'); dot >= 0 {
		b, bok := strconv.parse_int(text[dot + 1:], 10)
		if !bok || b < 1 {
			fail(ps, line, t.col, "bad beat in position '%s'", t.text)
			return
		}
		beat = b
		text = text[:dot]
	}
	bar, ok = strconv.parse_int(text, 10)
	if !ok || bar < 1 {
		fail(ps, line, t.col, "bad bar in position '%s'", t.text)
		return 0, 0, false
	}
	return bar, beat, true
}

@(private = "file")
words_of :: proc(toks: []Token) -> [dynamic]string {
	out: [dynamic]string
	for t in toks {append(&out, t.text)}
	return out
}

@(private = "file")
header_line :: proc(ps: ^Parse, toks: []Token, line: int) -> bool {
	p := &ps.p
	key := toks[0]
	args := toks[1:]
	need :: proc(ps: ^Parse, line: int, key: Token, args: []Token, n: int) -> bool {
		if len(args) < n {
			return fail(ps, line, key.col, "'%s' needs %d value(s)", key.text, n)
		}
		return true
	}
	switch key.text {
	case "title":
		need(ps, line, key, args, 1) or_return
		t := args[0].text
		if len(t) < 2 || t[0] != '"' || t[len(t) - 1] != '"' {
			return fail(ps, line, args[0].col, "the title must be in quotes")
		}
		p.title = t[1:len(t) - 1]
	case "tempo":
		need(ps, line, key, args, 1) or_return
		bpm := num_of(ps, line, args[0]) or_return
		if bpm <= 0 {return fail(ps, line, args[0].col, "the tempo must be above 0")}
		bar, beat := 1, 1
		if len(args) > 1 {
			if args[1].text !=
			   "at" {return fail(ps, line, args[1].col, "unknown word '%s'", args[1].text)}
			bar, beat = position_of(ps, line, toks, 3) or_return
		}
		append(&ps.tempo_marks, Mark{bar = bar, beat = beat, bpm = bpm})
	case "meter":
		need(ps, line, key, args, 1) or_return
		slash := strings.index_byte(args[0].text, '/')
		n, nok := strconv.parse_int(args[0].text[:max(slash, 0)], 10)
		d, dok := 0, false
		if slash >= 0 {d, dok = strconv.parse_int(args[0].text[slash + 1:], 10)}
		if !nok || !dok || n < 1 || n > 32 || (d != 1 && d != 2 && d != 4 && d != 8 && d != 16) {
			return fail(
				ps,
				line,
				args[0].col,
				"bad meter '%s' (like 3/4; the lower number 1, 2, 4, 8 or 16)",
				args[0].text,
			)
		}
		bar := 1
		if len(args) > 1 {
			if args[1].text !=
			   "at" {return fail(ps, line, args[1].col, "unknown word '%s'", args[1].text)}
			bar, _ = position_of(ps, line, toks, 3) or_return
		}
		append(&ps.meter_marks, Mark{bar = bar, num = u8(n), den = u8(d)})
	case "key":
		need(ps, line, key, args, 2) or_return
		modes := [?]string {
			"major",
			"minor",
			"dorian",
			"phrygian",
			"lydian",
			"mixolydian",
			"aeolian",
			"locrian",
		}
		if !slice.contains(modes[:], args[1].text) {
			return fail(ps, line, args[1].col, "unknown mode '%s'", args[1].text)
		}
		p.key, p.mode = args[0].text, args[1].text
	case "mood":
		need(ps, line, key, args, 1) or_return
		for a in args {append(&p.moods, a.text)}
	case "place":
		need(ps, line, key, args, 1) or_return
		for a in args {append(&p.place, a.text)}
	case "time":
		need(ps, line, key, args, 1) or_return
		for a in args {append(&p.time, a.text)}
	case "depth":
		need(ps, line, key, args, 1) or_return
		for a in args {append(&p.depth, a.text)}
	case "worlds":
		need(ps, line, key, args, 1) or_return
		for a in args {append(&p.worlds, a.text)}
	case "loop":
		need(ps, line, key, args, 1) or_return
		switch args[0].text {
		case "yes":
			p.loop = true
		case "no":
			p.loop = false
		case:
			return fail(ps, line, args[0].col, "loop is 'yes' or 'no', not '%s'", args[0].text)
		}
	case "seed":
		need(ps, line, key, args, 1) or_return
		p.seed = u64(int_of(ps, line, args[0]) or_return)
	case "humanize":
		need(ps, line, key, args, 5) or_return
		if args[0].text != "timing" {return fail(ps, line, args[0].col, "expected 'timing'")}
		if args[2].text != "ms" {return fail(ps, line, args[2].col, "expected 'ms'")}
		if args[3].text != "velocity" {return fail(ps, line, args[3].col, "expected 'velocity'")}
		p.humanize_ms = f32(num_of(ps, line, args[1]) or_return)
		p.humanize_vel = u8(clamp(int_of(ps, line, args[4]) or_return, 0, 127))
	case "reverb":
		need(ps, line, key, args, 3) or_return
		if args[1].text != "s" {return fail(ps, line, args[1].col, "expected 's'")}
		p.reverb_rt60 = f32(num_of(ps, line, args[0]) or_return)
		p.reverb_wet = f32(num_of(ps, line, args[2]) or_return)
	case "instrument":
		need(ps, line, key, args, 3) or_return
		if args[1].text != "preset" {return fail(ps, line, args[1].col, "expected 'preset'")}
		colon := strings.index_byte(args[2].text, ':')
		bank, bok := strconv.parse_int(args[2].text[:max(colon, 0)], 10)
		prog, pok := 0, false
		if colon >= 0 {prog, pok = strconv.parse_int(args[2].text[colon + 1:], 10)}
		if !bok || !pok || bank < 0 || bank > 16383 || prog < 0 || prog > 127 {
			return fail(
				ps,
				line,
				args[2].col,
				"bad preset '%s' (bank:program, like 0:0)",
				args[2].text,
			)
		}
		append(&ps.instruments, Instrument_Decl{args[0].text, u16(bank), u8(prog)})
	case:
		return fail(ps, line, key.col, "unknown word '%s'", key.text)
	}
	return true
}

@(private = "file")
part_start :: proc(ps: ^Parse, b: ^Part_Build, toks: []Token, line: int) -> bool {
	if len(toks) < 3 {return fail(ps, line, toks[0].col, "'part' needs a name and an instrument")}
	if len(ps.p.parts) >= 15 {return fail(ps, line, toks[0].col, "at most 15 parts")}
	b.name = toks[1].text
	part := Part {
		name = b.name,
	}
	found := false
	for d in ps.instruments {
		if d.name == toks[2].text {
			part.bank, part.program = d.bank, d.program
			found = true
		}
	}
	if !found {return fail(ps, line, toks[2].col, "instrument '%s' is not declared", toks[2].text)}
	i := 3
	for i < len(toks) {
		switch toks[i].text {
		case "volume":
			if i + 2 >= len(toks) || toks[i + 2].text != "dB" {
				return fail(ps, line, toks[i].col, "'volume' is followed by a number and 'dB'")
			}
			part.volume_db = f32(num_of(ps, line, toks[i + 1]) or_return)
			i += 3
		case "pan":
			if i + 1 >= len(toks) {return fail(ps, line, toks[i].col, "'pan' needs a number")}
			v := num_of(ps, line, toks[i + 1]) or_return
			if v < -1 || v > 1 {return fail(ps, line, toks[i + 1].col, "pan is from -1 to 1")}
			part.pan = f32(v)
			i += 2
		case:
			return fail(ps, line, toks[i].col, "unknown word '%s'", toks[i].text)
		}
	}
	append(&ps.p.parts, part)
	return true
}

// bar_line closes the bar being read (a bar line with nothing since the last
// one, as at a line's start, closes nothing).
@(private = "file")
bar_line :: proc(b: ^Part_Build, line, col: int) {
	if b.cur.length == 0 {return}
	b.cur.line, b.cur.col = line, col
	append(&b.bars, b.cur)
	append(&b.order, len(b.bars) - 1)
	b.cur = {}
}

@(private = "file")
part_end :: proc(ps: ^Parse, b: ^Part_Build) -> bool {
	bar_line(b, b.line, 1)
	if b.repeat_from >= 0 {return fail(ps, b.repeat_line, b.repeat_col, "'|:' is never closed")}
	return true
}

// suffix reads `[:dur][~][!vel]` after a note or chord.
@(private = "file")
suffix :: proc(
	ps: ^Parse,
	b: ^Part_Build,
	line, col: int,
	s: string,
) -> (
	dur: u32,
	tie: bool,
	vel: u8,
	ok: bool,
) {
	rest := s
	dur, vel = b.dur, b.vel
	if len(rest) > 0 && rest[0] == ':' {
		d, r, dok := parse_duration(rest[1:])
		if !dok {
			fail(ps, line, col, "bad duration in '%s'", s)
			return
		}
		dur, rest = d, r
	}
	if len(rest) > 0 && rest[0] == '~' {tie = true; rest = rest[1:]}
	if len(rest) > 0 && rest[0] == '!' {
		v, vok := strconv.parse_int(rest[1:], 10)
		if !vok || v < 1 || v > 127 {
			fail(ps, line, col, "bad velocity in '%s'", s)
			return
		}
		vel = u8(v)
		rest = ""
	}
	if len(rest) > 0 {
		fail(ps, line, col, "unexpected '%s'", rest)
		return
	}
	return dur, tie, vel, true
}

@(private = "file")
music_line :: proc(ps: ^Parse, b: ^Part_Build, toks: []Token, line: int) -> bool {
	for t in toks {
		text := t.text
		switch {
		case text == "|":
			bar_line(b, line, t.col)
		case text == "|:":
			bar_line(b, line, t.col)
			if b.repeat_from >= 0 {return fail(ps, line, t.col, "repeats do not nest")}
			b.repeat_from, b.repeat_line, b.repeat_col = len(b.order), line, t.col
		case strings.has_prefix(text, ":|"):
			bar_line(b, line, t.col)
			if b.repeat_from < 0 {return fail(ps, line, t.col, "':|' without '|:'")}
			times := 2
			if len(text) > 2 {
				n, nok := 0, false
				if text[2] == 'x' {n, nok = strconv.parse_int(text[3:], 10)}
				if !nok ||
				   n < 1 {return fail(ps, line, t.col, "bad repeat '%s' (like :|x3)", text)}
				times = n
			}
			span := slice.clone(b.order[b.repeat_from:])
			for _ in 1 ..< times {append(&b.order, ..span)}
			b.repeat_from = -1
		case text == "ped" || text == "unped":
			kind := Ev_Kind.Ped_Down if text == "ped" else .Ped_Up
			append(&b.cur.events, Ev{rel = b.cur.length, kind = kind, line = line, col = t.col})
		case text == "r" || strings.has_prefix(text, "r:"):
			dur, _, _, ok := suffix(ps, b, line, t.col, text[1:])
			if !ok {return false}
			b.dur = dur
			b.cur.length += dur
		case text[0] == '[':
			close := strings.index_byte(text, ']')
			if close < 0 {return fail(ps, line, t.col, "chord without ']'")}
			dur, tie, vel, ok := suffix(ps, b, line, t.col + close + 1, text[close + 1:])
			if !ok {return false}
			inner := text[1:close]
			count := 0
			for pitch in strings.fields(inner) {
				at := strings.index(inner, pitch)
				key, rest, kok := parse_pitch(pitch)
				if !kok || rest != "" {
					return fail(ps, line, t.col + 1 + at, "bad pitch '%s'", pitch)
				}
				append(
					&b.cur.events,
					Ev {
						rel = b.cur.length,
						length = dur,
						key = u8(key),
						vel = vel,
						tie = tie,
						line = line,
						col = t.col,
					},
				)
				count += 1
			}
			if count == 0 {return fail(ps, line, t.col, "empty chord")}
			b.dur = dur
			b.cur.length += dur
		case:
			if d, dok := dynamic_of(text); dok {
				b.vel = d
				continue
			}
			key, rest, kok := parse_pitch(text)
			if !kok {return fail(ps, line, t.col, "unknown word '%s'", text)}
			dur, tie, vel, ok := suffix(ps, b, line, t.col + len(text) - len(rest), rest)
			if !ok {return false}
			append(
				&b.cur.events,
				Ev {
					rel = b.cur.length,
					length = dur,
					key = u8(key),
					vel = vel,
					tie = tie,
					line = line,
					col = t.col,
				},
			)
			b.dur = dur
			b.cur.length += dur
		}
	}
	return true
}

@(private = "file")
dynamic_of :: proc(s: string) -> (u8, bool) {
	for d in DYNAMICS {
		if d.name == s {return d.vel, true}
	}
	return 0, false
}

meter_at :: proc(meters: []Meter, tick: u32) -> Meter {
	m := meters[0]
	for x in meters {
		if x.at <= tick {m = x}
	}
	return m
}

// expand plays each part's bars in order, checking every bar against the
// meter in force, and ties the notes.
@(private = "file")
expand :: proc(ps: ^Parse, builds: []Part_Build) -> bool {
	p := &ps.p
	piece_finish(p)
	end := u32(0)
	for &b, pi in builds {
		tick: u32
		raws: [dynamic]Note
		tied: [dynamic]Ev
		for bi, n in b.order {
			bar := b.bars[bi]
			m := meter_at(p.meters[:], tick)
			if bar.length != meter_bar_ticks(m) {
				beats := f64(bar.length) / f64(4 * PPQ / u32(m.den))
				return fail(
					ps,
					bar.line,
					bar.col,
					"bar %d has %v beats, the meter %d/%d wants %d",
					n + 1,
					beats,
					m.num,
					m.den,
					m.num,
				)
			}
			for e in bar.events {
				switch e.kind {
				case .Note:
					append(&raws, Note{tick + e.rel, e.length, e.key, e.vel, u8(pi)})
					append(&tied, e)
				case .Ped_Down:
					append(&p.pedals, Pedal{tick + e.rel, u8(pi), true})
				case .Ped_Up:
					append(&p.pedals, Pedal{tick + e.rel, u8(pi), false})
				}
			}
			tick += bar.length
		}
		if pi == 0 {
			end = tick
		} else if tick != end {
			return fail(
				ps,
				b.line,
				1,
				"part '%s' has %d bars, the first part has %d",
				b.name,
				len(b.order),
				len(builds[0].order),
			)
		}
		merge_ties(ps, raws[:], tied[:]) or_return
		for n in raws {
			if n.length > 0 {append(&p.notes, n)}
		}
	}
	p.end = end
	piece_finish(p)
	return true
}

// merge_ties joins each tied note with the next note of the same key that
// starts where it ends (the follower's length is zeroed, and it can tie on).
@(private = "file")
merge_ties :: proc(ps: ^Parse, notes: []Note, evs: []Ev) -> bool {
	for i in 0 ..< len(notes) {
		if notes[i].length == 0 || !evs[i].tie {continue}
		at := i
		for evs[at].tie {
			end := notes[i].start + notes[i].length
			next := -1
			for j in 0 ..< len(notes) {
				if j != at &&
				   notes[j].length > 0 &&
				   notes[j].key == notes[i].key &&
				   notes[j].start == end {
					next = j
					break
				}
			}
			if next < 0 {
				return fail(
					ps,
					evs[at].line,
					evs[at].col,
					"tie to nothing: no %d note follows",
					notes[i].key,
				)
			}
			notes[i].length += notes[next].length
			notes[next].length = 0
			at = next
		}
	}
	return true
}
