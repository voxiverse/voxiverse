package bench

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "common:base"
import "common:ogg"

// The `ogg` benchmark scenario (docs/plan.md, M53c; `build bench ogg`): the
// committed music decoded whole by common/ogg and, for comparison, by
// miniaudio's decoder, each three times, the best kept. Reported as seconds of
// audio decoded per second of CPU for both and their ratio. There is no pass
// bar; the figure goes in the milestone's history entry. Each repetition also
// records every piece's decode by common/ogg (`ogg_decode`, a result file that
// `build bench compare <ref> ogg` reads: issue #67).

OGG_VERSION :: 1

OGG_MUSIC :: [7]string{"death", "deep", "discovery", "far", "meadow", "night", "title"}

ogg_main :: proc() {
	files := make([dynamic][]byte, context.temp_allocator)
	for name in OGG_MUSIC {
		data, err := os.read_entire_file(
			strings.concatenate({"assets/music/", name, ".ogg"}, context.temp_allocator),
			context.temp_allocator,
		)
		if err != nil {
			fmt.eprintfln("bench ogg: %s: %v", name, err)
			os.exit(1)
		}
		append(&files, data)
	}
	seconds: f64
	ours_best, theirs_best := max(f64), max(f64)
	result := base.Bench_Result {
		scenario = "ogg",
		version  = OGG_VERSION,
	}
	frames := 0
	for rep in 0 ..< 3 {
		start := time.tick_now()
		frames = 0
		base.metrics_start()
		for data in files {
			piece := time.tick_now()
			frames += ogg_decode_all(data)
			base.metric_add(.Ogg_Decode, f32(time.duration_milliseconds(time.tick_since(piece))))
		}
		base.bench_repetition_end(&result)
		took := time.duration_seconds(time.tick_since(start))
		ours_best = min(ours_best, took)
		seconds = f64(frames) / 48000
		start = time.tick_now()
		for data in files {_ = miniaudio_decode_all(data)}
		theirs_best = min(theirs_best, time.duration_seconds(time.tick_since(start)))
		_ = rep
	}
	ours, theirs := seconds / ours_best, seconds / theirs_best
	fmt.printfln("ogg bench: %.0f s of music", seconds)
	fmt.printfln("  common/ogg  %.0f s of audio per CPU second", ours)
	fmt.printfln("  miniaudio   %.0f s of audio per CPU second", theirs)
	fmt.printfln("  ratio       %.2f (ours over theirs)", ours / theirs)
	append(&result.counts, base.Bench_Count{"frames", frames})
	if path := base.bench_result_write(&result); path != "" {fmt.printfln("result %s", path)}
	base.bench_result_destroy(&result)
}

// ogg_decode_all: the frames of a whole file through the decoder (the samples
// are read into a block and dropped).
ogg_decode_all :: proc(data: []byte) -> int {
	d, err := ogg.open(data)
	if err != .None {return 0}
	defer ogg.close(d)
	block: [ogg.MAX_CHANNELS * 4096]f32
	total := 0
	for {
		n, e := ogg.read(d, block[:], 4096)
		if n == 0 || e != .None {break}
		total += n
	}
	return total
}
