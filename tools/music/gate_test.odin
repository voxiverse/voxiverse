package music_tool

import "core:testing"

BANDS_TEXT :: #load("../../assets/music/ear_bands.txt", string)
PENDING_TEXT :: #load("../../assets/music/ear_pending.txt", string)
EXPECTATION_BYTES :: #load("../../assets/music/expectation.bin")

@(private = "file")
SCORES := [?]struct {
	name: string,
	src:  string,
} {
	{"death", SCORE_DEATH},
	{"deep", SCORE_DEEP},
	{"discovery", SCORE_DISCOVERY},
	{"far", SCORE_FAR},
	{"ignite", SCORE_IGNITE},
	{"meadow", SCORE_MEADOW},
	{"night", SCORE_NIGHT},
	{"title", SCORE_TITLE},
}

@(private = "file")
test_gate :: proc(t: ^testing.T, pending: []string) -> (g: Gate) {
	model, ok := expectation_read(EXPECTATION_BYTES)
	testing.expect(t, ok, "expectation.bin reads")
	bands, bok := bands_read(BANDS_TEXT)
	testing.expect(t, bok, "ear_bands.txt reads")
	g.model = model
	g.bands = bands
	for n in pending {append(&g.pending, n)}
	return
}

@(private = "file")
violations :: proc(g: ^Gate, p: ^Piece, name: string) -> []Violation {
	return gate_check(listen(p, name, name, &g.model), g.bands[:])
}

@(test)
test_gate_refuses_scramble_accepts_master :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	g := test_gate(t, nil)
	accepted, refused := 0, 0
	for f in CORPUS {
		p, _, ok := midi_read(transmute([]u8)f.data)
		if !ok {continue}
		name := f.name[:len(f.name) - len(".mid")]
		if len(violations(&g, &p, name)) > 0 {continue}
		accepted += 1
		testing.expect(t, gate_verdict(violations(&g, &p, name), name, nil) == .Pass)
		q := scramble_in_key(p, SEED_IN_KEY)
		vs := violations(&g, &q, name)
		testing.expectf(t, len(vs) > 0, "%s: its scramble_in_key copy passes the gate", name)
		if len(vs) > 0 {refused += 1}
		testing.expect(t, gate_verdict(vs, name, nil) == .Refuse)
		msg := gate_message(listen(&q, name, name, &g.model), vs)
		testing.expect(t, len(msg) > 0)
	}
	testing.expect(t, accepted > 0, "a master of the subset passes the gate")
	testing.expect_value(t, refused, accepted)
}

@(test)
test_gate_pending_warns_others_refuse :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	g := test_gate(t, []string{"night"})
	p, msg, ok := score_parse(SCORE_NIGHT, "night.score")
	testing.expectf(t, ok, "%s", msg)
	vs := violations(&g, &p, "night")
	testing.expect(t, len(vs) > 0, "night fails today")
	testing.expect(t, gate_verdict(vs, "night", g.pending[:]) == .Warn)
	testing.expect(t, gate_verdict(vs, "night", nil) == .Refuse)
	testing.expect(t, gate_run(&g, &p, "night", "night.score"), "a pending score renders")
	testing.expect(
		t,
		!gate_run(&g, &p, "other", "other.score"),
		"a non-pending failing score refuses",
	)
}

@(test)
test_gate_pending_list_is_honest :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	g := test_gate(t, nil)
	pending := pending_read(PENDING_TEXT)
	for name in pending {
		found := false
		for s in SCORES {
			if s.name != name {continue}
			found = true
			p, msg, ok := score_parse(s.src, name)
			testing.expectf(t, ok, "%s", msg)
			testing.expectf(
				t,
				len(violations(&g, &p, name)) > 0,
				"%s is in ear_pending.txt but passes the gate: remove it",
				name,
			)
		}
		testing.expectf(t, found, "ear_pending.txt names %s, which is not a score", name)
	}
}
