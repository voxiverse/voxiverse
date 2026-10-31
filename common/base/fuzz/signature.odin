package fuzz

import "core:math/bits"

// Outcome signatures: what a target returns. A mix of small facts about what the decoder
// did (the error, the stage, how much it consumed).

sig_mix :: proc(parts: ..u64) -> u64 {
	h := u64(0xcbf29ce484222325)
	for p in parts {h = (h ~ p) * 0x100000001b3; h ~= h >> 29}
	return h
}

// sig_bucket: the size of n on a log scale (0 for 0).
sig_bucket :: proc(n: int) -> u64 {
	return u64(bits.len(u64(max(n, 0))))
}

// sig_text: a hash of the letters of a message (its digits and quoted parts say which input,
// not which path).
sig_text :: proc(s: string) -> u64 {
	h := u64(0xcbf29ce484222325)
	for i in 0 ..< min(len(s), 80) {
		c := s[i]
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == ' ' {
			h = (h ~ u64(c)) * 0x100000001b3
		}
	}
	return h
}

// run_smoke: what the suite runs for each target: the regression files, the seeds, 200 cases
// at seed 84.
run_smoke :: proc(t: ^Target) -> Report {
	return run_target(t, {seed = 84, cases = 200, out_dir = "build/fuzz", regress = true})
}

// report_destroy frees a report.
report_destroy :: proc(r: ^Report) {
	for f in r.failures {delete(f)}
	delete(r.failures)
}
