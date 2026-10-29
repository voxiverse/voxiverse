package ogg

// One audio packet: floors, residues, inverse coupling, the inverse MDCT, the
// window and the overlap with the block before.

decode_packet :: proc "contextless" (d: ^Decoder, pkt: []byte) -> (frames: int, err: Error) {
	s := &d.s
	r := bits_init(pkt)
	if bits_read(&r, 1) != 0 {return 0, .Bad_Packet}
	mode_i := int(bits_read(&r, s.mode_bits))
	if r.eop || mode_i >= len(s.modes) {return 0, .Bad_Packet}
	mode := s.modes[mode_i]
	flag := 1 if mode.blockflag else 0
	n := s.block[flag]
	next_n := n
	if mode.blockflag {
		_ = bits_read(&r, 1)
		next_n = s.block[1] if bits_read(&r, 1) != 0 else s.block[0]
		if r.eop {return 0, .Bad_Packet}
	}
	half := n / 2
	ch := s.channels
	mp := &s.mappings[mode.mapping]

	for c in 0 ..< ch {
		zero(s.spec[c][:half])
		sm := 0 if mp.nsub == 1 else int(mp.mux[c])
		f := &s.floors[mp.floor[sm]]
		s.f_used[c] = floor_decode(s, f, &r, c)
	}
	// A coupled pair is decoded if either of its channels has a floor.
	for c in 0 ..< ch {s.res_skip[c] = !s.f_used[c]}
	for i in 0 ..< mp.ncoupling {
		m, a := mp.coupling[i].mag, mp.coupling[i].ang
		if !s.res_skip[m] || !s.res_skip[a] {s.res_skip[m], s.res_skip[a] = false, false}
	}
	for sm in 0 ..< mp.nsub {
		res := &s.residues[mp.residue[sm]]
		vecs: [MAX_CHANNELS][]f32
		skip: [MAX_CHANNELS]bool
		chs: [MAX_CHANNELS]int
		nch := 0
		for c in 0 ..< ch {
			if (0 if mp.nsub == 1 else int(mp.mux[c])) == sm {
				chs[nch] = c
				skip[nch] = s.res_skip[c]
				nch += 1
			}
		}
		if nch == 0 {continue}
		if res.kind == 2 {
			all := true
			for i in 0 ..< nch {all = all && skip[i]}
			if all {continue}
			tmp := s.res_tmp[:nch * half]
			zero(tmp)
			one := [1][]f32{tmp}
			sk := [1]bool{false}
			residue_decode(s, res, &r, one[:], sk[:], nch * half)
			for i in 0 ..< nch {
				dst := s.spec[chs[i]][:half]
				for k in 0 ..< half {dst[k] += tmp[k * nch + i]}
			}
		} else {
			for i in 0 ..< nch {vecs[i] = s.spec[chs[i]][:half]}
			residue_decode(s, res, &r, vecs[:nch], skip[:nch], half)
		}
	}
	d.left = bits_left(&r)
	// Inverse channel coupling, last step first.
	for i := mp.ncoupling - 1; i >= 0; i -= 1 {
		mg := s.spec[mp.coupling[i].mag][:half]
		an := s.spec[mp.coupling[i].ang][:half]
		for k in 0 ..< half {
			m, a := mg[k], an[k]
			nm, na: f32
			if m > 0 {
				if a > 0 {nm, na = m, m - a} else {na, nm = m, m + a}
			} else {
				if a > 0 {nm, na = m, m + a} else {na, nm = m, m - a}
			}
			mg[k], an[k] = nm, na
		}
	}
	for c in 0 ..< ch {
		spec := s.spec[c][:half]
		if !s.f_used[c] {
			zero(spec)
		} else {
			sm := 0 if mp.nsub == 1 else int(mp.mux[c])
			f := &s.floors[mp.floor[sm]]
			if f.kind == 1 {floor1_apply(s, f, c, half)} else {floor0_apply(s, f, c, half, flag)}
		}
		imdct(&s.mdct[flag], spec, s.blk[c][:n], s.dct[:half], s.fft[:half])
	}

	// The window: the slope on each side is that of the smaller neighbour.
	pn := d.prev_n if d.have_prev else n
	ls := min(n, pn)
	rs := min(n, next_n)
	lslope := s.slope[0] if ls == s.block[0] else s.slope[1]
	rslope := s.slope[0] if rs == s.block[0] else s.slope[1]
	a := n / 4 - ls / 4
	b := n / 4 - rs / 4
	for c in 0 ..< ch {
		w := s.blk[c][:n]
		for j in 0 ..< half {
			switch {
			case j < a:
				w[j] = 0
			case j < a + ls / 2:
				w[j] *= lslope[j - a]
			}
		}
		for jj in 0 ..< half {
			switch {
			case jj < b:
			case jj < b + rs / 2:
				w[half + jj] *= rslope[rs / 2 - 1 - (jj - b)]
			case:
				w[half + jj] = 0
			}
		}
	}
	if d.have_prev {
		frames = pn / 4 + n / 4
		for c in 0 ..< ch {
			out := s.pcm[c][:frames]
			ovl := s.ovl[c]
			w := s.blk[c]
			base := n / 4 - pn / 4
			for i in 0 ..< frames {
				v: f32
				if i < pn / 2 {v = ovl[i]}
				if base + i >= 0 {v += w[base + i]}
				out[i] = v
			}
		}
	}
	for c in 0 ..< ch {copy(s.ovl[c][:half], s.blk[c][half:n])}
	d.have_prev = true
	d.prev_n = n
	return frames, .None
}

@(private)
zero :: proc "contextless" (s: []f32) {
	for &v in s {v = 0}
}
