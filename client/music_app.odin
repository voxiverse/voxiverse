package client

import "core:math"
import "core:mem/virtual"
import "core:time"

import "../common/game"

// The music in the app (M44): the director, fed each frame from the session,
// and its actions carried out on the mixer.

Music_App :: struct {
	tracks:        []Music_Track,
	arena:         virtual.Arena, // the tracks' metadata
	player:        Music_Player,
	director:      Music_Director,
	actions:       [dynamic]Music_Action,
	seen:          [dynamic]game.Address, // the worlds visited this run
	session:       ^Session, // (the counts below belong to this session)
	died_seen:     int,
	arrivals_seen: int,
	ready:         bool, // the pieces are in the mixer
}

@(private = "file")
address_seen :: proc(m: ^Music_App, a: game.Address) -> bool {
	for s in m.seen {if s == a {return true}}
	return false
}

// music_init makes the director and registers the pieces with the mixer (before
// the device starts). Without the pieces decoded the game runs without music.
music_init :: proc(app: ^App) {
	m := &app.music
	m.tracks = music_tracks(&m.arena)
	m.ready = music_streams(&m.player, app.mixer, m.tracks)
	director_init(&m.director, m.tracks, u64(time.now()._nsec))
	m.director.tuning = MUSIC_DEFAULTS
}

music_destroy :: proc(app: ^App) {
	m := &app.music
	music_player_destroy(&m.player)
	virtual.arena_destroy(&m.arena)
	delete(m.actions)
	delete(m.seen)
	m^ = {}
}

// music_column_depth: the column's top under the player's feet minus the
// feet, blocks (0 where the column is not known).
music_column_depth :: proc(s: ^Session) -> f32 {
	f := s.prediction.state.position
	x, z := i32(math.floor(f.x)), i32(math.floor(f.z))
	column, ok := &s.world.columns[[2]i32{x >> game.CHUNK_SHIFT, z >> game.CHUNK_SHIFT}]
	if !ok {return 0}
	i := int(x & game.CHUNK_MASK) + int(z & game.CHUNK_MASK) * game.CHUNK_SIZE
	return f32(f64(column.heights[i]) - f.y)
}

// music_input: what the director is told this frame.
music_input :: proc(app: ^App) -> (in_: Music_Input) {
	m := &app.music
	in_.screen = app.screen
	in_.gap = app.settings.music_gap
	in_.biome = game.NO_BIOME
	s := app.session
	if s == nil {return}
	if s != m.session {
		m.session, m.died_seen, m.arrivals_seen = s, s.died, s.arrivals
	}
	in_.session = true
	in_.loading = s.loading != nil
	in_.playing = s.state == .Playing
	in_.paused = world_paused(app)
	in_.biome = s.place.biome
	in_.time_of_day = game.time_of_day(s.clock)
	in_.depth = music_column_depth(s)
	in_.world_home = s.welcome.address == s.home
	if !address_seen(m, s.home) {append(&m.seen, s.home)}
	if s.died != m.died_seen {
		m.died_seen = s.died
		in_.died = true
	}
	if s.arrivals != m.arrivals_seen {
		m.arrivals_seen = s.arrivals
		if !address_seen(m, s.welcome.address) {
			append(&m.seen, s.welcome.address)
			in_.arrived = true
		}
	}
	return
}

// music_update runs the director for a frame and plays what it decides.
music_update :: proc(app: ^App, dt: f32) {
	m := &app.music
	if !m.ready {return}
	music_alive(&m.player, app.mixer, &m.director)
	clear(&m.actions)
	director_update(&m.director, music_input(app), dt, &m.actions)
	music_apply(&m.player, app.mixer, m.tracks, m.actions[:])
}
