package client

import "core:time"

// The app's clock. The program reads the OS's; a test fixes it and moves it
// (app_clock_fix, app_clock_advance), as a Link takes `now`: nothing a test checks
// waits for time to pass. Read time through these in anything a test drives.

App_Clock :: struct {
	fixed: bool,
	tick:  time.Tick, // the fixed clock's monotonic time
	wall:  time.Time, // ... and its calendar time
}

// A fixed clock starts at an arbitrary calendar time (2023-11-14 22:13:20 UTC).
CLOCK_FIXED_WALL :: 1_700_000_000 * i64(time.Second)

app_clock_fix :: proc(app: ^App) {
	app.clock = {
		fixed = true,
		tick = {_nsec = 1_000 * i64(time.Second)},
		wall = {_nsec = CLOCK_FIXED_WALL},
	}
}

app_tick :: proc(app: ^App) -> time.Tick {
	return app.clock.tick if app.clock.fixed else time.tick_now()
}

app_wall :: proc(app: ^App) -> time.Time {
	return app.clock.wall if app.clock.fixed else time.now()
}

// app_clock_advance moves a fixed clock on.
app_clock_advance :: proc(app: ^App, d: time.Duration) {
	assert(app.clock.fixed, "only a fixed clock is moved")
	app.clock.tick = time.tick_add(app.clock.tick, d)
	app.clock.wall = time.time_add(app.clock.wall, d)
}

// app_since: the time from `then` to the app's now.
app_since :: proc(app: ^App, then: time.Tick) -> time.Duration {
	return time.tick_diff(then, app_tick(app))
}
