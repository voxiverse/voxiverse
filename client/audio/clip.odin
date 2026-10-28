package audio

import "core:log"
import ma "vendor:miniaudio"

// decode_clip decodes a short sound file (Ogg Vorbis; whatever miniaudio's
// decoder reads) whole, mixed down to mono at its own rate. The caller has
// already checked the file's length from its header (game.ogg_check); the
// decoded length is checked again here: more than max_seconds is refused.
decode_clip :: proc(
	data: []byte,
	max_seconds: int,
	allocator := context.allocator,
) -> (
	sound: Sound,
	ok: bool,
) {
	cfg := ma.decoder_config_init(.f32, 1, 0)
	d: ma.decoder
	if r := ma.decoder_init_memory(raw_data(data), uint(len(data)), &cfg, &d); r != .SUCCESS {
		log.warnf("audio clip: not a file miniaudio can decode (result %v)", r)
		return {}, false
	}
	defer ma.decoder_uninit(&d)
	rate := d.outputSampleRate
	if rate < 8000 || rate > 192000 {
		log.warnf("audio clip: unusable rate %d", rate)
		return {}, false
	}
	limit := int(rate) * max_seconds
	samples := make([dynamic]f32, 0, 4096, allocator)
	block: [2048]f32
	for {
		got: u64
		r := ma.decoder_read_pcm_frames(&d, &block[0], len(block), &got)
		append(&samples, ..block[:got])
		if len(samples) > limit {
			log.warnf("audio clip: longer than %d s", max_seconds)
			delete(samples)
			return {}, false
		}
		if got == 0 || r != .SUCCESS {break}
	}
	if len(samples) < 2 {
		delete(samples)
		return {}, false
	}
	return {samples = samples[:], rate = rate}, true
}
