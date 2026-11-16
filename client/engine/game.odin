package engine

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import "client:ui"
import "common:game"
import "common:protocol"
import "server:core"

// Game: a game's client part (docs/games.md): what the client does for the game its
// session plays. The engine never imports a game: client/main gives the App the games
// this build has (App.games, from the list the driver writes), and a session takes the
// one its server names in Welcome (session_game_begin). Its state is the session's.
// Any hook may be nil; all run on the main thread, in the frame.
Game :: struct {
	using info: game.Game_Info, // its id (its folder's name in games/: what the server's Welcome names), name and description (its shared package's, as the server part's)
	kinds:      protocol.Game_Kinds, // what its server part replicates (its shared package's)
	state:      typeid, // its state for the session (game_state): zero when the game begins; nil: none
	started:    proc(s: ^Session), // the session plays the game: welcomed, its state zero
	ended:      proc(s: ^Session), // the session ends (its state still there)
	received:   proc(s: ^Session, r: protocol.Received), // a record of the game's kinds came, changed or went, or an event (game_value)
	hud:        proc(s: ^Session, ctx: ^ui.Context), // draw its HUD, after the engine's (F1 hides both)
	debug:      proc(s: ^Session) -> string, // its line of the F3 overlay ("": none; temporary memory)
	scoreboard: proc(s: ^Session, board: ^Scoreboard), // fill board: what the player list shows while its key is held, in place of the engine's
	commands:   []Command_Spec, // its console commands, there while a world plays it
	camera:     proc(s: ^Session) -> Game_Camera, // the camera it wants, every frame (nil: the player's own, F5)
	actions:    []string, // its own actions' names (at most game.MAX_GAME_ACTIONS): keys Game_1.. press them, its server part's action hook hears them
}

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
