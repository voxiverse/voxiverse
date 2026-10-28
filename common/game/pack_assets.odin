package game

import "core:encoding/endian"
import "core:fmt"
import "core:image"
import "core:image/png"

// A pack's own art and sound (assets/textures/*.png, assets/sounds/*.ogg),
// checked when the registry is built. Both files come over the network, so
// they are read by code that is bounds-checked: the PNG by Odin's decoder
// after its header says 16x16, the Ogg's length by walking its pages (the
// client's decoder only sees a file that passed).

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

// ogg_length reads an Ogg Vorbis file's sample rate and length (frames) from
// its first and last pages, without decoding it.
ogg_length :: proc(data: []u8) -> (rate: u32, frames: u64, ok: bool) {
	at := 0
	last: i64 = -1
	first := true
	for at + 27 <= len(data) {
		if string(data[at:at + 4]) != "OggS" {return 0, 0, false}
		segments := int(data[at + 26])
		if at + 27 + segments > len(data) {return 0, 0, false}
		body := 0
		for s in 0 ..< segments {body += int(data[at + 27 + s])}
		start := at + 27 + segments
		if start + body > len(data) {return 0, 0, false}
		if first {
			// The identification packet: 0x01 "vorbis", version, channels, rate.
			if body < 16 || string(data[start:start + 7]) != "\x01vorbis" {return 0, 0, false}
			rate, _ = endian.get_u32(data[start + 12:], .Little)
			first = false
		}
		granule, _ := endian.get_i64(data[at + 6:], .Little)
		if granule >= 0 {last = granule}
		at = start + body
	}
	if first || at != len(data) || last < 0 || rate == 0 {return 0, 0, false}
	return rate, u64(last), true
}

// ogg_check is the message for a sound file that is too big or too long (""
// when it is fine).
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
	return ""
}
