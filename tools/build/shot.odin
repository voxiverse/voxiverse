package build

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "common:limited"

// Screenshots of the game as a player sees it, for a game's README or a review (docs/
// games.md, "Screenshots"): `build shot <name> [--game <id>] -- <script>` plays the game
// on lavapipe under xvfb-run at 1280x720, never a window on anyone's desktop, running
// the script as `--exec` does (console commands, `;` between them, with the script's own
// ticks <n>, wait_world, wait_joined, wait <frames> and sleep <seconds>:
// client/console/script.odin). The script's `screenshot <file>` writes
// build/screenshots/<file>.png; it ends with `quit`. The run's log, settings, state and
// saves (a universe the script makes) are in build/shots/<name>/ (a fresh one each run),
// and it is stopped after SHOT_LIMIT. What it needs is all it waits for: the client
// alone, built only when something it is built from changed (fresh.odin), and no sound
// card (its opening under xvfb took seconds).

SHOT_DIR :: "build/shots"
SHOT_LIMIT :: 10 * time.Minute
SHOT_SIZE :: "-screen 0 1280x720x24"

shot :: proc(args: []string) -> bool {
	if ODIN_OS != .Linux {
		fmt.eprintln("build: shot renders on lavapipe under xvfb-run, on Linux")
		return false
	}
	USAGE :: "build shot <name> [--game <id>] -- <script>"
	name, game_id, script := "", "", ""
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--":
			script = strings.join(args[i + 1:], " ")
			i = len(args)
		case args[i] == "--game" && i + 1 < len(args):
			game_id = args[i + 1]
			i += 1
		case name == "" && !strings.has_prefix(args[i], "-"):
			name = args[i]
		case:
			fmt.eprintfln("build: %s", USAGE)
			return false
		}
	}
	if name == "" || script == "" || strings.contains_any(name, "/\\") {
		fmt.eprintfln("build: %s", USAGE)
		return false
	}
	icd := lavapipe_icd()
	if icd == "" {
		fmt.eprintln(
			"build: shot: lavapipe is not installed (Mesa's CPU Vulkan driver: mesa-vulkan-drivers)",
		)
		return false
	}
	os.set_env("VK_DRIVER_FILES", icd)
	os.set_env("VK_ICD_FILENAMES", icd)
	exe := build_game({}, server = false) or_return
	root, _ := os.get_working_directory(context.allocator)
	state := path_join({root, SHOT_DIR, name})
	os.remove_all(state)
	os.make_directory_all(state)
	os.make_directory_all("build/screenshots")
	cmd := make([dynamic]string)
	append(
		&cmd,
		"xvfb-run",
		"-n",
		fmt.tprintf("%d", 100 + (os.get_pid() % 150) * 20 + 19), // (beside the images' displays)
		"-s",
		SHOT_SIZE,
		"env",
		strings.concatenate({"VX_STATE_DIR=", state}),
		strings.concatenate({"VX_SETTINGS=", state, "/settings.cfg"}),
		strings.concatenate({"VX_SAVES=", state, "/saves"}),
		exe,
	)
	append(&cmd, "--null-audio")
	if game_id != "" {append(&cmd, "--game", game_id)}
	append(&cmd, "--exec", script)
	fmt.printfln("shot   %s on lavapipe (its state: %s)", name, state)
	result := limited.run_limited(cmd[:], SHOT_LIMIT)
	if result != .Ok {
		fmt.eprintfln("build: shot %s: %v (the game's log: %s/voxiverse.log)", name, result, state)
		return false
	}
	return true
}
