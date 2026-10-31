package client

import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strings"

import "common:base"
import "common:game"
import "common:worldgen"

// The player's settings (saved) and the debug switches (not saved), each a
// plain struct described once by a variable table (see common/base/vars.odin and
// docs/plan.md, "Console and variables"). Code reads the fields; the console
// (`set`, `vars`, `reset`), the tuning panel and the settings file go
// through the tables.

Settings :: struct {
	name:              base.Var_Text, // the player's name ("": DEFAULT_NAME)
	last_server:       base.Var_Text, // Direct Connection's last address
	share_data:        bool, // send anonymous play data to the collector (asked once)
	share_asked:       bool, // the question was answered
	collector:         base.Var_Text, // the collector's address ("": DEFAULT_COLLECTOR)
	// Video
	fullscreen:        bool, // borderless, covering the monitor
	vsync:             bool, // wait for the display (off: up to max_fps)
	max_fps:           i32, // frames a second at most (0: no limit)
	fov:               f32, // degrees, vertical
	render_distance:   i32, // chunks around (the height follows: view_size)
	gui_scale:         i32, // 0 = automatic
	brightness:        f32, // 0..1: lifts the darkest light levels
	clouds:            bool,
	show_fps:          bool, // the FPS counter in the corner
	// Sound
	volume:            f32, // 0..1, all sound (the Master bus)
	music_volume:      f32, // 0..1
	ambience_volume:   f32, // 0..1
	music_gap:         i32, // 0 Rare, 1 Normal, 2 Often, 3 Constant: how often music plays in a world
	effects_volume:    f32, // 0..1
	mono_audio:        bool, // both ears hear the same (one-sided hearing)
	swap_channels:     bool, // left and right exchanged
	night_mode:        bool, // loud sounds down so nothing wakes the house
	crossfeed:         f32, // 0..0.6: headphones: the other ear hears the lows (0: off)
	ceiling_db:        f32, // hearing-safety ceiling for the whole mix, dBFS
	// Controls
	mouse_sensitivity: f32,
	invert_mouse:      bool,
	sneak_toggle:      bool, // a press sneaks until the next (else: while held)
	sprint_toggle:     bool,
	stick_look_speed:  f32, // times the stick's turning rate
	stick_invert:      bool, // pushing the right stick up looks down
	stick_dead_zone:   f32, // how far a stick moves before it counts
	stick_response:    int, // 1 linear, 2 curved, 3 steep
	stick_swap:        bool, // move with the right stick, look with the left
	button_prompts:    int, // 0 Auto, 1 Keyboard, 2 Xbox, 3 PlayStation: whose buttons the hints show
	keys:              Bindings, // (their own table: bindings_table)
	pad:               Pad_Bindings, // gamepad buttons (pad_bindings_table)
	// Accessibility
	reduce_motion:     bool, // still the menus' stars, the view bobbing, the sprint FOV kick and Ignite's zoom
	sprint_fov_kick:   bool, // the view widens a little while sprinting
	view_bobbing:      bool, // the first-person view sways while walking
	chat_text_size:    f32, // times the UI's text size
	prompt_bar:        bool, // the bar of button prompts along the bottom of menus (off by default)
}

@(rodata)
SETTINGS_DEFAULTS := Settings {
	vsync             = true,
	max_fps           = 0,
	fov               = 70,
	render_distance   = 12,
	gui_scale         = 0,
	clouds            = true,
	volume            = 0.8,
	music_volume      = 0.25,
	ambience_volume   = 1,
	music_gap         = 1,
	effects_volume    = 1,
	ceiling_db        = -1,
	mouse_sensitivity = 1,
	stick_look_speed  = 1,
	stick_dead_zone   = 0.15,
	stick_response    = 2,
	keys              = DEFAULT_BINDINGS,
	pad               = DEFAULT_PAD_BINDINGS,
	chat_text_size    = 1,
	sprint_fov_kick   = true,
	view_bobbing      = true,
}

@(rodata)
SETTINGS_VARS := [?]base.Var {
	{
		field = "name",
		label = "Your name",
		help = "The name other players see: letters, digits, _ or -.",
		check = proc(s: string) -> bool {return s == "" || game.name_valid(s)},
		hint = DEFAULT_NAME,
	},
	{field = "last_server", help = "the address Direct Connection last joined"},
	{
		field = "share_data",
		label = "Share play data",
		help = "Send anonymous play data (no name, no chat) to help improve Voxiverse.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{field = "share_asked", help = "the question about sharing play data was answered"},
	{field = "collector", help = "where play data goes (host:port); empty: the default"},
	{
		field = "fullscreen",
		label = "Display",
		help = "Play in a window or cover the whole screen.",
		choices = {{0, "Windowed"}, {1, "Fullscreen"}},
	},
	{
		field = "vsync",
		label = "VSync",
		help = "Wait for the display so the picture never tears; the frame rate then follows its refresh rate.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "max_fps",
		label = "Max frame rate",
		help = "The most frames drawn each second; Unlimited draws as many as it can.",
		min = 0,
		max = 240,
		choices = {
			{30, "30"},
			{60, "60"},
			{120, "120"},
			{144, "144"},
			{240, "240"},
			{0, "Unlimited"},
		},
	},
	{
		field = "fov",
		label = "Field of view",
		help = "How wide your view is, in degrees. Wider shows more, but bends the edges.",
		min = 30,
		max = 110,
		step = 1,
	},
	{
		field = "render_distance",
		help = "How far the world is drawn, in chunks. Applies to the next world you join.",
		min = 2,
		max = 32,
	},
	{
		field = "gui_scale",
		label = "GUI scale",
		help = "The size of menus and text. Auto picks one to fit your screen.",
		min = 0,
		max = 4,
		choices = {{0, "Auto"}, {1, "1"}, {2, "2"}, {3, "3"}, {4, "4"}},
		special = {{0, "Auto"}},
	},
	{
		field = "brightness",
		help = "Lifts the darkest places, such as caves and nights. Low is moody, high is bright.",
		min = 0,
		max = 1,
		step = 0.05,
	},
	{field = "clouds", help = "Draw the clouds in the sky.", choices = {{0, "Off"}, {1, "On"}}},
	{
		field = "show_fps",
		label = "Show FPS",
		help = "Show the frame rate in the corner of the screen.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "volume",
		label = "Master volume",
		help = "The loudness of everything, music included.",
		min = 0,
		max = 1,
		step = 0.05,
	},
	{
		field = "music_volume",
		label = "Music",
		help = "The loudness of the music.",
		min = 0,
		max = 1,
		step = 0.05,
	},
	{
		field = "ambience_volume",
		label = "Ambience",
		help = "The loudness of background sounds such as wind and water.",
		min = 0,
		max = 1,
		step = 0.05,
	},
	{
		field = "music_gap",
		label = "Music gaps",
		help = "How often music plays in a world: Rare, Normal, Often, or Constant (one piece after another).",
		min = 0,
		max = 3,
		choices = {{0, "Rare"}, {1, "Normal"}, {2, "Often"}, {3, "Constant"}},
	},
	{
		field = "effects_volume",
		label = "Effects",
		help = "The loudness of sounds in the world and of the menus.",
		min = 0,
		max = 1,
		step = 0.05,
	},
	{
		field = "mono_audio",
		label = "Mono sound",
		help = "Both ears hear the same mix (for one-sided hearing or one earbud).",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "swap_channels",
		label = "Swap ears",
		help = "Left and right are exchanged.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "night_mode",
		label = "Night mode",
		help = "Quiet sounds come up and loud ones go down, for playing at low volume.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "crossfeed",
		label = "Headphone cross-feed",
		help = "Each ear hears a little of the other, as with speakers: less tiring on headphones.",
		min = 0,
		max = 0.6,
		step = 0.05,
		special = {{0, "Off"}},
	},
	{
		field = "ceiling_db",
		label = "Loudest sound",
		help = "A ceiling no sound goes over, in decibels below full scale. Off: only the usual -1 dB limit.",
		min = -24,
		max = -1,
		step = 1,
		special = {{-1, "Off"}},
	},
	{
		field = "mouse_sensitivity",
		help = "How fast the view turns when you move the mouse.",
		min = 0.1,
		max = 5,
		step = 0.05,
	},
	{
		field = "invert_mouse",
		label = "Invert mouse",
		help = "Moving the mouse up looks down, and the other way round.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "sneak_toggle",
		label = "Sneak",
		help = "Hold the key to sneak, or press it once to start and again to stop.",
		choices = {{0, "Hold"}, {1, "Toggle"}},
	},
	{
		field = "sprint_toggle",
		label = "Sprint",
		help = "Hold the key to sprint, or press it once to start and again to stop.",
		choices = {{0, "Hold"}, {1, "Toggle"}},
	},
	{
		field = "stick_look_speed",
		label = "Stick look speed",
		help = "How fast the right stick turns the view.",
		min = 0.25,
		max = 3,
		step = 0.05,
	},
	{
		field = "stick_invert",
		label = "Invert stick",
		help = "Pushing the right stick up looks down.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "stick_dead_zone",
		label = "Stick dead zone",
		help = "How far a stick moves before it counts; raise it if the view drifts on its own.",
		min = 0.05,
		max = 0.4,
		step = 0.01,
	},
	{
		field = "stick_response",
		label = "Stick response",
		help = "Curved and steep turn slowly near the centre, for fine aiming, and fast at the edge.",
		min = 1,
		max = 3,
		choices = {{1, "Linear"}, {2, "Curved"}, {3, "Steep"}},
	},
	{
		field = "stick_swap",
		label = "Swap sticks",
		help = "Move with the right stick, look with the left.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "button_prompts",
		label = "Button prompts",
		help = "Which buttons the hints show: Auto follows whatever you used last.",
		min = 0,
		max = 3,
		choices = {{0, "Auto"}, {1, "Keyboard"}, {2, "Xbox"}, {3, "PlayStation"}},
	},
	{
		field = "reduce_motion",
		help = "Keeps the moving backgrounds still.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "sprint_fov_kick",
		label = "Sprint view kick",
		help = "The view widens a little while you sprint. Reduce motion turns it off too.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "view_bobbing",
		label = "View bobbing",
		help = "The first-person view sways a little while you walk. Reduce motion turns it off too.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "prompt_bar",
		label = "Button prompt bar",
		help = "Shows a bar of button hints (A Select, B Back) along the bottom of menus.",
		choices = {{0, "Off"}, {1, "On"}},
	},
	{
		field = "chat_text_size",
		help = "How large the chat's text is, compared with the menus'.",
		min = 0.5,
		max = 2,
		step = 0.25,
	},
}

DEFAULT_COLLECTOR :: "collector.voxiverse.net:27316"
DEFAULT_NAME :: "Player" // also the one player of format-1 saves (server.LEGACY_PLAYER)

// player_name: the name to play under.
player_name :: proc(s: ^Settings) -> string {
	name := base.var_text(&s.name)
	return name if name != "" else DEFAULT_NAME
}

// Debug switches: for development, never saved.
Debug_Switches :: struct {
	overlay:            bool, // F3
	chunk_borders:      bool,
	occlusion_stats:    bool, // count chunks drawn but hidden (a query each; logged at exit)
	hot_reload_shaders: bool,
	net_trace:          bool,
	net_capture:        bool,
	net_latency_ms:     f32,
	net_jitter_ms:      f32,
	net_bandwidth_kbps: f32,
	net_loss:           f32, // percent
	net_duplicate:      f32, // percent
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
		field = "occlusion_stats",
		help = "count chunks drawn but hidden behind nearer ones (logged at exit)",
	},
	{
		field = "hot_reload_shaders",
		help = "recompile and reload shaders when assets/shaders changes (development builds)",
	},
	{
		field = "net_trace",
		help = "record every message to net.trace (from the next world; net_trace starts it now)",
	},
	{
		field = "net_capture",
		help = "write every packet of the next remote game to net.pcap (Wireshark: tools/wireshark)",
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
		help = "simulated extra random delay, ms (in-process: order is kept; over UDP it reorders)",
		min = 0,
		max = 1000,
		step = 5,
	},
	{
		field = "net_bandwidth_kbps",
		help = "simulated bandwidth per direction, KB/s; 0 = unlimited (in-process only)",
		min = 0,
		max = 100000,
		step = 10,
	},
	{
		field = "net_loss",
		help = "simulated packet loss on what this client sends, % (remote games)",
		min = 0,
		max = 50,
		step = 1,
	},
	{
		field = "net_duplicate",
		help = "simulated packet duplication on what this client sends, % (remote games)",
		min = 0,
		max = 50,
		step = 1,
	},
}

// Telemetry switches: not saved. `ask` puts the one-time question about
// sharing play data back on the title screen (off: it is never asked and,
// unanswered, nothing is sent).
Telemetry_Switches :: struct {
	ask: bool,
}

@(rodata)
TELEMETRY_DEFAULTS := Telemetry_Switches{}

@(rodata)
TELEMETRY_VARS := [?]base.Var {
	{field = "ask", help = "ask once, on the title screen, whether to share anonymous play data"},
}

settings_table :: proc() -> base.Var_Table {
	return {"", Settings, SETTINGS_VARS[:], &SETTINGS_DEFAULTS}
}

debug_table :: proc() -> base.Var_Table {
	return {"debug.", Debug_Switches, DEBUG_VARS[:], &DEBUG_DEFAULTS}
}

telemetry_table :: proc() -> base.Var_Table {
	return {"telemetry.", Telemetry_Switches, TELEMETRY_VARS[:], &TELEMETRY_DEFAULTS}
}

// Variables: a table and the struct it describes.
Variables :: struct {
	table: base.Var_Table,
	data:  rawptr,
}

// app_variables lists every table the console can reach: settings, debug
// switches, and in a world the server's rules (a copy: changing them goes
// through session_set_rule).
app_variables :: proc(app: ^App) -> []Variables {
	out := make([dynamic]Variables, context.temp_allocator)
	append(
		&out,
		Variables{settings_table(), &app.settings},
		Variables{bindings_table(), &app.settings.keys},
		Variables{pad_bindings_table(), &app.settings.pad},
		Variables{debug_table(), &app.debug},
		Variables{telemetry_table(), &app.telemetry},
	)
	if app.session != nil && app.session.state == .Playing {
		append(&out, Variables{game.rules_table(), &app.session.rules})
		if app.session.has_worldgen {append(&out, Variables{worldgen.params_table(), &app.session.worldgen})}
	}
	return out[:]
}

// server_table: the table of a variable the server owns (rules.*,
// worldgen.*): changing one asks the server.
server_table :: proc(name: string) -> (base.Var_Table, bool) {
	switch {
	case strings.has_prefix(name, "rules."):
		return game.rules_table(), true
	case strings.has_prefix(name, "worldgen."):
		return worldgen.params_table(), true
	}
	return {}, false
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

// crashes_dir: where crash bundles go, beside the settings file (VX_SETTINGS moves both).
crashes_dir :: proc() -> (string, bool) {
	path, ok := settings_path()
	if !ok {return "", false}
	context.allocator = context.temp_allocator
	return filepath.join({filepath.dir(path), "crashes"}) or_else "", true
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
	// Three tables in one file: "key." lines are the keys', "pad." lines the
	// gamepad's, the rest the settings'; each reports only its own lines.
	problems := make([dynamic]base.Var_File_Problem, context.temp_allocator)
	for p in base.vars_read(settings_table(), &app.settings, string(data)) {
		if !is_binding_line(p.text, "key.") &&
		   !is_binding_line(p.text, "pad.") {append(&problems, p)}
	}
	for p in base.vars_read(bindings_table(), &app.settings.keys, string(data)) {
		if is_binding_line(p.text, "key.") {append(&problems, p)}
	}
	for p in base.vars_read(pad_bindings_table(), &app.settings.pad, string(data)) {
		if is_binding_line(p.text, "pad.") {append(&problems, p)}
	}
	for p in problems {
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

@(private = "file")
is_binding_line :: proc(line: string, prefix: string) -> bool {
	return strings.has_prefix(strings.trim_space(line), prefix)
}

// settings_save writes the settings file (through a temporary file, so a
// crash mid-write cannot leave half a file).
settings_save :: proc(app: ^App) {
	if app.benchmark || app.checking {return} 	// (never a benchmark's or a check's settings)
	path, ok := settings_path()
	if !ok {return}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(
		&b,
		"# Voxiverse settings (written by the game; edit freely while it is closed)\n\n",
	)
	base.vars_write(settings_table(), &app.settings, &b)
	strings.write_string(&b, "\n# Controls: keys by their place on a US keyboard\n\n")
	base.vars_write(bindings_table(), &app.settings.keys, &b)
	strings.write_string(&b, "\n# Gamepad: buttons by their place, named as on an Xbox pad\n\n")
	base.vars_write(pad_bindings_table(), &app.settings.pad, &b)
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
