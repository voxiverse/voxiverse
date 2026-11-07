package music_tool

import "core:testing"

@(private = "file")
subset :: proc(t: ^testing.T) -> (pieces: [dynamic]Piece, names: [dynamic]string) {
	for f in CORPUS {
		p, err, ok := midi_read(transmute([]u8)f.data)
		testing.expectf(t, ok, "%s: %s", f.name, err)
		if ok {
			append(&pieces, p)
			append(&names, f.name[:len(f.name) - len(".mid")])
		}
	}
	return
}

@(test)
test_calibrate_subset_gates :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pieces, names := subset(t)
	c := calibrate(pieces[:], names[:])
	n := 0
	for k in 0 ..< len(MEASURES) {
		if c.gating[k] {
			n += 1
			testing.expectf(
				t,
				c.auc_in_key[k] >= GATE_AUC,
				"%s gates at AUC %v",
				MEASURES[k].name,
				c.auc_in_key[k],
			)
		}
	}
	testing.expect(t, n > 0, "at least one measure gates on the subset")
	testing.expect(t, c.gating[1], "surprise gates")
}

@(test)
test_calibrate_is_deterministic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pieces, names := subset(t)
	a := calibrate(pieces[:], names[:])
	b := calibrate(pieces[:], names[:])
	testing.expect_value(t, bands_write(gating_bands(a)), bands_write(gating_bands(b)))
}

@(test)
test_bands_round_trip :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	defer free_all(context.temp_allocator)
	pieces, names := subset(t)
	c := calibrate(pieces[:], names[:])
	text := bands_write(gating_bands(c))
	back, ok := bands_read(text)
	testing.expect(t, ok, "the file reads back")
	testing.expect_value(t, len(back), len(gating_bands(c)))
	testing.expect_value(t, bands_write(back[:]), text)
	_, bad := bands_read("stepwise\t0.1\n")
	testing.expect(t, !bad, "a short line is refused")
}

@(test)
test_auc_ties_count_half :: proc(t: ^testing.T) {
	testing.expect_value(t, auc({1, 2, 3, 4}, {0, 2, 4, 5}, true), 0.375)
	testing.expect_value(t, auc({1, 2}, {2, 3}, false), 1.0)
}
