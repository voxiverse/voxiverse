package ogg

// Residues 0, 1 and 2.

residue_parse :: proc "contextless" (r: ^Bits, s: ^Setup, res: ^Residue) -> Error {
	kind := int(bits_read(r, 16))
	if kind > 2 {return .Bad_Setup}
	res.kind = kind
	res.begin = int(bits_read(r, 24))
	res.end = int(bits_read(r, 24))
	res.psize = int(bits_read(r, 24)) + 1
	res.nclass = int(bits_read(r, 6)) + 1
	res.classbook = int(bits_read(r, 8))
	if r.eop || res.classbook >= len(s.books) || res.end < res.begin {return .Bad_Setup}
	// The classification code is decoded to nclass digits per word.
	cdim := s.books[res.classbook].dim
	if res.psize > MAX_BLOCK {return .Bad_Setup}
	cascade: [MAX_RES_CLASSES]u8
	for i in 0 ..< res.nclass {
		low := bits_read(r, 3)
		high: u32
		if bits_read(r, 1) != 0 {high = bits_read(r, 5)}
		cascade[i] = u8(high << 3 | low)
	}
	for i in 0 ..< res.nclass {
		for k in 0 ..< 8 {
			res.books[i][k] = -1
			if cascade[i] & (1 << uint(k)) != 0 {
				b := int(bits_read(r, 8))
				if b >= len(s.books) || !s.books[b].has_vq {return .Bad_Setup}
				// Residue 0 stripes each codeword over the partition.
				if kind == 0 && res.psize % s.books[b].dim != 0 {return .Bad_Setup}
				res.books[i][k] = i16(b)
			}
		}
	}
	_ = cdim
	if r.eop {return .Bad_Setup}
	return .None
}

// residue_decode adds the residue vectors of the channels in `chans` into
// vec[ch] (n coefficients each; for type 2, one interleaved vector). skip:
// per channel, the "do not decode" flags. Running out of bits ends the
// decode where it stands, the rest stays zero.
residue_decode :: proc "contextless" (
	s: ^Setup,
	res: ^Residue,
	r: ^Bits,
	vecs: [][]f32,
	skip: []bool,
	n: int,
) {
	nch := len(vecs)
	limit_begin := min(res.begin, n)
	limit_end := min(res.end, n)
	to_read := limit_end - limit_begin
	if to_read <= 0 {return}
	psize := res.psize
	nparts := to_read / psize
	if nparts == 0 {return}
	cb := &s.books[res.classbook]
	cwords := cb.dim
	classes := s.res_class
	// classes[ch * nparts + p]
	for pass in 0 ..< 8 {
		p := 0
		for p < nparts {
			if pass == 0 {
				for ch in 0 ..< nch {
					if skip[ch] {continue}
					v := codebook_scalar(cb, r)
					if v < 0 {return}
					for i := cwords - 1; i >= 0; i -= 1 {
						if p + i < nparts {classes[ch * nparts + p + i] = u8(v % res.nclass)}
						v /= res.nclass
					}
				}
			}
			for i := 0; i < cwords && p < nparts; i += 1 {
				for ch in 0 ..< nch {
					if skip[ch] {continue}
					cl := int(classes[ch * nparts + p])
					book := int(res.books[cl][pass])
					if book < 0 {continue}
					bk := &s.books[book]
					off := limit_begin + p * psize
					out := vecs[ch]
					dim := bk.dim
					if res.kind == 0 {
						step := psize / dim
						for k in 0 ..< step {
							e := codebook_scalar(bk, r)
							if e < 0 {return}
							for j in 0 ..< dim {
								out[off + k + j * step] += bk.vecs[e * dim + j]
							}
						}
					} else {
						for k := 0; k < psize; k += dim {
							e := codebook_scalar(bk, r)
							if e < 0 {return}
							for j in 0 ..< min(dim, psize - k) {
								out[off + k + j] += bk.vecs[e * dim + j]
							}
						}
					}
				}
				p += 1
			}
		}
	}
}
