package bench

import ma "vendor:miniaudio"

// The last place the game's tree decodes with miniaudio: the speed bench's
// comparison. Deleted with the rest of miniaudio by "Audio devices in Odin".
miniaudio_decode_all :: proc(data: []byte) -> int {
	cfg := ma.decoder_config_init(.f32, 2, 0)
	d: ma.decoder
	if ma.decoder_init_memory(raw_data(data), uint(len(data)), &cfg, &d) != .SUCCESS {return 0}
	defer ma.decoder_uninit(&d)
	block: [2 * 4096]f32
	total := 0
	for {
		got: u64
		ma.decoder_read_pcm_frames(&d, raw_data(block[:]), 4096, &got)
		if got == 0 {break}
		total += int(got)
	}
	return total
}
