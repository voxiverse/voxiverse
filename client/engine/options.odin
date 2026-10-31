package engine

Options :: struct {
	frames:        int `usage:"exit after this many frames (0: run until closed)"`,
	capture_frame: int `usage:"when started from RenderDoc, capture this frame (1 = first)"`,
	exec:          string `usage:"console commands to run at startup, separated by ';'"`,
	benchmark:     string `usage:"run a benchmark scenario (load, views, flight, edits) with fixed settings, write its result, quit"`,
	null_audio:    bool `usage:"mix into the null device (real time, no sound card) instead of the card"`,
	smoke:         bool `usage:"with --benchmark: one short repetition (CI: the scenario still works)"`,
	bench_size:    string `usage:"with --benchmark: draw at WIDTHxHEIGHT instead of 1280x720 (results under <scenario>-WIDTHxHEIGHT)"`,
	check:         string `usage:"run an exit check (fly, tour, blast) after any --exec script, and quit: fails the run if it fails"`,
	scene:         string `usage:"render a visual baseline's scene (assets/baselines/images/scenes.txt) offscreen to images/<scene>.png, and quit"`,
	version:       bool `usage:"print the version and quit"`,
}
