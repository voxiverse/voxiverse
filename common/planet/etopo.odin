package planet

// NOAA ETOPO5: 5 arc-minute global relief, big-endian i16 metres, 4320 columns (0 to
// 360 degrees east, column 0 starting at 0 E) by 2160 rows (row 0 starting at 90 N).
ETOPO5_WIDTH :: 4320
ETOPO5_HEIGHT :: 2160
ETOPO5_SIZE :: ETOPO5_WIDTH * ETOPO5_HEIGHT * 2

// relief_from_etopo5 averages the source to the relief grid, each cell the mean of the
// source cells it covers, weighted by the overlap (the source's cell edges are on
// multiples of 5 arc-minutes, the grid's are not).
relief_from_etopo5 :: proc(
	src: []u8,
	width := RELIEF_WIDTH,
	height := RELIEF_HEIGHT,
	allocator := context.allocator,
) -> (
	r: Relief,
	ok: bool,
) {
	if len(src) != ETOPO5_SIZE {return}
	elevation :: proc(src: []u8, col, row: int) -> f64 {
		k := (row * ETOPO5_WIDTH + col) * 2
		return f64(i16(u16(src[k]) << 8 | u16(src[k + 1])))
	}
	r = relief_make(width, height, allocator)
	// Source cells per grid cell, across and down.
	sx := f64(ETOPO5_WIDTH) / f64(width)
	sy := f64(ETOPO5_HEIGHT) / f64(height)
	for j in 0 ..< height {
		y0, y1 := f64(j) * sy, f64(j + 1) * sy
		for i in 0 ..< width {
			// The grid's column 0 starts at -180, the source's at 0: half a turn on.
			x0 := f64(i) * sx + f64(ETOPO5_WIDTH) / 2
			x1 := x0 + sx
			sum, weight := 0.0, 0.0
			for row := int(y0); f64(row) < y1 && row < ETOPO5_HEIGHT; row += 1 {
				wy := min(y1, f64(row + 1)) - max(y0, f64(row))
				for c := int(x0); f64(c) < x1; c += 1 {
					wx := min(x1, f64(c + 1)) - max(x0, f64(c))
					w := wx * wy
					sum += w * elevation(src, c % ETOPO5_WIDTH, row)
					weight += w
				}
			}
			v := sum / weight
			r.elevation[j * width + i] = i16(v + 0.5 if v >= 0 else v - 0.5)
		}
	}
	return r, true
}
