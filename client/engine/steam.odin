package engine

import "core:log"

import "client:steam"
import "common:base"

// Steam (docs/platforms.md, "Steam"): started once after the settings are read, when the
// `steam` setting allows it and the Steamworks library sits beside the executable; its
// callbacks run once a frame. Without either, Steam is off and nothing else changes. A
// benchmark or a check never starts it.

steam_start :: proc(app: ^App) {
	if app.benchmark || app.checking {return}
	dir := base.boot_info().dirs.exe
	if dir == "" {
		log.info("steam off: the executable's folder is unknown")
		return
	}
	steam.open_real(&app.steam, dir, app.settings.steam)
}

steam_update :: proc(app: ^App) {
	steam.run_callbacks(&app.steam)
}

steam_stop :: proc(app: ^App) {
	steam.shutdown(&app.steam)
}
