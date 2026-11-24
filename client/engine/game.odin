package engine

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:reflect"
import "core:strings"

import "client:platform"
import "client:render"
import "client:ui"
import "common:base"
import "common:game"
import "common:protocol"
import "common:worldgen"
import "server:core"

// Game: a game's client part (docs/games.md): what the client does for the game its
// session plays. The engine never imports a game: client/main gives the App the games
// this build has (App.games, from the list the driver writes), and a session takes the
// one its server names in Welcome (session_game_begin). Its state is the session's.
// Any hook may be nil; all run on the main thread, in the frame.
Game :: struct {
	using info:    game.Game_Info, // its id (its folder's name in games/: what the server's Welcome names), name and description (its shared package's, as the server part's)
	kinds:         protocol.Game_Kinds, // what its server part replicates (its shared package's)
	state:         typeid, // its state for the session (game_state): zero when the game begins; nil: none
	started:       proc(s: ^Session), // the session plays the game: welcomed, its state zero
	ended:         proc(s: ^Session), // the session ends (its state still there)
	received:      proc(s: ^Session, r: protocol.Received), // a record of the game's kinds came, changed or went, or an event (game_value)
	hud:           proc(s: ^Session, ctx: ^ui.Context), // draw its HUD, after the engine's (F1 hides both)
	debug:         proc(s: ^Session) -> string, // its line of the F3 overlay ("": none; temporary memory)
	scoreboard:    proc(s: ^Session, board: ^Scoreboard), // fill board: what the player list shows while its key is held, in place of the engine's
	commands:      []Command_Spec, // its console commands, there while a world plays it
	camera:        proc(s: ^Session) -> Game_Camera, // the camera it wants, every frame (nil: the player's own, F5)
	actions:       []string, // its own actions' names (at most game.MAX_GAME_ACTIONS): keys Game_1.. press them, its server part's action hook hears them
	screen:        proc(s: ^Session, ctx: ^ui.Context, top: bool), // its screen, every frame while it is open (game_screen_open): a panel over the world drawn with the UI kit; top: it has the focus
	keys:          []Game_Key, // its client part's own keys (at most MAX_GAME_KEYS): a command panel's hotkeys, control groups; read with game_key_pressed and game_key_down, never sent
	no_hotbar:     bool, // its players hold no hotbar: in its world the hotbar's keys and the wheel pick no slot, and the controls do not list them
	machine_shown: typeid, // what its machines show (its server part's Game.machine_shown): machine_shown reads it
	look:          Look, // its atmosphere: sky, fog, light and the picture's colour, as data (zero: the engine's own)
	seen:          proc(s: ^Session, e: Seen), // the engine showed something worth feeling (an entity hurt or dead, the player hurt or healed, its shot hitting, a blast): the game's own feedback (feel.odin)
}

// Look: a game's atmosphere (render.Look, docs/games.md): its sky, fog, light and the
// picture's colour, declared as data in its client part (Game.look); zero is the engine's own.
Look :: render.Look

// Grade: the colour of a look's finished picture (render.Grade): tint, saturation, contrast
// and vignette; zero is none.
Grade :: render.Grade

// Machine_Shown: what a machine showed when last told (apply_machine).
Machine_Shown :: struct {
	pos:   game.Block_Pos,
	shown: [game.MAX_MACHINE_SHOWN]u8,
}

// machine_shown: what the game's machine at p shows, as the game's type (Game.machine_shown),
// as its server part last said; nil where the session holds no machine (none there, its
// chunk not here, or it never showed anything).
machine_shown :: proc(s: ^Session, p: game.Block_Pos, $T: typeid) -> ^T {
	assert(s.game.machine_shown == T, "not the game's machine_shown")
	#assert(size_of(T) <= game.MAX_MACHINE_SHOWN)
	b, loaded := world_block(&s.world, p)
	if !loaded || game.block_entity_kind(&s.reg.blocks, b) != .Machine {return nil}
	list, _ := &s.machines[game.chunk_of(p)]
	if list == nil {return nil}
	for &m in list {if m.pos == p {return (^T)(&m.shown)}}
	return nil
}

// MAX_GAME_KEYS: the keys a game's client part may declare (Game.keys).
MAX_GAME_KEYS :: 32

// Game_Key: one of a game's own keys: what it does (shown in the controls under the game's
// name and in the controls' words of the game's HUD) and the key that does it until the
// player binds another. Unlike its actions (Game.actions: sent to its server part), these
// are its client part's to read alone: a strategy game's many hotkeys and its control
// groups on the number keys.
Game_Key :: struct {
	name: string,
	key:  platform.Key,
}

// GAME_ACTION_KEYS: the keys of a game's actions until the player binds others.
GAME_ACTION_KEYS :: [protocol.MAX_GAME_ACTIONS]platform.Key{.Z, .X, .B}

// Game_Binds: the keys the player bound to the game playing's actions and its own keys,
// saved per game (keys/<game>.cfg beside the settings file: `<name> = <key>` lines, the
// names the game's), and listed under the game's name in the controls while it plays. In
// the world a key of the game's is the game's alone: an engine action bound to the same
// key does not fire there (game_owns_key; menus are unchanged), and a game whose players
// hold no hotbar (Game.no_hotbar) frees the hotbar's keys and the wheel.
Game_Binds :: struct {
	loaded:      bool, // read for the session's game (game_binds_load)
	no_hotbar:   bool, // the game's Game.no_hotbar
	actions:     [protocol.MAX_GAME_ACTIONS]platform.Key, // by Game.actions
	actions_len: int,
	keys:        [MAX_GAME_KEYS]platform.Key, // by Game.keys
	keys_len:    int,
}

// game_binds: the bindings of the game the session plays (nil: no session, or not read yet).
game_binds :: proc(app: ^App) -> ^Game_Binds {
	if app.session == nil || !app.session.binds.loaded {return nil}
	return &app.session.binds
}

// game_owns_key: k is bound to one of the game's actions or keys (game: nil, none).
game_owns_key :: proc(game: ^Game_Binds, k: platform.Key) -> bool {
	if game == nil || k == .Unknown {return false}
	for x in game.actions[:game.actions_len] {if x == k {return true}}
	for x in game.keys[:game.keys_len] {if x == k {return true}}
	return false
}

// game_binds_reset: the game's own defaults (GAME_ACTION_KEYS, its keys' keys).
game_binds_reset :: proc(b: ^Game_Binds, g: ^Game) {
	b.no_hotbar = g.no_hotbar
	b.actions_len = min(len(g.actions), protocol.MAX_GAME_ACTIONS)
	b.keys_len = min(len(g.keys), MAX_GAME_KEYS)
	b.actions = GAME_ACTION_KEYS
	for k, i in g.keys[:b.keys_len] {b.keys[i] = k.key}
	b.loaded = true
}

// game_binds_path: where the player's bindings of a game are kept (false: nowhere).
game_binds_path :: proc(id: string) -> (path: string, ok: bool) {
	settings := settings_path() or_return
	context.allocator = context.temp_allocator
	name := strings.concatenate({id, ".cfg"})
	return filepath.join({filepath.dir(settings), "keys", name}) or_else "", true
}

// game_binds_load: the game's defaults, then what the player bound (its file, if any:
// a benchmark's or a check's run reads none). A line naming nothing of the game's, or no
// key, is logged and skipped.
game_binds_load :: proc(app: ^App, s: ^Session) {
	b := &s.binds
	game_binds_reset(b, &s.game)
	if app.benchmark || app.checking {return}
	path, ok := game_binds_path(s.game.id)
	if !ok {return}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return}
	for l in base.config_lines(string(data)) {
		k, known := key_named(l.value)
		slot := game_bind_slot(b, &s.game, l.key)
		if !known || slot == nil {
			log.warnf("game keys line ignored path=%s line=%d text=%q", path, l.number, l.text)
			continue
		}
		slot^ = k
	}
}

// game_binds_save writes the game's bindings (not a script's, a benchmark's or a check's).
game_binds_save :: proc(app: ^App) {
	s := app.session
	b := game_binds(app)
	if b == nil || app.scripted || app.benchmark || app.checking {return}
	path, ok := game_binds_path(s.game.id)
	if !ok {return}
	out := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&out, "# The keys of %s (written by the game)\n\n", s.game.name)
	for name, i in s.game.actions[:b.actions_len] {
		fmt.sbprintf(&out, "%s = %s\n", name, key_name(b.actions[i]))
	}
	for k, i in s.game.keys[:b.keys_len] {
		fmt.sbprintf(&out, "%s = %s\n", k.name, key_name(b.keys[i]))
	}
	os.make_directory_all(filepath.dir(path))
	if err := os.write_entire_file(path, out.buf[:]); err != nil {
		log.errorf("game keys cannot write path=%s error=%v", path, err)
	}
}

// game_bind_key: the game's binding i, its actions then its keys (nil: none), and its name.
game_bind_key :: proc(b: ^Game_Binds, g: ^Game, i: int) -> (^platform.Key, string) {
	switch {
	case i < 0:
	case i < b.actions_len:
		return &b.actions[i], g.actions[i]
	case i < b.actions_len + b.keys_len:
		return &b.keys[i - b.actions_len], g.keys[i - b.actions_len].name
	}
	return nil, ""
}

// game_bind_slot: the binding of the game's action or key called name (nil: none).
game_bind_slot :: proc(b: ^Game_Binds, g: ^Game, name: string) -> ^platform.Key {
	for a, i in g.actions[:b.actions_len] {if a == name {return &b.actions[i]}}
	for k, i in g.keys[:b.keys_len] {if k.name == name {return &b.keys[i]}}
	return nil
}

// key_name: a key as the settings file writes it ("num_1"); key_named reads it back.
key_name :: proc(k: platform.Key) -> string {
	name, _ := reflect.enum_name_from_value(k)
	return strings.to_lower(name, context.temp_allocator)
}

key_named :: proc(text: string) -> (platform.Key, bool) {
	for k in platform.Key {
		if strings.equal_fold(key_name(k), text) {return k, true}
	}
	return .Unknown, false
}

// The game's screen: a panel of the game's own over the world (a town's market, a shop),
// drawn by its screen hook with the UI kit while it is open. The game opens it
// (game_screen_open, from a record, an event or its own action's answer) and closes it
// (game_screen_close); the player closes it as any screen over the world: Escape, the pad's
// Back, leaving the world. While open it takes the keyboard, the pointer and the pad's
// navigation, as the engine's screens do (the overlay Game_Screen); the world runs on.

// game_screen_open opens the game's screen (a game without a screen hook has none).
game_screen_open :: proc(s: ^Session) {
	if s.game.screen != nil {s.game_screen = true}
}

// game_screen_close closes the game's screen (closed: nothing to do).
game_screen_close :: proc(s: ^Session) {
	s.game_screen = false
}

// game_screen_shown: the game's screen is open.
game_screen_shown :: proc(s: ^Session) -> bool {
	return s.game_screen
}

// Key_Label: what a key is called on screen, kept by value (game_action_key).
Key_Label :: struct {
	text: [24]u8,
	len:  u8,
}

// game_action_key: the name of the key the player has bound to the game's action
// `index` (into Game.actions), as their keyboard prints it ("Z"; "(none)" when unbound),
// for a HUD to say which key does what. "" for an action the game has not.
game_action_key :: proc(s: ^Session, index: int) -> string {
	if index < 0 || index >= len(s.game.actions) || index >= len(s.game_keys) {return ""}
	k := &s.game_keys[index]
	return string(k.text[:k.len])
}

// game_key_pressed: the game's own key `index` (into Game.keys) went down this frame,
// while the world has the keyboard.
game_key_pressed :: proc(s: ^Session, index: int) -> bool {
	return index >= 0 && index < len(s.game.keys) && index in s.game_key_pressed
}

// game_key_down: the game's own key `index` is held, while the world has the keyboard.
game_key_down :: proc(s: ^Session, index: int) -> bool {
	return index >= 0 && index < len(s.game.keys) && index in s.game_key_down
}

// game_key_label: the name of the game's own key `index` as the player's keyboard prints
// it ("" for a key the game has not).
game_key_label :: proc(s: ^Session, index: int) -> string {
	if index < 0 || index >= len(s.game.keys) {return ""}
	k := &s.game_key_labels[index]
	return string(k.text[:k.len])
}

// game_action_pressed: the key of the game's action `index` was pressed this frame,
// wherever the keyboard is (over the world or the game's own screen: the key that opened
// a screen may close it). Over the world the action also goes to the server part.
game_action_pressed :: proc(s: ^Session, index: int) -> bool {
	return index >= 0 && index < len(s.game.actions) && index in s.game_pressed
}

// game_screen_sync (every frame): the overlay stack holds the game's screen while the
// session playing has it open, and only then; the game's bindings are read once
// (game_binds_load), the names of the keys bound to its actions taken from them
// (game_action_key), which were pressed from the actions (game_action_pressed), and its
// own keys' state from the input (game_key_pressed).
game_screen_sync :: proc(app: ^App) {
	s := app.session
	// (read once the session plays: before Welcome it knows no game)
	if s != nil && s.state == .Playing && !s.binds.loaded {game_binds_load(app, s)}
	if s != nil {
		b := &s.binds
		s.game_pressed = {}
		for action, i in GAME_ACTIONS {
			label := key_label(&app.window, b.actions[i])
			s.game_keys[i].len = u8(copy(s.game_keys[i].text[:], label))
			if key_action_pressed(&app.actions, action) {s.game_pressed += {i}}
		}
		s.game_key_pressed, s.game_key_down = {}, {}
		world := game_controls(app) && !app.ui.edit.active
		for key, i in b.keys[:b.keys_len] {
			label := key_label(&app.window, key)
			s.game_key_labels[i].len = u8(copy(s.game_key_labels[i].text[:], label))
			if !world || key == .Unknown {continue}
			if key in app.input.pressed {s.game_key_pressed += {i}}
			if key in app.input.held {s.game_key_down += {i}}
		}
	}
	if s != nil && s.state != .Playing {s.game_screen = false} 	// (the world left: closed)
	want := s != nil && s.game_screen
	open := overlay_is_open(&app.overlays, .Game_Screen)
	if want && !open {
		overlay_open(&app.overlays, .Game_Screen)
	} else if !want && open {
		overlay_close(&app.overlays, .Game_Screen)
	}
}

// game_screen_draw draws the game's screen (the overlay's turn).
game_screen_draw :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	s := app.session
	if s == nil || s.game.screen == nil || !s.game_screen {return}
	ui.push_id(ctx, "game_screen")
	defer ui.pop_id(ctx)
	s.item_icons = &app.item_icons
	s.game.screen(s, ctx, top)
}

// session_item_icons: every item's icon (the App's), for a game's screen to draw its slots
// as the player menu does (client/menu: stack_slot); nil outside the game's screen.
session_item_icons :: proc(s: ^Session) -> ^Item_Icons {return s.item_icons}

// game_actions: the game's own actions pressed this frame go to its server part (a
// Game_Action, after the last input sent).
game_actions :: proc(s: ^Session, a: ^Actions) {
	for action, i in GAME_ACTIONS {
		if i >= len(s.game.actions) {break}
		if action_pressed(a, action) {
			send_message(s, protocol.Game_Action{u8(i), s.prediction.next_sequence - 1})
		}
	}
}

// game_request sends the game's server part one of its requests (Game_Kinds.requests:
// value of the request kind's type), after the last input sent; the server checks it
// and its request hook judges it. The type names the kind: no kind number.
game_request :: proc(s: ^Session, value: ^$T) {
	kind, found := protocol.request_kind(&s.schema, T)
	assert(found, "not a request kind of the game's")
	if s.state != .Playing {return}
	w: game.Writer
	game.writer_init(&w, context.temp_allocator)
	protocol.request_encode(&w, &s.schema, kind, value)
	if len(w.buf) > protocol.MAX_GAME_REQUEST {
		log.errorf(
			"game request %s: %d bytes, more than %d",
			s.schema.kinds[kind].name,
			len(w.buf),
			protocol.MAX_GAME_REQUEST,
		)
		return
	}
	send_message(s, protocol.Game_Request{u16(kind), s.prediction.next_sequence - 1, w.buf[:]})
}

// SCOREBOARD_COLUMNS: the most columns a game's scoreboard has besides the name.
SCOREBOARD_COLUMNS :: 4

// Scoreboard: a game's table of its players, shown by the player list while its key
// is held (client/hud): a title, the headings of its columns after the name's, and a
// row for each player, in the order the game gives (the game sorts). The game's
// scoreboard hook fills it with scoreboard_columns and scoreboard_row; it lasts the
// frame (its rows are temporary memory).
Scoreboard :: struct {
	title:   string, // over the table ("": none)
	columns: [SCOREBOARD_COLUMNS]string, // the headings after the name's
	count:   int, // ... how many
	rows:    [dynamic]Score_Row,
}

// Score_Row: a player's row: the name and a cell under each heading.
Score_Row :: struct {
	name:  string,
	cells: [SCOREBOARD_COLUMNS]string,
	you:   bool, // the player's own: lit
}

// scoreboard_columns: the board's headings after the name's (at most SCOREBOARD_COLUMNS).
scoreboard_columns :: proc(board: ^Scoreboard, headings: ..string) {
	assert(len(headings) <= SCOREBOARD_COLUMNS, "a scoreboard has too many columns")
	board.count = copy(board.columns[:], headings)
}

// scoreboard_row: a row, after those there are: a name and its cells, in the columns'
// order; you: the player's own.
scoreboard_row :: proc(board: ^Scoreboard, name: string, cells: ..string, you := false) {
	row := Score_Row {
		name = name,
		you  = you,
	}
	copy(row.cells[:], cells)
	append(&board.rows, row)
}

// game_scoreboard: the game's scoreboard, if it has one (ok false: the engine's list).
game_scoreboard :: proc(s: ^Session) -> (board: Scoreboard, ok: bool) {
	if s.game.scoreboard == nil {return}
	board.rows = make([dynamic]Score_Row, context.temp_allocator)
	s.game.scoreboard(s, &board)
	return board, true
}

// HARNESS_GAME: the client part of the game a harness server plays when its tests name
// none (core.HARNESS_GAME): what a session joining one in a test or a fuzz target
// needs, since every server names a game and a client must have it.
HARNESS_GAME :: Game {
	info = core.HARNESS_GAME.info,
}

// HARNESS_GAMES: a session's games (Session_Config.games) when it joins a harness
// server: a list that outlives whoever starts the session.
@(rodata)
HARNESS_GAMES := []Game{HARNESS_GAME}

// game_find: the game of that id among games.
game_find :: proc(games: []Game, id: string) -> (^Game, bool) {
	for &g in games {
		if g.id == id {return &g, true}
	}
	return nil, false
}

// game_state: the session's state of its game, as the type the game declared
// (Game.state). Its memory is the session's.
game_state :: proc(s: ^Session, $T: typeid) -> ^T {
	assert(s.game.state == T, "not the game's state")
	return (^T)(raw_data(s.game_state))
}

// game_value: r's value as T, when r is of the game's kind whose value type is T
// (ok); nil for a removal (r.op == .Remove, r.key says which). The type names the
// kind, so the game's code holds no kind number and no cast.
game_value :: proc(s: ^Session, r: protocol.Received, $T: typeid) -> (value: ^T, ok: bool) {
	kind := protocol.game_kind(&s.schema, T) or_return
	if r.kind != kind {return nil, false}
	return (^T)(r.value), true
}

// Seats: what a game's client part keeps of each player from a record of its kind T
// keyed by the player (protocol.key_player), by seat: the last value told and its name
// (T's `name`, copied out of the message it came in, so the value's name stays good),
// forgotten when the server stops putting it. games/arena keeps its scores so.
Seats :: struct($T: typeid) {
	known:  [game.MAX_PLAYERS]bool,
	values: [game.MAX_PLAYERS]T,
	names:  [game.MAX_PLAYERS][game.MAX_NAME_LENGTH]u8,
}

// seats_received: r kept in seats when it is a record of T (its key a player's seat);
// true when it was one.
seats_received :: proc(s: ^Session, seats: ^Seats($T), r: protocol.Received) -> bool {
	value, ok := game_value(s, r, T)
	if !ok || int(r.key.a) >= game.MAX_PLAYERS {return ok}
	id := int(r.key.a)
	if value == nil {
		seats.known[id], seats.values[id] = false, {}
		return true
	}
	seats.known[id], seats.values[id] = true, value^
	n := copy(seats.names[id][:], value.name)
	seats.values[id].name = string(seats.names[id][:n])
	return true
}

// seat_mine: the session's own player's value (zero until told).
seat_mine :: proc(s: ^Session, seats: ^Seats($T)) -> ^T {
	return &seats.values[min(int(s.welcome.player), game.MAX_PLAYERS - 1)]
}

// seats_ranked: the seats told of, ordered by before (ties by name), as player ids
// (temp memory): a scoreboard's rows.
seats_ranked :: proc(seats: ^Seats($T), before: proc(a, b: ^T) -> bool) -> []int {
	ids := make([dynamic]int, context.temp_allocator)
	for known, id in seats.known {
		if !known {continue}
		// (at most MAX_PLAYERS: an insertion keeps them in order)
		append(&ids, id)
		for i := len(ids) - 1; i > 0; i -= 1 {
			x, y := &seats.values[ids[i]], &seats.values[ids[i - 1]]
			if !before(x, y) && (before(y, x) || x.name >= y.name) {break}
			ids[i], ids[i - 1] = ids[i - 1], ids[i]
		}
	}
	return ids[:]
}

// session_game_begin: the server plays the game of that id (Welcome). The session
// takes the client game of the same id, builds the schema with its kinds and makes
// its state; false (with the reason) when this client has no such game.
@(private)
session_game_begin :: proc(s: ^Session, id: string) -> (ok: bool, why: string) {
	g, found := game_find(s.config.games, id)
	if !found {
		return false, fmt.tprintf("the server plays %s, a game this version does not have", id)
	}
	s.game = g^
	protocol.receiver_destroy(&s.rx) // (nothing came yet: the receiver is made over the new schema)
	protocol.schema_destroy(&s.schema)
	s.schema = protocol.game_schema(g.id, g.kinds)
	protocol.receiver_init(&s.rx, &s.schema, s.reg)
	if g.state != nil {
		info := type_info_of(g.state)
		err: mem.Allocator_Error
		s.game_state, err = mem.alloc_bytes(
			info.size,
			info.align,
			virtual.arena_allocator(&s.arena),
		)
		if err != nil {return false, "out of memory for the game's state"}
	}
	log.infof("session game=%s", g.id)
	return true, ""
}

// session_game_started: the session is playing (welcomed): the game's started hook.
@(private)
session_game_started :: proc(s: ^Session) {
	s.game_playing = true
	if s.game.started != nil {s.game.started(s)}
}

// session_game_ended: the session ends: the game's ended hook, if started ran.
@(private)
session_game_ended :: proc(s: ^Session) {
	if !s.game_playing {return}
	s.game_playing = false
	if s.game.ended != nil {s.game.ended(s)}
}

// game_hud draws the game's HUD, if the session plays a game that has one, in the
// screen below top (the F3 overlay's bottom while it is open: App.debug_bottom), so
// neither covers the other.
game_hud :: proc(s: ^Session, ctx: ^ui.Context, top: f32 = 0) {
	if s.game.hud == nil {return}
	whole := ctx.screen
	defer ctx.screen = whole
	if top > whole.y {ui.cut_top(&ctx.screen, top - whole.y)}
	s.game.hud(s, ctx)
}

// game_debug_line: the game's F3 line ("" for none).
game_debug_line :: proc(s: ^Session) -> string {
	if s.game.debug == nil {return ""}
	line := s.game.debug(s)
	return fmt.tprintf("game %s: %s", s.game.id, line) if line != "" else ""
}

// game_command: the console command of that name of the game the session plays.
game_command :: proc(s: ^Session, name: string) -> (^Command_Spec, bool) {
	if s == nil {return nil, false}
	for &cmd in s.game.commands {
		if cmd.name == name {return &cmd, true}
	}
	return nil, false
}

// world_look: the look the world in view is drawn in: the game's (Game.look) and, on a
// world of a class (common/worldgen/classes.odin), the class's sky where the game's look
// leaves the sky its own: by day its zenith, horizon and clouds, blended into the time of
// day's at dusk and dawn so the night is the night; stars by day under an airless sky;
// no clouds where it has none. The class comes with the world's generator parameters (the
// Variables state), so a world of no class, or of another generator, is drawn as the
// game says.
world_look :: proc(s: ^Session) -> render.Look {
	look := s.game.look
	if !s.has_worldgen {return look}
	class := worldgen.world_class_of(&s.worldgen)
	if class == .None {return look}
	d := &worldgen.CLASSES[class]
	sky := render.sky_at(render.look_time(look, game.time_of_day(s.clock)))
	noon := render.sky_at(0.5)
	day := clamp(sky.sky_light.b / noon.sky_light.b, 0, 1) // 1 by day, the moonlight's at night
	day = clamp((day - 0.22) / 0.78, 0, 1)
	blend :: proc(time_of_day, class: [3]f32, day: f32) -> [3]f32 {
		return time_of_day + (class - time_of_day) * day
	}
	if look.zenith == {} && d.zenith != {} {look.zenith = blend(sky.zenith, d.zenith, day)}
	if look.horizon == {} && d.horizon != {} {look.horizon = blend(sky.horizon, d.horizon, day)}
	if look.cloud == {} && d.cloud != {} {look.cloud = blend(sky.cloud, d.cloud, day)}
	if look.stars == 0 {look.stars = d.stars}
	look.no_clouds ||= d.no_clouds
	return look
}
