package client

import "core:log"
import "core:strings"

import "gpu"

// Visual baselines (docs/debugging.md, "Visual baselines"): `voxiverse --scene
// <name>` runs one scene of assets/baselines/images/scenes.txt, writes what it
// drew to images/<name>.png next to the executable (build/images) and quits;
// `build images` runs every scene on lavapipe and compares the pictures with
// the baselines. Whatever could change the picture from one run to the next
// is fixed: the benchmarks' settings (BENCHMARK_SETTINGS), the scratch world
// at its fixed spawn with still clouds and no sheep, still rules (the time of
// day stopped at BENCH_TIME_OF_DAY unless the scene sets another, no random
// ticks, no gravity: a player put somewhere stays there), the water's
// animation stopped (App.seconds stays 0), no chat lines or toasts (they fade
// with the clock: cleared before the picture), and the size: SCENE_SIZE,
// drawn offscreen whatever the window is.

SCENES_TEXT :: #load("../assets/baselines/images/scenes.txt", string)

SCENE_SIZE :: [2]u32{640, 360}

// What runs before a scene's own script (once the world is there) and after
// it: the still rules, then, once whatever the scene asked for has arrived
// from the server and the world round where it stands is loaded and meshed,
// a few frames for the GPU before the picture.
SCENE_BEFORE ::
	"wait_world; set rules.daylight_cycle 0; set rules.random_tick_speed 0; set rules.gravity 0; /time set " +
	BENCH_TIME_OF_DAY +
	"; sleep 1"
SCENE_AFTER :: "sleep 1; wait_world; wait 10"

Scene_Phase :: enum u8 {
	Off,
	Script, // its script running (the main loop's)
	Clearing, // chat lines and toasts taken down, the UI drawn without them
	Shooting, // the picture asked for, not yet written
	Done,
}

Scene_Run :: struct {
	name:   string,
	phase:  Scene_Phase,
	frames: int, // in this phase
}

// SCENE_CLEAR_FRAMES: frames drawn between clearing the overlays and the picture.
SCENE_CLEAR_FRAMES :: 2

// scene_find: the script of the scene called name in text (SCENES_TEXT's form).
scene_find :: proc(text, name: string) -> (script: string, ok: bool) {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		n, colon, s := strings.partition(l, ":")
		if colon != "" && strings.trim_space(n) == name {return strings.trim_space(s), true}
	}
	return "", false
}

// scene_names: every scene's name in text, in order.
scene_names :: proc(text: string, allocator := context.allocator) -> []string {
	names := make([dynamic]string, allocator)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		n, colon, _ := strings.partition(l, ":")
		if colon != "" {append(&names, strings.trim_space(n))}
	}
	return names[:]
}

// scene_exec: the whole script a scene runs (--exec's form).
scene_exec :: proc(script: string, allocator := context.allocator) -> string {
	return strings.join({SCENE_BEFORE, script, SCENE_AFTER}, "; ", allocator)
}

// scene_begin starts the scene called name (after app_init): offscreen at
// SCENE_SIZE, in the scratch world.
scene_begin :: proc(app: ^App, name: string) -> bool {
	app.scene = {
		name  = name,
		phase = .Script,
	}
	app.screenshot_dir = "images"
	if !gpu.set_offscreen(&app.g, SCENE_SIZE.x, SCENE_SIZE.y) {
		log.errorf("scene %s: cannot draw offscreen at a fixed size here", name)
		return false
	}
	enter_world(app, "", SCRATCH_SEED, SCRATCH_SPAWN, benchmark = true)
	return true
}

// scene_update takes the picture once the scene's script is done; once a frame.
scene_update :: proc(app: ^App, script_done: bool) {
	sc := &app.scene
	sc.frames += 1
	#partial switch sc.phase {
	case .Script:
		if !script_done {return}
		s := app.session
		if s == nil || app.screen != .Game {
			log.errorf("scene %s: not in the world when its picture was due", sc.name)
			app.script_failed, app.quit = true, true
			return
		}
		for e in s.chat {delete(e.text)}
		clear(&s.chat)
		for t in app.toasts.list {delete(t.text)}
		clear(&app.toasts.list)
		sc.phase, sc.frames = .Clearing, 0
	case .Clearing:
		if sc.frames < SCENE_CLEAR_FRAMES {return}
		screenshot_request(app, sc.name)
		sc.phase, sc.frames = .Shooting, 0
	}
}
