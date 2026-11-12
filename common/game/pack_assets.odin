package game

import "core:encoding/endian"
import "core:fmt"
import "core:hash"
import "core:image"
import "core:image/png"

import "common:ogg"

// A pack's own art and sound (assets/textures/*.png, assets/sounds/*.ogg),
// checked when the registry is built. Both files come over the network, so
// they are read by code that is bounds-checked: the PNG by Odin's decoder
// after its header says 16x16, the Ogg by `common/ogg`: scanned for its
// length and decoded once, so the client only plays a file that passed.

TEXTURE_SIZE :: 16 // a block texture is this many pixels square
MAX_PNG_BYTES :: 64 << 10
MAX_OGG_BYTES :: 1 << 20
MAX_SOUND_SECONDS :: 5
MAX_PACK_SOUND_FILES :: 128 // sound files of file-based sound sets, over all packs

Texture_Image :: [TEXTURE_SIZE * TEXTURE_SIZE][4]u8

// png_texture decodes a pack's PNG into RGBA8. The message names the fault
// (the pack's own name for the file is path); ok is false for any file that is not exactly
// 16x16 or cannot be decoded.
png_texture :: proc(
	data: []u8,
	path: string,
) -> (
	pixels: Texture_Image,
	message: string,
	ok: bool,
) {
	if len(data) > MAX_PNG_BYTES {
		return {},
			fmt.aprintf("file is %d bytes; the limit is %d", len(data), MAX_PNG_BYTES),
			false
	}
	// The header before the decoder: a PNG of a huge size packs into a few bytes.
	if len(data) < 33 || string(data[:8]) != "\x89PNG\r\n\x1a\n" || string(data[12:16]) != "IHDR" {
		return {}, "not a PNG file", false
	}
	w, _ := endian.get_u32(data[16:], .Big)
	h, _ := endian.get_u32(data[20:], .Big)
	if w != TEXTURE_SIZE || h != TEXTURE_SIZE {
		return {},
			fmt.aprintf(
				"textures are %dx%d pixels; %s is %dx%d",
				TEXTURE_SIZE,
				TEXTURE_SIZE,
				path,
				w,
				h,
			),
			false
	}
	// Check what core:image/png is handed: a truncated zlib stream panics its
	// inflater, so a texture whose deflate structure does not decode is refused
	// here, like any other undecodable file.
	if !png_ok(data) {
		return {}, fmt.aprintf("cannot be decoded as a PNG"), false
	}
	img, err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if err != nil || img == nil {
		return {}, fmt.aprintf("cannot be decoded as a PNG (%v)", err), false
	}
	defer image.destroy(img, context.temp_allocator)
	bytes := img.pixels[:]
	step := img.depth / 8
	n := TEXTURE_SIZE * TEXTURE_SIZE
	if img.width != TEXTURE_SIZE ||
	   img.height != TEXTURE_SIZE ||
	   (img.depth != 8 && img.depth != 16) ||
	   img.channels < 1 ||
	   img.channels > 4 ||
	   len(bytes) < n * img.channels * step {
		return {}, "is a PNG this game cannot read; save it as 8-bit RGBA", false
	}
	for i in 0 ..< n {
		// 16-bit samples are big endian: the high byte is the 8-bit value.
		c: [4]u8
		for k in 0 ..< img.channels {c[k] = bytes[(i * img.channels + k) * step]}
		switch img.channels {
		case 1:
			pixels[i] = {c[0], c[0], c[0], 255}
		case 2:
			pixels[i] = {c[0], c[0], c[0], c[1]}
		case 3:
			pixels[i] = {c[0], c[1], c[2], 255}
		case:
			pixels[i] = c
		}
	}
	return pixels, "", true
}

// ogg_length reads an Ogg Vorbis file's sample rate and length (frames) with
// `ogg.scan`: every page's CRC and structure and the granules, no decoding.
ogg_length :: proc(data: []u8) -> (rate: u32, frames: u64, ok: bool) {
	info, _, err := ogg.scan(data)
	if err != .None || info.rate == 0 {return 0, 0, false}
	return info.rate, info.frames, true
}

// ogg_check is the message for a sound file that is too big, too long or not
// decodable ("" when it is fine). A pack's sound is decoded once, to the end,
// into a discard buffer, so a file whose pages are good and whose audio is not
// is refused when the pack loads, not when the sound first plays.
ogg_check :: proc(data: []u8) -> string {
	if len(data) > MAX_OGG_BYTES {
		return fmt.aprintf("file is %d bytes; the limit is %d", len(data), MAX_OGG_BYTES)
	}
	rate, frames, ok := ogg_length(data)
	if !ok {return "not an Ogg Vorbis file"}
	if frames > u64(rate) * MAX_SOUND_SECONDS {
		return fmt.aprintf(
			"sound is %.1f s; the limit is %d s",
			f64(frames) / f64(rate),
			MAX_SOUND_SECONDS,
		)
	}
	d, err := ogg.open(data)
	if err != .None {return fmt.aprintf("not an Ogg Vorbis file (%v)", err)}
	defer ogg.close(d)
	discard: [2048]f32
	for {
		n, e := ogg.read(d, discard[:])
		if e != .None {return fmt.aprintf("not decodable Ogg Vorbis audio (%v)", e)}
		if n == 0 {break}
	}
	return ""
}

// A pack texture's bytes come over the network, so before `core:image/png`
// decodes the file, its chunks and its zlib stream are checked here. The
// pinned stdlib's inflater asserts on bit-underflow (a truncated stream
// panics the process), so what we hand it must be a stream whose deflate
// structure is complete. This is the "a failure inside core: is fixed in our
// layer, by checking what we hand it" rule of docs/fuzzing.md. A refused
// texture is reported to the pack's user as before; it is never decoded.
//
// A stored or compressed stream whose declared output is larger than
// MAX_PNG_RAW is refused: a 16x16 texture inflates to at most 2 064 bytes.

MAX_PNG_RAW :: 4096

// png_ok reports whether data is a whole PNG whose chunks and zlib stream are
// complete: every chunk's CRC matches, IEND is present, and the deflate
// stream decodes to at most MAX_PNG_RAW output bytes, checksummed.
png_ok :: proc(data: []u8) -> bool {
	if len(data) < 8 || string(data[:8]) != "\x89PNG\r\n\x1a\n" {return false}
	idat := make([dynamic]u8, context.temp_allocator)
	have_idat := false
	have_iend := false
	pos := 8
	for pos + 8 <= len(data) {
		length_u32, _ := endian.get_u32(data[pos:], .Big)
		length := int(length_u32)
		if length < 0 || pos + 12 + length > len(data) {return false}
		type_be := data[pos + 4:pos + 8]
		payload := data[pos + 8:pos + 8 + length]
		stored, _ := endian.get_u32(data[pos + 8 + length:], .Big)
		computed := hash.crc32(payload, hash.crc32(type_be))
		if stored != computed {return false}
		switch string(type_be) {
		case "IDAT":
			have_idat = true
			append(&idat, ..payload)
			if len(idat) > MAX_PNG_BYTES {return false}
		case "IEND":
			if length != 0 {return false}
			have_iend = true
		}
		pos += 12 + length
		if have_iend {break}
	}
	if !have_idat || !have_iend {return false}
	return zlib_ok(idat[:])
}

// ---- the zlib (deflate) validator ----

@(private = "file")
Zlib_Bits :: struct {
	data:    []u8,
	bitbuf:  u64,
	nbits:   u64,
	out:     [MAX_PNG_RAW]u8,
	out_len: int,
}

@(private = "file")
zlib_read_bits :: proc(z: ^Zlib_Bits, width: u8) -> (u32, bool) {
	for z.nbits < u64(width) {
		if len(z.data) == 0 {return 0, false}
		z.bitbuf |= u64(z.data[0]) << u64(z.nbits)
		z.data = z.data[1:]
		z.nbits += 8
	}
	v := u32(z.bitbuf & ((u64(1) << u64(width)) - 1))
	z.bitbuf >>= u64(width)
	z.nbits -= u64(width)
	return v, true
}

@(private = "file")
zlib_align_byte :: proc(z: ^Zlib_Bits) {
	drop := z.nbits % 8
	z.bitbuf >>= u64(drop)
	z.nbits -= u64(drop)
}

@(private = "file")
zlib_put :: proc(z: ^Zlib_Bits, b: u8) -> bool {
	if z.out_len >= MAX_PNG_RAW {return false}
	z.out[z.out_len] = b
	z.out_len += 1
	return true
}

@(private = "file")
Huff :: struct {
	sizes:        [16]int,
	first_symbol: [16]int,
	value:        [288]u16,
}

@(private = "file")
huff_build :: proc(lengths: []u8, h: ^Huff) -> bool {
	sizes: [16]int
	for l in lengths {
		if l > 15 {return false}
		sizes[l] += 1
	}
	code := 0
	k := 0
	for i in 1 ..< 16 {
		if sizes[i] > (1 << uint(i)) {return false}
	}
	for i in 1 ..= 15 {
		h.first_symbol[i] = k
		code += sizes[i]
		if sizes[i] != 0 && code - 1 >= (1 << uint(i)) {return false}
		code <<= 1
		k += sizes[i]
	}
	h.sizes = sizes
	idx := 0
	for l in 1 ..= 15 {
		for v, i in lengths {
			if v == u8(l) {
				h.value[idx] = u16(i)
				idx += 1
			}
		}
	}
	return true
}

@(private = "file")
huff_decode :: proc(z: ^Zlib_Bits, h: ^Huff) -> (u16, bool) {
	code: u32 = 0
	first: u32 = 0
	for l in 1 ..= 15 {
		b, ok := zlib_read_bits(z, 1)
		if !ok {return 0, false}
		code = code << 1 | u32(b)
		count := u32(h.sizes[l])
		if code >= first && code - first < count {
			return h.value[h.first_symbol[l] + int(code - first)], true
		}
		first = (first + count) << 1
	}
	return 0, false
}

@(private = "file")
ZLIB_LENGTH_BASE :: [29]u16 {
	3,
	4,
	5,
	6,
	7,
	8,
	9,
	10,
	11,
	13,
	15,
	17,
	19,
	23,
	27,
	31,
	35,
	43,
	51,
	59,
	67,
	83,
	99,
	115,
	131,
	163,
	195,
	227,
	258,
}

@(private = "file")
ZLIB_LENGTH_EXTRA :: [29]u8 {
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	0,
	1,
	1,
	1,
	1,
	2,
	2,
	2,
	2,
	3,
	3,
	3,
	3,
	4,
	4,
	4,
	4,
	5,
	5,
	5,
	5,
	0,
}

@(private = "file")
ZLIB_DIST_BASE :: [30]u16 {
	1,
	2,
	3,
	4,
	5,
	7,
	9,
	13,
	17,
	25,
	33,
	49,
	65,
	97,
	129,
	193,
	257,
	385,
	513,
	769,
	1025,
	1537,
	2049,
	3073,
	4097,
	6145,
	8193,
	12289,
	16385,
	24577,
}

@(private = "file")
ZLIB_DIST_EXTRA :: [30]u8 {
	0,
	0,
	0,
	0,
	1,
	1,
	2,
	2,
	3,
	3,
	4,
	4,
	5,
	5,
	6,
	6,
	7,
	7,
	8,
	8,
	9,
	9,
	10,
	10,
	11,
	11,
	12,
	12,
	13,
	13,
}

@(private = "file")
ZLIB_ZIGZAG :: [19]u8{16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15}

@(private = "file")
zlib_ok :: proc(data: []u8) -> bool {
	if len(data) < 2 {return false}
	cmf, flg := data[0], data[1]
	if cmf & 0x0f != 8 {return false} 	// DEFLATE
	if (cmf >> 4) > 7 {return false} 	// window at most 32 KiB
	if (u16(cmf) << 8 | u16(flg)) % 31 != 0 {return false} 	// FCHECK
	if flg & 0x20 != 0 {return false} 	// no preset dictionary
	z: Zlib_Bits
	// The tables are compile-time constants; copy them onto the stack so the hot
	// loops can index them at run time.
	length_base := ZLIB_LENGTH_BASE
	length_extra := ZLIB_LENGTH_EXTRA
	dist_base := ZLIB_DIST_BASE
	dist_extra := ZLIB_DIST_EXTRA
	zigzag := ZLIB_ZIGZAG
	z.data = data[2:]

	lit_lens: [288]u8
	dist_lens: [32]u8
	for k in 0 ..< 144 {lit_lens[k] = 8}
	for k in 144 ..< 256 {lit_lens[k] = 9}
	for k in 256 ..< 280 {lit_lens[k] = 7}
	for k in 280 ..< 288 {lit_lens[k] = 8}
	for k in 0 ..< 32 {dist_lens[k] = 5}

	final := false
	for !final {
		b, ok := zlib_read_bits(&z, 1)
		if !ok {return false}
		final = b == 1
		btype, okT := zlib_read_bits(&z, 2)
		if !okT {return false}

		lit: Huff
		dist: Huff
		switch btype {
		case 0:
			zlib_align_byte(&z)
			ln, okA := zlib_read_bits(&z, 16)
			if !okA {return false}
			nln, okB := zlib_read_bits(&z, 16)
			if !okB {return false}
			if ~u16(ln) != u16(nln) {return false}
			for _ in 0 ..< int(ln) {
				tok, okC := zlib_read_bits(&z, 8)
				if !okC {return false}
				if !zlib_put(&z, u8(tok)) {return false}
			}
			continue
		case 1:
			if !huff_build(lit_lens[:], &lit) {return false}
			if !huff_build(dist_lens[:], &dist) {return false}
		case 2:
			hlit, okD := zlib_read_bits(&z, 5)
			if !okD {return false}
			hdist, okE := zlib_read_bits(&z, 5)
			if !okE {return false}
			hclen, okF := zlib_read_bits(&z, 4)
			if !okF {return false}
			nlit := int(hlit) + 257
			ndist := int(hdist) + 1
			ntot := nlit + ndist
			cl_lengths: [19]u8
			for k in 0 ..< int(hclen) + 4 {
				tok, okG := zlib_read_bits(&z, 3)
				if !okG {return false}
				cl_lengths[zigzag[k]] = u8(tok)
			}
			cl_huff: Huff
			if !huff_build(cl_lengths[:], &cl_huff) {return false}
			lengths: [286 + 32]u8
			n := 0
			for n < ntot {
				sym, ok8 := huff_decode(&z, &cl_huff)
				if !ok8 {return false}
				if sym < 16 {
					lengths[n] = u8(sym)
					n += 1
					continue
				}
				rep: int
				fill: u8
				switch sym {
				case 16:
					if n == 0 {return false}
					r, ok5 := zlib_read_bits(&z, 2)
					if !ok5 {return false}
					rep = int(r) + 3
					fill = lengths[n - 1]
				case 17:
					r, ok6 := zlib_read_bits(&z, 3)
					if !ok6 {return false}
					rep = int(r) + 3
				case 18:
					r, ok7 := zlib_read_bits(&z, 7)
					if !ok7 {return false}
					rep = int(r) + 11
				case:
					return false
				}
				if n + rep > ntot {return false}
				for _ in 0 ..< rep {
					lengths[n] = fill
					n += 1
				}
			}
			if !huff_build(lengths[:nlit], &lit) {return false}
			if !huff_build(lengths[nlit:ntot], &dist) {return false}
		case:
			return false
		}

		for {
			sym, okI := huff_decode(&z, &lit)
			if !okI {return false}
			if sym < 256 {
				if !zlib_put(&z, u8(sym)) {return false}
				continue
			}
			if sym == 256 {break}
			idx := int(sym) - 257
			if idx >= len(length_base) {return false}
			length := int(length_base[idx])
			length_extra := length_extra[idx]
			if length_extra > 0 {
				extra, okJ := zlib_read_bits(&z, length_extra)
				if !okJ {return false}
				length += int(extra)
			}
			dsym, okK := huff_decode(&z, &dist)
			if !okK {return false}
			if dsym >= len(dist_base) {return false}
			distance := int(dist_base[dsym])
			if dist_extra[dsym] > 0 {
				extra, okL := zlib_read_bits(&z, dist_extra[dsym])
				if !okL {return false}
				distance += int(extra)
			}
			if distance > z.out_len {return false}
			for _ in 0 ..< length {
				if z.out_len >= MAX_PNG_RAW {return false}
				z.out[z.out_len] = z.out[z.out_len - distance]
				z.out_len += 1
			}
		}
	}

	zlib_align_byte(&z)
	adler: [4]u8
	for k in 0 ..< 4 {
		b4, okM := zlib_read_bits(&z, 8)
		if !okM {return false}
		adler[k] = u8(b4)
	}
	stored := u32(adler[0]) << 24 | u32(adler[1]) << 16 | u32(adler[2]) << 8 | u32(adler[3])
	return hash.adler32(z.out[:z.out_len]) == stored
}
