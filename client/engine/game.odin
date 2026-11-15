package engine

import "core:fmt"
import "core:log"
import "core:mem"
import "core:mem/virtual"

import "client:ui"
import "common:game"

// Game: a game's client part (docs/games.md): what the client does for the game its
// session plays. The engine never imports a game: client/main gives the App the games
// this build has (App.games, from the list the driver writes), and a session takes the
// one its server names in Welcome (session_game_begin). Its state is the session's.
// Any hook may be nil; all run on the main thread, in the frame.
Game :: struct {
	id:       string, // its folder's name in games/: what the server's Welcome names
	kinds:    game.Game_Kinds, // what its server part replicates (its shared package's)
	state:    typeid, // its state for the session (game_state): zero when the game begins; nil: none
	started:  proc(s: ^Session), // the session plays the game: welcomed, its state zero
	ended:    proc(s: ^Session), // the session ends (its state still there)
	received: proc(s: ^Session, r: game.Received), // a record of the game's kinds came, changed or went, or an event (game_value)
	hud:      proc(s: ^Session, ctx: ^ui.Context), // draw its HUD, after the engine's (F1 hides both)
	debug:    proc(s: ^Session) -> string, // its line of the F3 overlay ("": none; temporary memory)
	commands: []Command_Spec, // its console commands, there while a world plays it
}

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
game_value :: proc(s: ^Session, r: game.Received, $T: typeid) -> (value: ^T, ok: bool) {
	kind := game.game_kind(&s.schema, T) or_return
	if r.kind != kind {return nil, false}
	return (^T)(r.value), true
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
	game.receiver_destroy(&s.rx) // (nothing came yet: the receiver is made over the new schema)
	game.schema_destroy(&s.schema)
	s.schema = game.game_schema(g.id, g.kinds)
	game.receiver_init(&s.rx, &s.schema, s.reg)
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
	if s.game.id == "" {return}
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
