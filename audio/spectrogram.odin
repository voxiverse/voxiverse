package audio

import "core:math"

// A spectrogram of audio as pixels, for `build audiodump -spectrogram`: time
// across, frequency up on a log axis (SPEC_LOW_HZ to the Nyquist limit or
// SPEC_HIGH_HZ), level as colour from SPEC_FLOOR_DB (dark) to 0 dB (bright) of a
// full-scale sine, on the mono sum. A 4096-point Hann window, hops chosen so
// the image is at most `max_width` wide.

SPEC_WINDOW :: 4096
SPEC_HEIGHT :: 384
SPEC_LOW_HZ :: 40.0
SPEC_HIGH_HZ :: 20000.0
SPEC_FLOOR_DB :: -100.0

// spectrogram_rgba returns 8-bit RGBA pixels, rows top to bottom (the highest
// frequency first). Audio shorter than a window is one column, padded.
spectrogram_rgba :: proc(
	x: []f32,
	rate: u32,
	max_width: int,
	allocator := context.allocator,
) -> (
	pixels: []u8,
	width, height: int,
) {
	frames := len(x) / 2
	hop := max(SPEC_WINDOW / 8, (frames - SPEC_WINDOW) / max(max_width, 1) + 1)
	width = max(1, (frames - SPEC_WINDOW) / hop + 1)
	height = SPEC_HEIGHT
	pixels = make([]u8, width * height * 4, allocator)
	re := make([]f64, SPEC_WINDOW)
	im := make([]f64, SPEC_WINDOW)
	win := make([]f64, SPEC_WINDOW)
	defer {delete(re); delete(im); delete(win)}
	for i in 0 ..< SPEC_WINDOW {win[i] = 0.5 - 0.5 * math.cos(2 * math.PI * f64(i) / SPEC_WINDOW)}
	// (a full-scale sine of amplitude 1 reads sum(win) / 2 in its bin)
	norm := 0.0
	for w in win {norm += w}
	norm *= 0.5
	top := min(SPEC_HIGH_HZ, 0.5 * f64(rate))
	bin_hz := f64(rate) / SPEC_WINDOW
	for col in 0 ..< width {
		at := col * hop
		for i in 0 ..< SPEC_WINDOW {
			v := 0.0
			if j := at + i; j < frames {v = 0.5 * f64(x[2 * j] + x[2 * j + 1])}
			re[i], im[i] = v * win[i], 0
		}
		fft(re, im)
		for row in 0 ..< height {
			// The row's band on the log axis; the loudest bin in it.
			f0 := SPEC_LOW_HZ * math.pow(top / SPEC_LOW_HZ, f64(row) / f64(height))
			f1 := SPEC_LOW_HZ * math.pow(top / SPEC_LOW_HZ, f64(row + 1) / f64(height))
			lo := int(f0 / bin_hz)
			hi := max(int(f1 / bin_hz), lo + 1)
			peak := 0.0
			for k in lo ..< min(hi, SPEC_WINDOW / 2) {
				peak = max(peak, math.sqrt(re[k] * re[k] + im[k] * im[k]))
			}
			db := 20 * math.log10(max(peak / norm, 1e-12))
			c := spectrogram_colour(clamp((db - SPEC_FLOOR_DB) / -SPEC_FLOOR_DB, 0, 1))
			p := ((height - 1 - row) * width + col) * 4
			pixels[p], pixels[p + 1], pixels[p + 2], pixels[p + 3] = c.r, c.g, c.b, 255
		}
	}
	return
}

// spectrogram_colour: 0 (silent) to 1 (full scale): black, blue, magenta,
// orange, pale yellow; each step brighter than the one before.
spectrogram_colour :: proc(t: f64) -> (c: [3]u8) {
	stops := [5][3]f64{{0, 0, 0}, {30, 20, 110}, {170, 40, 130}, {245, 130, 40}, {255, 245, 190}}
	s := clamp(t, 0, 1) * 4
	i := min(int(s), 3)
	u := s - f64(i)
	for k in 0 ..< 3 {c[k] = u8(stops[i][k] + (stops[i + 1][k] - stops[i][k]) * u + 0.5)}
	return
}
