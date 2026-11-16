package console

import "client:engine"
import "client:screen"
import "common:game"
import "core:log"
import "core:strconv"
import "core:strings"
import "core:time"


// Startup scripts (--exec "cmd; cmd; ..."): console commands run in order,
// one batch per frame, with script-only commands that pause it:
//
//	ticks <n>        resume once the server has run n more ticks: our own server
//	                 runs them back to back, as fast as it can (core.hurry), so
//	                 `ticks 600` (half a minute of play) takes a second or two;
//	                 someone else's keeps its time (n ticks of the clock)
//	wait <frames>    resume after that many frames
//	sleep <seconds>  resume after that much time (frame counts vary with vsync):
//	                 for what the clock and not the game decides; `ticks` for play
//	wait_world       resume once the world has loaded and finished meshing
//	                 (no world, or it failed: the run fails and quits)
//	wait_joined      resume once the session plays, its world perhaps still
//	                 loading (no world, or it failed: as wait_world)
//
//	--exec "singleplayer; wait_world; ticks 200; wait_world; screenshot world; quit"
//
// Settings changes made by scripts are never saved (App.scripted).

script_init :: proc(s: ^engine.Script, text: string, allocator := context.allocator) {
	s^ = {}
	s.commands = strings.split(text, ";", allocator)
}

script_destroy :: proc(s: ^engine.Script) {
	delete(s.commands)
}

// script_run runs commands until the script waits or ends; once per frame.
// script_done: every command has run and nothing is waited for.
script_done :: proc(s: ^engine.Script) -> bool {
	return(
		s.next >= len(s.commands) &&
		s.wait == 0 &&
		s.until == {} &&
		!s.wait_world &&
		!s.wait_joined &&
		!s.hurried \
	)
}

script_run :: proc(app: ^engine.App, s: ^engine.Script) {
	if s.wait > 0 {
		s.wait -= 1
		return
	}
	if s.until != {} {
		if time.tick_diff(time.tick_now(), s.until) > 0 {return}
		s.until = {}
	}
	if s.hurried {
		if app.session != nil && engine.server_hurrying(app.session) {return}
		s.hurried = false
	}
	if s.wait_world || s.wait_joined {
		if app.session == nil || app.session.state == .Failed {
			log.error("script wait_world: no world to wait for (see above); quitting")
			app.script_failed = true
			app.quit = true
			return
		}
		if s.wait_world && !screen.world_settled(app) {return}
		if s.wait_joined && app.session.state != .Playing {return}
		s.wait_world, s.wait_joined = false, false
	}
	app.scripted = true
	defer app.scripted = false
	for s.next < len(s.commands) {
		line := strings.trim_space(s.commands[s.next])
		s.next += 1
		args := strings.fields(line, context.temp_allocator)
		if len(args) == 0 {continue}
		switch args[0] {
		case "wait":
			n, ok := strconv.parse_int(args[1] if len(args) > 1 else "")
			if !ok || n < 0 {
				log.warnf("script bad wait line=%q", line)
				continue
			}
			s.wait = n
			return
		case "ticks":
			n, ok := strconv.parse_int(args[1] if len(args) > 1 else "")
			if !ok || n < 0 {
				log.warnf("script bad ticks line=%q", line)
				continue
			}
			if app.session != nil && engine.server_hurry(app.session, n) {
				s.hurried = true
			} else {
				s.until = time.tick_add(time.tick_now(), time.Duration(n) * game.TICK_DURATION)
			}
			return
		case "wait_world":
			s.wait_world = true
			return
		case "wait_joined":
			s.wait_joined = true
			return
		case "sleep":
			seconds, ok := strconv.parse_f64(args[1] if len(args) > 1 else "")
			if !ok || seconds < 0 {
				log.warnf("script bad sleep line=%q", line)
				continue
			}
			s.until = time.tick_add(time.tick_now(), time.Duration(seconds * f64(time.Second)))
			return
		case:
			console_execute(app, line)
		}
	}
}
