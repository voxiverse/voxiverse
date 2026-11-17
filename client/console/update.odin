package console

import "core:fmt"
import "core:strconv"
import "core:strings"

import "client:engine"
import "client:update"

// update_command: the developer's handle on the updater (development builds): its state,
// a check or an install by hand, the restart, and `fake`, which shows the title as in a
// phase (its screenshots: update_available, update_downloading, update_restart).
update_command :: proc(app: ^engine.App, args: []string) {
	u := &app.updater
	say :: proc(app: ^engine.App, text: string) {engine.console_print(&app.console, text)}
	if len(args) == 0 {
		s := update.status(u)
		say(
			app,
			fmt.tprintf(
				"update: %v %v version=%s percent=%d (this build: %s)",
				s.phase,
				s.failure,
				s.version,
				s.percent,
				u.version,
			),
		)
		if s.phase >= .Available {
			say(
				app,
				fmt.tprintf(
					"update: %s size=%d sha256=%s",
					u.found.url,
					u.found.size,
					update.digest_text(u.found.digest),
				),
			)
		}
		return
	}
	switch args[0] {
	case "check":
		update.check(u, force = true)
	case "install":
		update.install(u)
	case "restart":
		app.restart, app.quit = true, true
	case "fake":
		phase: update.Phase
		failure: update.Failure
		ok := len(args) >= 3
		if ok {phase, ok = enum_named(update.Phase, args[1])}
		percent := 0
		if ok && len(args) == 4 {
			if phase == .Failed {
				failure, ok = enum_named(update.Failure, args[3])
			} else {
				percent, ok = strconv.parse_int(args[3])
			}
		}
		if !ok {
			engine.console_print(
				&app.console,
				"update: fake <phase> <version> [percent | failure]",
				.Warning,
			)
			return
		}
		update.fake(u, phase, args[2], percent, failure)
	case:
		engine.console_print(&app.console, "update: check, install, restart or fake", .Warning)
	}
}

// enum_named: the value of E whose name is name, without regard to case.
@(private = "file")
enum_named :: proc($E: typeid, name: string) -> (E, bool) {
	for v in E {
		if strings.equal_fold(fmt.tprint(v), name) {return v, true}
	}
	return {}, false
}
