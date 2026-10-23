package base

import "core:testing"

@(test)
test_frame_stats_summary :: proc(t: ^testing.T) {
	s := new(Frame_Stats)
	defer free(s)
	testing.expect_value(t, frame_stats_summary(s).count, 0)
	for i in 1 ..= 100 {frame_stats_add(s, f32(i))}
	sum := frame_stats_summary(s)
	testing.expect_value(t, sum.count, 100)
	testing.expect_value(t, sum.avg, 50.5)
	testing.expect_value(t, sum.p50, 51)
	testing.expect_value(t, sum.p99, 100)
	testing.expect_value(t, sum.max, 100)
}

@(test)
test_frame_stats_window_keeps_recent :: proc(t: ^testing.T) {
	s := new(Frame_Stats)
	defer free(s)
	for _ in 0 ..< FRAME_STATS_WINDOW {frame_stats_add(s, 100)} 	// old, slow frames
	for _ in 0 ..< FRAME_STATS_WINDOW {frame_stats_add(s, 1)} 	// recent, fast
	sum := frame_stats_summary(s)
	testing.expect_value(t, sum.p99, 1) // percentiles: recent window only
	testing.expect_value(t, sum.max, 100) // max: whole run
}
