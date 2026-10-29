package ogg

// Which of the generated edge-case files (testdata/edge) have no reference
// decode, and why. The reference decoder is libvorbis's through ffmpeg
// (`build ogg reference`); it cannot say what these decode to. Everything
// else has one, and the test checks the decoder against it.

reference_skipped :: proc(name: string) -> (reason: string) {
	switch name {
	case "chain_same_rate", "chain_mixed", "chain_three_empty_middle":
		return "the reference decoder does not follow a chained file past its first link"
	case "tiny_headers_only":
		return "the reference decoder cannot open a stream without audio"
	case "tiny_one_packet":
		return "no output: the first audio packet only primes the overlap"
	case "floor0_residue0":
		return(
			"the reference decoder approximates floor 0's cosines from a table (it differs by 1e-3)" \
		)
	}
	return ""
}
