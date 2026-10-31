package engine

import "core:time"

// Loading: where the session is (Session.loading while it is on).
Loading :: struct {
	since:   time.Tick,
	arrival: bool, // through a gate (or /travel): "Arriving"
}

// loading_begin puts the loading screen up (a new session, an arrival).
loading_begin :: proc(s: ^Session, arrival: bool) {
	s.loading = Loading{time.tick_now(), arrival}
}

// Failed: the failure screen's words, and where Back goes.
Failed :: struct {
	title:  string,
	reason: string, // (allocated)
	back:   Screen,
}
