package base

import "core:slice"

// Frame_Stats summarises per-frame durations (ms): average and maximum over
// the whole run, percentiles over the most recent FRAME_STATS_WINDOW frames.
// Fixed size, no allocation while recording.

FRAME_STATS_WINDOW :: 4096

Frame_Stats :: struct {
	recent: [FRAME_STATS_WINDOW]f32,
	count:  int, // all samples ever added
	sum:    f64,
	max:    f32,
}

Frame_Summary :: struct {
	count:              int,
	avg, p50, p99, max: f32,
}

frame_stats_add :: proc(s: ^Frame_Stats, ms: f32) {
	s.recent[s.count % FRAME_STATS_WINDOW] = ms
	s.count += 1
	s.sum += f64(ms)
	s.max = max(s.max, ms)
}

frame_stats_summary :: proc(s: ^Frame_Stats) -> (sum: Frame_Summary) {
	if s.count == 0 {return}
	window := min(s.count, FRAME_STATS_WINDOW)
	sorted := make([]f32, window, context.temp_allocator)
	copy(sorted, s.recent[:window])
	slice.sort(sorted)
	at :: proc(sorted: []f32, q: f32) -> f32 {
		return sorted[min(len(sorted) - 1, int(q * f32(len(sorted))))]
	}
	return {
		count = s.count,
		avg = f32(s.sum / f64(s.count)),
		p50 = at(sorted, 0.50),
		p99 = at(sorted, 0.99),
		max = s.max,
	}
}
