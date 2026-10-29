package ogg

import "../../base"
import "core:math"

// Floors 0 and 1: their headers, their packets and their curves.

floor1_db_table :: proc "contextless" (t: []f32) {
	// exp(0.5469 dB * (i - 255)): the step is 140/256 dB, a dB being ln(10)/20.
	step := 0.11512925464970229 * 0.546875
	for i in 0 ..< 256 {
		t[i] = f32(base.exp_f64(f64(i - 255) * step))
	}
}

floor_parse :: proc "contextless" (r: ^Bits, a: ^Arena, s: ^Setup, f: ^Floor) -> Error {
	kind := bits_read(r, 16)
	switch kind {
	case 0:
		f.kind = 0
		f.f0_order = int(bits_read(r, 8))
		f.f0_rate = int(bits_read(r, 16))
		f.f0_map_size = int(bits_read(r, 16))
		f.f0_amp_bits = bits_read(r, 6)
		f.f0_amp_off = int(bits_read(r, 8))
		f.f0_nbooks = int(bits_read(r, 4)) + 1
		if r.eop || f.f0_order < 1 || f.f0_order > MAX_FLOOR0_ORDER {return .Bad_Setup}
		if f.f0_rate < 1 || f.f0_map_size < 1 || f.f0_amp_bits < 1 {return .Bad_Setup}
		for i in 0 ..< f.f0_nbooks {
			b := int(bits_read(r, 8))
			if b >= len(s.books) || !s.books[b].has_vq {return .Bad_Setup}
			f.f0_books[i] = u8(b)
		}
		if r.eop {return .Bad_Setup}
	case 1:
		f.kind = 1
		f.partitions = int(bits_read(r, 5))
		maxclass := -1
		for i in 0 ..< f.partitions {
			c := int(bits_read(r, 4))
			f.part_class[i] = u8(c)
			maxclass = max(maxclass, c)
		}
		for c in 0 ..= maxclass {
			cl := &f.classes[c]
			cl.dim = u8(bits_read(r, 3) + 1)
			cl.subclass = u8(bits_read(r, 2))
			if cl.subclass != 0 {
				cl.masterbook = u8(bits_read(r, 8))
				if int(cl.masterbook) >= len(s.books) {return .Bad_Setup}
			}
			for k in 0 ..< 1 << cl.subclass {
				b := int(bits_read(r, 8)) - 1
				if b >= len(s.books) {return .Bad_Setup}
				cl.subbooks[k] = i16(b)
			}
		}
		f.multiplier = int(bits_read(r, 2)) + 1
		rangebits := bits_read(r, 4)
		f.xs[0] = 0
		f.xs[1] = u16(1) << rangebits
		n := 2
		for i in 0 ..< f.partitions {
			for _ in 0 ..< f.classes[f.part_class[i]].dim {
				if n >= MAX_FLOOR1_POINTS {return .Over_Limit}
				f.xs[n] = u16(bits_read(r, rangebits))
				n += 1
			}
		}
		if r.eop {return .Bad_Setup}
		f.npoints = n
		// Sorted order; duplicates are an error.
		for i in 0 ..< n {f.order[i] = u8(i)}
		for i in 1 ..< n {
			j := i
			for j > 0 && f.xs[f.order[j - 1]] > f.xs[f.order[j]] {
				f.order[j - 1], f.order[j] = f.order[j], f.order[j - 1]
				j -= 1
			}
		}
		for i in 1 ..< n {
			if f.xs[f.order[i - 1]] == f.xs[f.order[i]] {return .Bad_Setup}
		}
		// Neighbours among the points before each.
		for i in 2 ..< n {
			lo, hi := -1, -1
			for j in 0 ..< i {
				x := f.xs[j]
				if x < f.xs[i] && (lo < 0 || x > f.xs[lo]) {lo = j}
				if x > f.xs[i] && (hi < 0 || x < f.xs[hi]) {hi = j}
			}
			if lo < 0 || hi < 0 {return .Bad_Setup}
			f.lo[i], f.hi[i] = u8(lo), u8(hi)
		}
	case:
		return .Bad_Setup
	}
	return .None
}

@(private = "file")
bark :: proc "contextless" (x: f64) -> f64 {
	return(
		13.1 * math.atan2(0.00074 * x, 1) +
		2.24 * math.atan2(0.0000000185 * x * x, 1) +
		0.0001 * x \
	)
}

// floor0_map: the bark-scale bin for each of the n spectrum bins (the spec's map).
floor0_map :: proc "contextless" (f: ^Floor, out: []i32, n: int) {
	rate := f64(f.f0_rate)
	size := f64(f.f0_map_size)
	scale := size / bark(0.5 * rate)
	for i in 0 ..< n {
		v := int(bark(rate * f64(i) / f64(2 * n)) * scale) // in range: bark is bounded by the scale
		out[i] = i32(min(f.f0_map_size - 1, v))
	}
	out[n] = -1
}

// floor_decode reads one channel's floor from the packet. false: the
// channel is unused in this block (zero floor, no residue).
floor_decode :: proc "contextless" (s: ^Setup, f: ^Floor, r: ^Bits, ch: int) -> bool {
	if f.kind == 1 {return floor1_decode(s, f, r, ch)}
	return floor0_decode(s, f, r, ch)
}

@(private = "file")
floor1_decode :: proc "contextless" (s: ^Setup, f: ^Floor, r: ^Bits, ch: int) -> bool {
	if bits_read(r, 1) == 0 {return false}
	range_tab := [4]int{256, 128, 86, 64}
	rng := range_tab[f.multiplier - 1]
	y: [MAX_FLOOR1_POINTS]int
	rb := u32(ilog(rng - 1))
	y[0] = int(bits_read(r, rb))
	y[1] = int(bits_read(r, rb))
	off := 2
	for i in 0 ..< f.partitions {
		cl := &f.classes[f.part_class[i]]
		cdim := int(cl.dim)
		cbits := u32(cl.subclass)
		csub := (1 << cbits) - 1
		cval := 0
		if cbits > 0 {
			cval = codebook_scalar(&s.books[cl.masterbook], r)
			if cval < 0 {return false}
		}
		for j in 0 ..< cdim {
			book := cl.subbooks[cval & csub]
			cval >>= cbits
			if book >= 0 {
				v := codebook_scalar(&s.books[book], r)
				if v < 0 {return false}
				y[off + j] = v
			}
		}
		off += cdim
	}
	if r.eop {return false}
	fy := s.f_y[ch]
	flag := s.f_flag[ch]
	fy[0], fy[1] = i32(y[0]), i32(y[1])
	flag[0], flag[1] = true, true
	for i in 2 ..< f.npoints {
		lo, hi := int(f.lo[i]), int(f.hi[i])
		pred := render_point(int(f.xs[lo]), int(fy[lo]), int(f.xs[hi]), int(fy[hi]), int(f.xs[i]))
		val := y[i]
		highroom := rng - pred
		lowroom := pred
		room := (highroom if highroom < lowroom else lowroom) * 2
		if val != 0 {
			flag[lo], flag[hi], flag[i] = true, true, true
			if val >= room {
				if highroom > lowroom {
					fy[i] = i32(val - lowroom + pred)
				} else {
					fy[i] = i32(pred - val + highroom - 1)
				}
			} else if val & 1 != 0 {
				fy[i] = i32(pred - (val + 1) / 2)
			} else {
				fy[i] = i32(pred + val / 2)
			}
		} else {
			flag[i] = false
			fy[i] = i32(pred)
		}
	}
	return true
}

@(private = "file")
render_point :: proc "contextless" (x0, y0, x1, y1, x: int) -> int {
	dy := y1 - y0
	adx := x1 - x0
	ady := abs(dy)
	off := ady * (x - x0) / adx
	return y0 - off if dy < 0 else y0 + off
}

// floor1_apply multiplies the channel's spectrum by the floor curve.
floor1_apply :: proc "contextless" (s: ^Setup, f: ^Floor, ch, n: int) {
	spec := s.spec[ch][:n]
	fy := s.f_y[ch]
	flag := s.f_flag[ch]
	tab := s.floor1_db
	mult := f.multiplier
	line :: proc "contextless" (spec: []f32, tab: []f32, x0, y0, x1, y1, n: int) {
		dy := y1 - y0
		adx := x1 - x0
		ady := abs(dy)
		basev := dy / adx
		sy := basev - 1 if dy < 0 else basev + 1
		ady -= abs(basev) * adx
		x, y, err := x0, y0, 0
		if x < n {spec[x] *= tab[clamp(y, 0, 255)]}
		for x += 1; x < min(x1, n); x += 1 {
			err += ady
			if err >= adx {
				err -= adx
				y += sy
			} else {
				y += basev
			}
			spec[x] *= tab[clamp(y, 0, 255)]
		}
	}
	lx := 0
	ly := int(fy[f.order[0]]) * mult
	hx, hy := lx, ly
	for i in 1 ..< f.npoints {
		p := int(f.order[i])
		if !flag[p] {continue}
		hx = int(f.xs[p])
		hy = int(fy[p]) * mult
		if lx < n {line(spec, tab, lx, ly, hx, hy, n)}
		lx, ly = hx, hy
	}
	if hx < n {
		for x in hx ..< n {spec[x] *= tab[clamp(hy, 0, 255)]}
	}
}

@(private = "file")
floor0_decode :: proc "contextless" (s: ^Setup, f: ^Floor, r: ^Bits, ch: int) -> bool {
	amp := int(bits_read(r, f.f0_amp_bits))
	if amp == 0 || r.eop {return false}
	bn := int(bits_read(r, u32(ilog(f.f0_nbooks))))
	if bn >= f.f0_nbooks {return false}
	cb := &s.books[f.f0_books[bn]]
	coef := s.f_coef[ch]
	got := 0
	last: f32
	for got < f.f0_order {
		e := codebook_scalar(cb, r)
		if e < 0 {return false}
		for d in 0 ..< cb.dim {
			if got >= f.f0_order {break}
			coef[got] = cb.vecs[e * cb.dim + d] + last
			got += 1
		}
		last = coef[got - 1]
	}
	maxamp := f64(int(1) << f.f0_amp_bits - 1)
	s.f_amp[ch] = f32(f64(amp) * f64(f.f0_amp_off) / maxamp)
	return true
}

floor0_apply :: proc "contextless" (s: ^Setup, f: ^Floor, ch, n: int, blockflag: int) {
	spec := s.spec[ch][:n]
	coef := s.f_coef[ch]
	bmap := f.f0_map[blockflag]
	order := f.f0_order
	amp := f64(s.f_amp[ch])
	off := f64(f.f0_amp_off)
	// amp is amplitude * offset / (2^bits - 1), from floor0_decode.
	cosc: [MAX_FLOOR0_ORDER]f64
	for j in 0 ..< order {cosc[j] = base.cos_f64(f64(coef[j]))}
	i := 0
	for i < n {
		omega := PI_F64 * f64(bmap[i]) / f64(f.f0_map_size)
		cw := base.cos_f64(omega)
		p, q: f64
		if order & 1 != 0 {
			p = 1 - cw * cw
			q = 0.25
			for j := 0; j <= (order - 3) / 2; j += 1 {
				d := cosc[2 * j + 1] - cw
				p *= 4 * d * d
			}
			for j := 0; j <= (order - 1) / 2; j += 1 {
				d := cosc[2 * j] - cw
				q *= 4 * d * d
			}
		} else {
			p = (1 - cw) / 2
			q = (1 + cw) / 2
			for j in 0 ..< order / 2 {
				d := cosc[2 * j + 1] - cw
				p *= 4 * d * d
			}
			for j in 0 ..< order / 2 {
				d := cosc[2 * j] - cw
				q *= 4 * d * d
			}
		}
		lin := f32(base.exp_f64(0.11512925 * (amp / math.sqrt(p + q) - off)))
		cur := bmap[i]
		for i < n && bmap[i] == cur {
			spec[i] *= lin
			i += 1
		}
	}
}
