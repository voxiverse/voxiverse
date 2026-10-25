package client

import "core:log"
import "core:math"
import "core:strconv"
import "core:strings"
import "core:time"

import "../game"

// Startup scripts (--exec "cmd; cmd; ..."): console commands run in order,
// one batch per frame, with two script-only commands that pause it:
//
//	wait <frames>    resume after that many frames
//	sleep <seconds>  resume after that much time (frame counts vary with vsync)
//	wait_world       resume once the world has loaded and finished meshing
//	                 (no world, or it failed: the run fails and quits)
//
//	--exec "singleplayer; wait_world; screenshot world; wait 2; quit"
//
// Settings changes made by scripts are never saved (App.scripted).

Script :: struct {
	commands:   []string, // into the --exec text (lives for the program)
	next:       int,
	wait:       int, // frames left to wait
	wait_world: bool,
	until:      time.Tick, // sleeping until then (zero: not)
}

script_init :: proc(s: ^Script, text: string, allocator := context.allocator) {
	s^ = {}
	s.commands = strings.split(text, ";", allocator)
}

script_destroy :: proc(s: ^Script) {
	delete(s.commands)
}

// script_run runs commands until the script waits or ends; once per frame.
// script_done: every command has run and nothing is waited for.
script_done :: proc(s: ^Script) -> bool {
	return s.next >= len(s.commands) && s.wait == 0 && s.until == {} && !s.wait_world
}

script_run :: proc(app: ^App, s: ^Script) {
	if s.wait > 0 {
		s.wait -= 1
		return
	}
	if s.until != {} {
		if time.tick_diff(time.tick_now(), s.until) > 0 {return}
		s.until = {}
	}
	if s.wait_world {
		if app.session == nil {
			log.error("script wait_world: no world to wait for (see above); quitting")
			app.script_failed = true
			app.quit = true
			return
		}
		if !world_settled(app) {return}
		s.wait_world = false
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
		case "wait_world":
			s.wait_world = true
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

// world_settled: in a world whose interest area has arrived and been meshed.
world_settled :: proc(app: ^App) -> bool {
	s := app.session
	if s == nil || s.state != .Playing {return false}
	r, h := i32(s.welcome.view_radius), i32(s.welcome.view_height)
	w := &s.world
	if len(w.to_mesh) > 0 || len(w.uploads) > 0 || w.stats.mesh_jobs_busy > 0 {return false}
	// Every chunk around the player here (counting them is not enough: just
	// after a teleport, those left behind still count). Around the feet, as
	// the server streams them.
	f := s.prediction.state.position
	centre := game.chunk_of({i32(math.floor(f.x)), i32(math.floor(f.y)), i32(math.floor(f.z))})
	for y in -h ..= h {
		for z in -r ..= r {
			for x in -r ..= r {
				p := centre + {x, y, z}
				if game.in_interest({x, y, z}, r, h) &&
				   game.in_world(p) &&
				   world_get(w, p) == nil {return false}
			}
		}
	}
	return true
}
