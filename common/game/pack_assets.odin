package game

import "core:encoding/endian"
import "core:fmt"
import "core:image"
import "core:image/png"

import "common:ogg"

// A pack's own art and sound (assets/textures/*.png, assets/sounds/*.ogg),
// checked when the registry is built. Both files come over the network, so
// they are read by code that is bounds-checked: the PNG by Odin's decoder
// after its header says 16x16, the Ogg by `common/ogg` (M53c): scanned for its
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
	img, err := png.load_from_bytes(data, {.alpha_add_if_missing}, context.temp_allocator)
	if err != nil || img == nil {
		return {}, fmt.aprintf("cannot be decoded as a PNG (%v)", err), false
	}
	defer image.destroy(img, context.temp_allocator)
	bytes := img.pixels.buf[:]
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
