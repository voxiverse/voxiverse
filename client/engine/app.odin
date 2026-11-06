package engine

import "core:fmt"
import "core:log"
import "core:math"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

import "client:audio"
import "client:font"
import "client:gpu"
import "client:mesh"
import "client:platform"
import "client:render"
import "client:starfield"
import "client:ui"
import "common:base"
import "common:game"
import "common:netcode"
import "server:core"

// App is everything that lives for the whole process: window, GPU, UI, the
// console, settings. Created and destroyed in one place (app_init /
// app_destroy, in reverse order). A world visit is a Session, with its own
// lifetime inside the App's.

FONT_DATA :: #load("../../assets/fonts/jetbrains_mono_regular.ttf")
// SYMBOL_FONT_DATA: the addresses' symbols (Old Turkic), which the UI font
// lacks (common/game/address.odin).
SYMBOL_FONT_DATA :: #load("../../assets/fonts/noto_sans_old_turkic_regular.ttf")

Screen :: enum u8 {
	Title,
	Options,
	Credits,
	Universes,
	Creation,
	Multiplayer,
	Game, // a session exists
	Failed, // the session ended against our will: why (app.failed)
}

// CHUNK_VERTEX_CAPACITY: vertices of all chunk meshes together (8 bytes
// each: 128 MiB).
CHUNK_VERTEX_CAPACITY :: 16 * 1024 * 1024

App :: struct {
	window:           platform.Window,
	g:                gpu.Gpu,
	renderdoc:        gpu.Renderdoc,
	symbol_font:      font.Font, // (SYMBOL_FONT_DATA)
	font:             font.Font,
	ui:               ui.Context,
	ui_pass:          render.Ui_Pass,
	world_pass:       render.World_Pass,
	sky_pass:         render.Sky_Pass,
	scenes:           render.Scene_Buffers,
	debug_pass:       render.Debug_Pass,
	debug_draw:       render.Debug_Draw, // this frame's debug lines
	entity_pass:      render.Entity_Pass,
	entity_draw:      render.Entity_Draw, // this frame's boxes (players, entities, particles)
	held_pass:        render.Held_Pass, // what the hands hold (viewmodel.odin)
	held_draw:        render.Held_Draw, // this frame's held meshes: the view model, third person items
	held_cache:       Held_Cache, // every item's mesh in a hand
	held_arm:         Held_Mesh, // our right arm, in our shirt
	held_arm_shirt:   [4]u8,
	mixer:            ^audio.Mixer, // heap (it is large); fed to the sound card by audio_device
	audio_device:     audio.Device,
	null_audio:       bool, // mix into the null device, whatever the sound card (--null-audio, --check audio)
	audio_debug:      Audio_Debug,
	sounds:           Sound_Bank,
	music:            Music_App, // the director and its voices (music_app.odin)
	snapshots:        Snapshots, // what the mixer's snapshot holds (snapshots.odin)
	volumes:          [audio.Bus]f32, // as last told to the mixer
	listener:         audio.Listener, // ... and the listener's options
	shader_watch:     Shader_Watch,
	universes:        Universes_Screen,
	creation:         Creation_Screen,
	ignite:           Ignite,
	cues:             [dynamic]string, // UI sound events fired (ui_cue)
	multiplayer:      Multiplayer_Screen,
	session:          ^Session, // nil outside a world
	debug:            Debug_Switches,
	telemetry:        Telemetry_Switches,
	settings_dirty:   bool, // changed since loaded or saved
	scripted:         bool, // running --exec commands: settings changes are not saved
	benchmark:        bool, // --benchmark: BENCHMARK_SETTINGS, no sound device, nothing saved
	bench:            Bench, // the scenario running (benchmark.odin)
	stars:            starfield.Starfield, // the menus' background (starfield.odin)
	failed:           Failed, // the Failed screen's (screen_loading.odin)
	credits:          Credits_View, // the Credits screen's scroll (screen_credits.odin)
	options:          Options_View, // the Options screen's tab and state (screen_options.odin)
	fixed_view:       [2]i32, // view radius, height: a benchmark's or check's (else view_size)
	checking:         bool, // --check or --scene: BENCHMARK_SETTINGS (with the check's view), nothing saved
	scene:            Scene_Run, // --scene: a visual baseline's (scenes.odin)
	screenshot_names: [dynamic]string, // requested, not yet saved (oldest first)
	screenshot_dir:   string, // where they go, next to the executable ("": screenshots)
	message:          string, // shown on the title screen (why a session ended)
	fly_test:         Fly_Test,
	blast_test:       Blast_Test,
	audio_check:      Audio_Check,
	cull_check:       Exit_Check, // `--check cull` (cull_check_run)
	hiz_check:        Exit_Check, // `--check hiz` (hiz_check_run)
	tour_test:        Tour_Test,
	server_failed:    bool, // a session's server stopped on an error (fails the run)
	script_failed:    bool, // an --exec script could not go on (fails the run)
	console:          Console,
	input:            Input_State,
	actions:          Actions, // this frame's actions (actions.odin)
	injected:         [dynamic]platform.Event, // events the pad command and checks add
	settings:         Settings,
	screen:           Screen,
	overlays:         Overlays, // what is open over the screen (overlay.odin)
	crash_track:      Crash_Track, // what the crash bundle was told (crash_track.odin)
	account:          game.Account_Key, // who we are to servers (account.odin)
	new_character:    [dynamic]u8, // the name typed on the characters screen
	chat:             Line_Editor, // the chat's line (overlay_chat.odin)
	chat_scroll:      f32, // lines scrolled up in the open chat
	chat_osk:         bool, // the chat was opened by a pad: its line opens the on-screen keyboard
	splash:           string, // the title screen's, chosen once (screen_title.odin)
	started:          time.Tick, // when the app began (the splash's pulse)
	toasts:           Toasts, // the notices at the top right (overlay_toasts.odin)
	hud_hidden:       bool, // F1: the HUD is hidden (not saved)
	popup:            Item_Popup, // the held item's name above the hotbar (hud_popup.odin)
	lan:              Lan_Dialog, // the Open to LAN dialog's choices (overlay_lan.odin)
	player_menu:      Player_Menu, // the section shown and the one shown last (menu_player.odin)
	inventory_view:   Inventory_View, // the inventory overlay's (menu_inventory.odin)
	reporter:         Reporter, // what the client tells the server about itself (telemetry.odin)
	launched:         time.Tick, // when the program started
	clock:            App_Clock, // the OS's unless a test fixed it (clock.odin)
	stats_view:       Stats_View, // the statistics overlay's (menu_statistics.odin)
	preview:          Preview, // the player in the inventory (preview.odin)
	inventory_search: [dynamic]u8, // the Creative tab's search text
	prompt_icons:     Prompt_Icons, // the button glyphs (hud_prompts.odin)
	prompts_shown:    [PROMPTS_SHOWN_MAX]Prompt_Glyph, // this frame's, for tests (prompts_seen)
	prompts_count:    int,
	shown:            ^game.Registry, // the registry the texture array, sound bank and icons were last made for (nil: none of a session)
	registry:         ^game.Registry, // the game's own (the base pack); sessions use it unless they play a universe with packs
	item_icons:       Item_Icons, // every item's icon, in the UI's atlas (icons.odin)
	dial:             Dial_View, // the dial overlay's (overlay_dial.odin)
	quit:             bool,
	frame_stats:      base.Frame_Stats,
	triangle_stats:   base.Frame_Stats, // thousands drawn a frame, in a world
	last_frame_ms:    f32,
	seconds:          f32, // since start, wrapped every 1000 (moving water)
	fps:              Fps,
}

// audio_init makes the sounds and opens the sound card; without one the
// game runs silent.
audio_init :: proc(app: ^App) {
	sounds_init(&app.sounds, app.mixer)
	music_init(app)
	// Explosions and the like duck the music.
	audio.set_duck(
		app.mixer,
		0,
		{
			active = true,
			trigger = .Effects,
			target = .Music,
			threshold = 0.25,
			amount = 0.6,
			attack = 0.02,
			release = 1,
		},
	)
	audio_volumes(app, true)
	audio_listener(app, true)
	if app.null_audio {
		audio.device_open_null(&app.audio_device, app.mixer)
	} else {
		audio.device_open(&app.audio_device, app.mixer)
	}
	audio_ring_start(app)
}

// audio_volumes tells the mixer the volume sliders that changed (all, first).
audio_volumes :: proc(app: ^App, all: bool) {
	s := &app.settings
	want := #partial [audio.Bus]f32 {
		.Master   = s.volume,
		.Music    = s.music_volume,
		.Ambience = s.ambience_volume,
		.Effects  = s.effects_volume,
	}
	for b in ([]audio.Bus{.Master, .Music, .Ambience, .Effects}) {
		if all || want[b] != app.volumes[b] {
			audio.set_bus_gain(app.mixer, b, want[b])
			app.volumes[b] = want[b]
		}
	}
}

// audio_listener tells the mixer the listener's options when they changed
// (all: whatever they are, first).
audio_listener :: proc(app: ^App, all: bool) {
	s := &app.settings
	want := audio.Listener {
		mono       = s.mono_audio,
		swap       = s.swap_channels,
		night      = s.night_mode,
		crossfeed  = clamp(s.crossfeed, 0, 0.6),
		ceiling_db = clamp(s.ceiling_db, -24, -0.1) if s.ceiling_db != 0 else 0,
	}
	if all || want != app.listener {
		audio.set_listener(app.mixer, want)
		app.listener = want
	}
}

// apply_registry makes what depends on a registry: the texture array, the
// sound files of its packs and its items' icons. Nothing is made again for the
// registry shown already.
apply_registry :: proc(app: ^App, reg: ^game.Registry) {
	if app.shown == reg {return}
	app.shown = reg
	if app.world_pass.textures.handle != 0 {
		layers := u32(game.registry_texture_layers(reg))
		render.world_set_textures(&app.world_pass, &app.g, mesh.texture_array(reg), layers)
	}
	if !app.benchmark {sounds_load_pack(&app.sounds, app.mixer, reg)}
	item_icons_init(reg, &app.item_icons, &app.ui)
}

// world_pass_init sets up chunk rendering with the generated block textures.
world_pass_init :: proc(app: ^App, vert, frag: []u8) -> bool {
	pixels := mesh.texture_array(app.registry)
	#assert(size_of(mesh.Vertex) == render.WORLD_VERTEX_SIZE)
	shaders := world_shaders(vert, frag) or_return
	app.shown = app.registry
	return render.world_init(
		&app.world_pass,
		&app.g,
		{vertex_capacity = CHUNK_VERTEX_CAPACITY, staging_size = 8 * 1024 * 1024},
		shaders,
		pixels,
		mesh.TEXTURE_SIZE,
		mesh.TEXTURE_MIPS,
		u32(game.registry_texture_layers(app.registry)),
		max_meshes = 1 << 16,
	)
}

// app_frame runs one frame: input, UI, render. Returns false to stop.
// keep_awake_update: no screensaver and no display sleep for the whole run
// (the title, the menus and a paused game included; the window's close lets
// them be).
keep_awake_update :: proc(app: ^App) {
	platform.set_keep_awake(&app.window, true)
}

// render_size: what frames are drawn at: a benchmark's fixed offscreen
// size (gpu.set_offscreen), else the window's.
render_size :: proc(app: ^App) -> (width, height: i32) {
	if s := app.g.offscreen.size; s != {} {return i32(s.x), i32(s.y)}
	return app.window.width, app.window.height
}

// MENU_FPS: frames per second at most where nothing in a world moves (the
// title, menus, the game menu): drawing them thousands of times a second
// with vsync off only heats the machine (and can make it whine).
MENU_FPS :: 120

// frame_cap: the shortest a frame may take now (0: no limit).
frame_cap :: proc(app: ^App) -> time.Duration {
	in_world := app.screen == .Game && !world_paused(app)
	if in_world ||
	   app.fly_test.phase != .Off ||
	   app.blast_test.phase != .Off ||
	   app.audio_check.phase != .Off ||
	   app.tour_test.phase != .Off {
		if app.settings.max_fps > 0 &&
		   !app.benchmark {return time.Second / time.Duration(app.settings.max_fps)}
		return 0
	}
	return time.Second / MENU_FPS
}

// SCRATCH_SPAWN: where exit checks start in the scratch world: fixed, so
// their budgets keep meaning the same ground (the generator keeps spawns off trees and the shore).
SCRATCH_SPAWN :: [3]f64{24.5, 11, 8.5}

// SCRATCH_SEED: the seed of the scratch world (singleplayer, exit checks).
SCRATCH_SEED :: 0x5eed

// enter_world starts a session in the world saved at save_dir (created if
// new, with seed), or with save_dir "" a scratch world nothing is saved of
// (scripts and tests). The world runs here; others can join once it is
// opened to the LAN.
enter_world :: proc(
	app: ^App,
	save_dir: string,
	seed: i64,
	spawn: Maybe([3]f64) = nil,
	benchmark := false, // the same work every run: no sheep, still clouds
	mode := "creative", // a new universe's default game mode
) {
	view_radius, view_height := view_size(app)
	start_session(
		app,
		{
			no_sheep = benchmark,
			still_clouds = benchmark,
			name = player_name(&app.settings),
			key = app.account,
			seed = seed,
			mode = mode,
			save_dir = save_dir,
			spawn = spawn,
			view_radius = view_radius,
			view_height = view_height,
			trace = app.debug.net_trace,
			upload = upload_target(app),
		},
	)
}

// upload_target: where this world's events go: the collector, if the player
// said yes (and the world is saved: a scratch world keeps no log); else nowhere.
upload_target :: proc(app: ^App) -> Maybe(core.Upload) {
	if !app.settings.share_data {return nil}
	address := base.var_text(&app.settings.collector)
	if address == "" {address = DEFAULT_COLLECTOR}
	ep, err := net.resolve_ip4(address)
	if err != nil {return nil}
	if ep.port == 0 {ep.port = netcode.DEFAULT_PORT}
	return core.Upload{ep, app.account, 0}
}

// join_server plays on the server at address ("host" or "host:port"; the
// default port if none).
join_server :: proc(app: ^App, address: string, password: string, choose := false) {
	ep, err := net.resolve_ip4(address)
	if err != nil {
		delete(app.message)
		app.message = fmt.aprintf("Cannot find %s (%v)", address, err)
		app.screen = .Title
		return
	}
	if ep.port == 0 {ep.port = netcode.DEFAULT_PORT}
	view_radius, view_height := view_size(app)
	start_session(
		app,
		{
			name        = "" if choose else player_name(&app.settings), // "": the server's list
			key         = app.account,
			join        = Join{ep, password},
			capture     = app.debug.net_capture,
			view_radius = view_radius,
			view_height = view_height,
		},
	)
}

@(private = "file")
start_session :: proc(app: ^App, config: Session_Config) {
	if app.session != nil {return}
	delete(app.message)
	app.message = ""
	app.session = new(Session)
	config := config
	config.registry = app.registry
	if !session_start(app.session, config) {
		app.message = fmt.aprintf("Could not start: %s", app.session.failure)
		leave_world(app)
		return
	}
	apply_registry(app, app.session.reg) // (a universe with packs: its textures, sounds and items)
	app.screen = .Game
	overlays_leave_game(&app.overlays)
}

// leave_world ends the session and returns to the title screen.
leave_world :: proc(app: ^App) {
	if app.session == nil {return}
	app.shown = nil // (its registry goes with it)
	gpu.wait_idle(&app.g) // its meshes may be in use
	if !session_end(app.session, &app.world_pass, &app.g) {
		log.error("the server stopped with an error (see above)")
		app.server_failed = true
		delete(app.message)
		app.message = strings.clone("The world could not be saved (see the log)")
	}
	free(app.session)
	app.session = nil
	popup_reset(&app.popup)
	app.screen = .Title
	overlays_leave_game(&app.overlays)
	platform.set_mouse_captured(&app.window, false)
}

// view_size: the view to join a world with: the render distance around
// and half of it up and down, or the fixed view of a benchmark or a check.
view_size :: proc(app: ^App) -> (radius, height: i32) {
	if app.fixed_view != {} {return app.fixed_view.x, app.fixed_view.y}
	r := app.settings.render_distance
	return r, clamp(r / 2, 2, 16)
}

// ui_scale: the user's setting, or one derived from the window height
// (1.0 at 720 px, in quarter steps) so the UI keeps its proportions.
ui_scale :: proc(app: ^App) -> f32 {
	if app.settings.gui_scale > 0 {return f32(app.settings.gui_scale)}
	h := f32(max(app.window.height, 1))
	return clamp(math.round(h / 720 * 4) / 4, 1, 3)
}

// validation_options reads VX_VALIDATION: unset = on in development builds only,
// "0" = off, otherwise a comma list of "1"/"on", "best" (best-practices
// advice) and "gpu" (GPU-assisted shader checks).
validation_options :: proc() -> gpu.Validation {
	value, set := os.lookup_env("VX_VALIDATION", context.temp_allocator)
	if !set {return {enabled = base.DEV}}
	v: gpu.Validation
	for word in split_commas(value) {
		switch word {
		case "1", "on":
			v.enabled = true
		case "best":
			v.enabled, v.best_practices = true, true
		case "gpu":
			v.enabled, v.gpu_assisted = true, true
		case "0", "off", "":
		case:
			log.warnf("VX_VALIDATION: unknown option '%s' (use 0, 1, best, gpu)", word)
		}
	}
	return v
}

// EMBED_SHADERS: the compiled shaders are carried in the executable (a
// release package: one file, nothing beside it); otherwise they are read
// from the shaders/ folder beside it, so hot reload can replace them.
EMBED_SHADERS :: #config(VX_EMBED_SHADERS, false)
when EMBED_SHADERS {
	SHADERS := #load_directory("../../build/shaders")
}

// read_shader loads compiled SPIR-V: carried in the executable, or from the
// shaders/ folder next to it (build/shaders in a dev build).
read_shader :: proc(name: string) -> ([]byte, bool) {
	when EMBED_SHADERS {
		for f in SHADERS {
			if f.name == name {return f.data, true}
		}
		log.errorf("shader %s is not in this build", name)
		return nil, false
	}
	path := path_next_to_exe(filepath.join({"shaders", name}, context.temp_allocator) or_else name)
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		log.errorf("cannot read shader %s: %v (run `build shaders`)", path, err)
		return nil, false
	}
	return data, true
}

// path_next_to_exe places a file beside the executable (build/ in dev).
path_next_to_exe :: proc(name: string) -> string {
	dir, err := os.get_executable_directory(context.temp_allocator)
	if err != nil {return name}
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	return path
}

@(private)
split_commas :: proc(s: string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == ',' {
			append(&out, s[start:i])
			start = i + 1
		}
	}
	return out[:]
}

// eye_in_water: the camera is inside water.
eye_in_water :: proc(s: ^Session) -> bool {
	e := s.camera.position
	b, _ := world_block(
		&s.world,
		{i32(math.floor(e.x)), i32(math.floor(e.y)), i32(math.floor(e.z))},
	)
	_, water := game.water_level(b)
	return water
}
