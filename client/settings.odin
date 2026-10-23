package client

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "../base"
import "../game"

// The player's settings (saved) and the debug switches (not saved), each a
// plain struct described once by a variable table (see base/vars.odin and
// PLAN.md, "Console and variables"). Code reads the fields; the console
// (`set`, `get`, `vars`, `reset`), the tuning panel and the settings file go
// through the tables.

Settings :: struct {
	ui_scale:          f32, // 0 = automatic
	mouse_sensitivity: f32,
	invert_mouse:      bool,
	fov:               f32, // degrees, vertical
	view_radius:       i32, // chunks
	view_height:       i32,
	show_frame_times:  bool,
	volume:            f32, // 0..1, all sound
}

@(rodata)
SETTINGS_DEFAULTS := Settings {
	ui_scale          = 0,
	mouse_sensitivity = 1,
	fov               = 70,
	view_radius       = 12,
	view_height       = 6,
	volume            = 0.8,
}

@(rodata)
SETTINGS_VARS := [?]base.Var {
	{
		field = "ui_scale",
		label = "UI scale (0 = automatic)",
		help = "UI scale; 0 = automatic",
		min = 0,
		max = 3,
		step = 0.25,
	},
	{field = "mouse_sensitivity", help = "mouse look speed", min = 0.1, max = 5, step = 0.05},
	{field = "invert_mouse", help = "mouse up looks down"},
	{
		field = "fov",
		label = "Field of view",
		help = "vertical field of view, degrees",
		min = 50,
		max = 110,
		step = 1,
	},
	{field = "view_radius", help = "view distance across, chunks (next world)", min = 2, max = 32},
	{
		field = "view_height",
		help = "view distance up and down, chunks (next world)",
		min = 1,
		max = 16,
	},
	{field = "show_frame_times", help = "show frame times in the corner"},
	{field = "volume", help = "sound volume", min = 0, max = 1, step = 0.05},
}

// Debug switches: for development, never saved.
Debug_Switches :: struct {
	overlay:            bool, // F3
	chunk_borders:      bool,
	hot_reload_shaders: bool,
	net_trace:          bool,
	net_latency_ms:     f32,
	net_jitter_ms:      f32,
	net_bandwidth_kbps: f32,
}

@(rodata)
DEBUG_DEFAULTS := Debug_Switches {
	hot_reload_shaders = true,
}

@(rodata)
DEBUG_VARS := [?]base.Var {
	{field = "overlay", help = "debug overlay (F3)"},
	{field = "chunk_borders", help = "outline the camera's chunk and its neighbours' edges"},
	{
		field = "hot_reload_shaders",
		help = "recompile and reload shaders when assets/shaders changes (development builds)",
	},
	{
		field = "net_trace",
		help = "record every message to net.trace (from the next world; net_trace starts it now)",
	},
	{
		field = "net_latency_ms",
		help = "simulated one-way latency, ms",
		min = 0,
		max = 2000,
		step = 5,
	},
	{
		field = "net_jitter_ms",
		help = "simulated extra random delay, ms (order is kept)",
		min = 0,
		max = 1000,
		step = 5,
	},
	{
		field = "net_bandwidth_kbps",
		help = "simulated bandwidth per direction, KB/s; 0 = unlimited",
		min = 0,
		max = 100000,
		step = 10,
	},
}

settings_table :: proc() -> base.Var_Table {
	return {"", Settings, SETTINGS_VARS[:], &SETTINGS_DEFAULTS}
}

debug_table :: proc() -> base.Var_Table {
	return {"debug.", Debug_Switches, DEBUG_VARS[:], &DEBUG_DEFAULTS}
}

// Variable is a table and the struct it describes.
Variables :: struct {
	table: base.Var_Table,
	data:  rawptr,
}

// app_variables lists every table the console can reach: settings, debug
// switches, and in a world the server's rules (a copy: changing them goes
// through session_set_rule).
app_variables :: proc(app: ^App) -> []Variables {
	out := make([dynamic]Variables, context.temp_allocator)
	append(&out, Variables{settings_table(), &app.settings}, Variables{debug_table(), &app.debug})
	if app.session != nil && app.session.state == .Playing {
		append(&out, Variables{game.rules_table(), &app.session.rules})
	}
	return out[:]
}

// settings_path: VX_SETTINGS, else voxiverse/settings.cfg in the user's
// config directory.
settings_path :: proc() -> (string, bool) {
	if p, set := os.lookup_env("VX_SETTINGS", context.temp_allocator); set {return p, p != ""}
	dir, err := os.user_config_dir(context.temp_allocator)
	if err != nil {return "", false}
	return filepath.join({dir, "voxiverse", "settings.cfg"}, context.temp_allocator) or_else "",
		true
}

// settings_load reads the settings file (if any) over the defaults.
settings_load :: proc(app: ^App) {
	app.settings = SETTINGS_DEFAULTS
	path, ok := settings_path()
	if !ok {return}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		if err != .Not_Exist {log.warnf("settings cannot read path=%s error=%v", path, err)}
		return
	}
	for p in base.vars_read(settings_table(), &app.settings, string(data)) {
		log.warnf(
			"settings line ignored or clamped path=%s line=%d problem=%v text=%q",
			path,
			p.line,
			p.error,
			p.text,
		)
	}
	log.infof("settings loaded path=%s", path)
}

// settings_save writes the settings file (through a temporary file, so a
// crash mid-write cannot leave half a file).
settings_save :: proc(app: ^App) {
	path, ok := settings_path()
	if !ok {return}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"# Voxiverse settings (written by the game; edit freely while it is closed)\n\n",
	)
	base.vars_write(settings_table(), &app.settings, &b)
	os.make_directory_all(filepath.dir(path))
	tmp := strings.concatenate({path, ".tmp"}, context.temp_allocator)
	if err := os.write_entire_file(tmp, b.buf[:]); err != nil {
		log.errorf("settings cannot write path=%s error=%v", tmp, err)
		return
	}
	if err := os.rename(tmp, path); err != nil {
		log.errorf("settings cannot replace path=%s error=%v", path, err)
		return
	}
	app.settings_dirty = false
	log.infof("settings saved path=%s", path)
}

// settings_changed marks the settings for saving, unless a script is
// running (--exec): test runs must not change the player's settings.
settings_changed :: proc(app: ^App) {
	if !app.scripted {app.settings_dirty = true}
}
