package planet

import "core:testing"

@(test)
test_relief_roundtrip :: proc(t: ^testing.T) {
	// A synthetic source (more than one stored block of data) goes through the format.
	r := relief_make(300, 150)
	defer relief_destroy(&r)
	for k in 0 ..< len(r.elevation) {
		r.elevation[k] = i16(k * 7 - 9000)
	}
	data := relief_encode(r)
	defer delete(data)
	back, ok := relief_decode(data)
	defer relief_destroy(&back)
	testing.expect(t, ok)
	testing.expect_value(t, back.width, 300)
	testing.expect_value(t, back.height, 150)
	testing.expect_value(t, relief_hash(back), relief_hash(r))

	// Damage is refused, not read.
	for n in ([]int{0, 3, 15, 16, len(data) / 2, len(data) - 1}) {
		_, ok = relief_decode(data[:n])
		testing.expect(t, !ok)
	}
	bad := make([]u8, len(data))
	defer delete(bad)
	copy(bad, data)
	bad[0] = 'X'
	_, ok = relief_decode(bad)
	testing.expect(t, !ok)
}

@(test)
test_relief_from_etopo5_averages :: proc(t: ^testing.T) {
	// A flat 100 m world with one 4 x 4-cell block (a 2 x 2 cell of the 1080 x 540 grid) at 1000 m.
	src := make([]u8, ETOPO5_SIZE)
	defer delete(src)
	put :: proc(src: []u8, col, row: int, v: i16) {
		k := (row * ETOPO5_WIDTH + col) * 2
		src[k], src[k + 1] = u8(u16(v) >> 8), u8(u16(v))
	}
	for row in 0 ..< ETOPO5_HEIGHT {
		for col in 0 ..< ETOPO5_WIDTH {put(src, col, row, 100)}
	}
	// Source columns 2160..2163 are -180 .. -179.67 in the grid; rows 0..3 are the north edge.
	for row in 0 ..< 4 {
		for col in 2160 ..< 2164 {put(src, col, row, -1000)}
	}
	r, ok := relief_from_etopo5(src, 1080, 540)
	defer relief_destroy(&r)
	testing.expect(t, ok)
	testing.expect_value(t, relief_at(r, 0, 0), -1000) // 1080 x 540 cells are 4 x 4 source cells
	testing.expect_value(t, relief_at(r, 1, 0), 100)
	testing.expect_value(t, relief_at(r, 0, 1), 100)
	testing.expect_value(t, relief_at(r, 540, 270), 100)

	_, ok = relief_from_etopo5(src[:100])
	testing.expect(t, !ok)
}
