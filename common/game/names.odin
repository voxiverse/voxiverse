package game

// What names a game and its players, the same on every side: a game's id and the
// names players read (docs/games.md), a player's name and how many share a server.

// Game_Info: what names a game (docs/games.md), declared once in its shared package
// and taken by both of its parts (core.Game and engine.Game hold it by `using`): its
// id (its folder's name in games/, what Welcome names), the name players read and a
// line saying what it is, both in plain English (Singleplayer's list of games, and the
// head of the game's page).
Game_Info :: struct {
	id:          string,
	name:        string,
	description: string,
}

// MAX_GAME_ID: the longest game id (a folder name of games/).
MAX_GAME_ID :: 32

// DEFAULT_GAME: the game a session plays when nobody names one (games/sandbox: the
// engine's open world). There is no session without a game.
DEFAULT_GAME :: "sandbox"

// game_id_valid: an id is a game's folder name, singular snake_case: a lower-case
// letter, then lower-case letters, digits and underscores (never "": every session
// plays a game).
game_id_valid :: proc(id: string) -> bool {
	if id == "" || len(id) > MAX_GAME_ID {return false}
	for ch, i in transmute([]u8)id {
		switch ch {
		case 'a' ..= 'z':
		case '0' ..= '9', '_':
			if i == 0 {return false}
		case:
			return false
		}
	}
	return true
}

// A player's name, an account's characters, a server's seats.
MAX_NAME_LENGTH :: 16
MAX_CHARACTERS :: 8 // an account's in one universe
MAX_PLAYERS :: 32 // a server's seats at most

// name_valid: a player name is 1..MAX_NAME_LENGTH letters, digits, '_' or '-'.
name_valid :: proc(name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_NAME_LENGTH {return false}
	for c in transmute([]u8)name {
		switch c {
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
		case:
			return false
		}
	}
	return true
}
