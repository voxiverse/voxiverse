package client

import "core:slice"
import "core:testing"

// A minute at 240 fps is 14 400 frames, more than PERF_FRAMES: the count and the worst
// are still exact, and the sample covers the whole minute, a hitch near its end too.
@(test)
test_perf_sample_covers_the_minute :: proc(t: ^testing.T) {
	r := new(Reporter)
	defer free(r)
	N :: 14_400
	for i in 0 ..< N {
		us := u32(4_000) // the minute's first half at 4 ms a frame, the second at 2 ms
		if i >= N / 2 {us = 2_000}
		if i == N - 100 {us = 80_000} 	// one hitch, late
		perf_sample(r, us)
	}
	testing.expect_value(t, r.seen, N)
	testing.expect_value(t, r.worst, u32(80_000))
	testing.expect_value(t, r.frame_n, PERF_FRAMES)
	// Half the sample from each half of the minute (the first PERF_FRAMES alone would
	// all be 4 ms).
	slow := slice.count(r.frames[:], u32(4_000))
	testing.expectf(
		t,
		slow > PERF_FRAMES * 4 / 10 && slow < PERF_FRAMES * 6 / 10,
		"4 ms frames in the sample: %d",
		slow,
	)
}
