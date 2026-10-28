package game

import "core:testing"

@(test)
test_templates :: proc(t: ^testing.T) {
	// 3 wide, 2 high, 4 deep: a stone floor, a lamp in one corner above,
	// the rest void but one air cell.
	tmpl := Template {
		size = {3, 2, 4},
	}
	tmpl.cells = make([]u16, 3 * 2 * 4)
	defer delete(tmpl.cells)
	for &c in tmpl.cells {c = VOID}
	for z in i32(0) ..< 4 {
		for x in i32(0) ..< 3 {tmpl.cells[template_index(&tmpl, {x, 0, z})] = u16(Block.Stone)}
	}
	tmpl.cells[template_index(&tmpl, {2, 1, 0})] = u16(Block.Lamp)
	tmpl.cells[template_index(&tmpl, {0, 1, 3})] = u16(Block.Air)

	// Round trip.
	w: Writer
	writer_init(&w, context.temp_allocator)
	template_encode(&w, &tmpl, test_reg())
	back, ok := template_decode(test_reg(), w.buf[:])
	defer delete(back.cells)
	testing.expect(t, ok && back.size == tmpl.size)
	testing.expect(t, ok && string(transmute([]u8)back.cells) == string(transmute([]u8)tmpl.cells))

	// Turning: the box's sides swap; four turns are none; one turn puts
	// the lamp where a clockwise quarter turn would.
	testing.expect_value(t, rotated_size(tmpl.size, 1), [3]i32{4, 2, 3})
	for r in u8(0) ..< 4 {
		size := rotated_size(tmpl.size, r)
		lamps := 0
		for z in i32(0) ..< size.z {
			for x in i32(0) ..< size.x {
				if template_cell(&tmpl, {x, 1, z}, r) == u16(Block.Lamp) {lamps += 1}
			}
		}
		testing.expectf(t, lamps == 1, "turned %d: %d lamps", r, lamps)
	}
	testing.expect_value(t, template_cell(&tmpl, {2, 1, 0}, 0), u16(Block.Lamp))
	testing.expect_value(t, template_cell(&tmpl, {3, 1, 2}, 1), u16(Block.Lamp))
	testing.expect_value(t, template_cell(&tmpl, {0, 1, 3}, 2), u16(Block.Lamp))

	// Damaged files are refused.
	bad := make([]u8, len(w.buf), context.temp_allocator)
	copy(bad, w.buf[:])
	bad[0] ~= 1
	_, ok = template_decode(test_reg(), bad)
	testing.expect(t, !ok, "a bad magic number")
	_, ok = template_decode(test_reg(), w.buf[:len(w.buf) - 1])
	testing.expect(t, !ok, "a short file")
}
