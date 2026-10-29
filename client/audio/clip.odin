package audio

import "core:log"

import "../../common/ogg"

// decode_clip decodes a short sound file (Ogg Vorbis, by common/ogg) whole,
// mixed down to mono at its own rate. The caller has already checked the
// file's length from its header (game.ogg_check); the decoded length is
// checked again here: more than max_seconds is refused.
decode_clip :: proc(
	data: []byte,
	max_seconds: int,
	allocator := context.allocator,
) -> (
	sound: Sound,
	ok: bool,
) {
	d, err := ogg.open(data)
	if err != .None {
		log.warnf("audio clip: not an Ogg Vorbis file we can decode (%v)", err)
		return {}, false
	}
	defer ogg.close(d)
	rate := ogg.info(d).rate
	if rate < 8000 || rate > 192000 {
		log.warnf("audio clip: unusable rate %d", rate)
		return {}, false
	}
	limit := int(rate) * max_seconds
	samples := make([dynamic]f32, 0, 4096, allocator)
	block: [ogg.MAX_CHANNELS * 1024]f32
	for {
		got, e := ogg.read(d, block[:], 1024)
		ch := int(ogg.info(d).channels)
		for i in 0 ..< got {
			sum: f32
			for c in 0 ..< ch {sum += block[i * ch + c]}
			append(&samples, sum / f32(ch))
		}
		if len(samples) > limit {
			log.warnf("audio clip: longer than %d s", max_seconds)
			delete(samples)
			return {}, false
		}
		if got == 0 || e != .None {break}
	}
	if len(samples) < 2 {
		delete(samples)
		return {}, false
	}
	return {samples = samples[:], rate = rate}, true
}
