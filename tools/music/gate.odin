package music_tool

import "core:fmt"
import "core:os"
import "core:strings"

PENDING_FILE :: "assets/music/ear_pending.txt"
GATE_CRITIQUE_LINES :: 5 // the worst lines of the critique an error shows

// Violation is a gating measure outside its band.
Violation :: struct {
	measure: string,
	band:    Band,
	value:   f64,
}

// gate_check compares each gating measure of the ear with its band.
gate_check :: proc(e: Ear, bands: []Band) -> []Violation {
	values := measure_values(e)
	out: [dynamic]Violation
	for b in bands {
		for m, k in MEASURES {
			if m.name != b.name {continue}
			if values[k] < b.low || values[k] > b.high {
				append(&out, Violation{m.name, b, values[k]})
			}
		}
	}
	return out[:]
}

// gate_message names each measure, its band, the score's value and the
// critique's worst lines.
gate_message :: proc(e: Ear, vs: []Violation) -> string {
	b: strings.Builder
	for v in vs {
		fmt.sbprintfln(
			&b,
			"%s: %s %.4f is outside its band [%.4f, %.4f]",
			e.name,
			v.measure,
			v.value,
			v.band.low,
			v.band.high,
		)
	}
	for line, i in e.critique {
		if i >= GATE_CRITIQUE_LINES {break}
		fmt.sbprintfln(&b, "  critique: %s", line)
	}
	return strings.to_string(b)
}

// pending_read: one score name per line; blank lines and # comments skipped.
pending_read :: proc(text: string) -> (names: [dynamic]string) {
	rest := text_lf(text)
	for line in strings.split_lines_iterator(&rest) {
		s := strings.trim_space(line)
		if len(s) == 0 || s[0] == '#' {continue}
		append(&names, s)
	}
	return
}

// gate_verdict is the gate's decision on one score: pass, warn (pending) or refuse.
Verdict :: enum {
	Pass,
	Warn,
	Refuse,
}

gate_verdict :: proc(violations: []Violation, name: string, pending: []string) -> Verdict {
	if len(violations) == 0 {return .Pass}
	return .Warn if contains(pending, name) else .Refuse
}

// Gate holds what the gate reads: the model, the bands and the pending list.
Gate :: struct {
	model:   Expectation,
	bands:   [dynamic]Band,
	pending: [dynamic]string,
}

gate_load :: proc() -> (g: Gate, ok: bool) {
	bytes, err := os.read_entire_file_from_path(EXPECTATION_FILE, context.allocator)
	model, mok := expectation_read(bytes)
	if err != nil || !mok {
		fmt.eprintfln("music: cannot read %s (build music ear --train)", EXPECTATION_FILE)
		return
	}
	g.model = model
	btext, berr := os.read_entire_file_from_path(BANDS_FILE, context.allocator)
	bands, bok := bands_read(string(btext))
	if berr != nil || !bok {
		fmt.eprintfln("music: cannot read %s (build music ear --calibrate)", BANDS_FILE)
		return
	}
	g.bands = bands
	ptext, perr := os.read_entire_file_from_path(PENDING_FILE, context.allocator)
	if perr != nil {
		fmt.eprintfln("music: cannot read %s", PENDING_FILE)
		return
	}
	g.pending = pending_read(string(ptext))
	return g, true
}

// gate_run listens to the piece and decides; false refuses it (the error is printed).
gate_run :: proc(g: ^Gate, p: ^Piece, name, file: string) -> bool {
	e := listen(p, name, file, &g.model)
	vs := gate_check(e, g.bands[:])
	switch gate_verdict(vs, name, g.pending[:]) {
	case .Pass:
		return true
	case .Warn:
		fmt.eprint("warning (pending):", " ", gate_message(e, vs))
		return true
	case .Refuse:
		fmt.eprint("music: refused: ", gate_message(e, vs))
		return false
	}
	return true
}
