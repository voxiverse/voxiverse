package engine

import "client:testkit"
import "common:game"
import "core:testing"

// An arrival into an address seen before this run is quiet (the app decides).
@(test)
test_arrival_into_a_seen_address :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	s := new(Session)
	defer free(s)
	s.reg = testkit.test_reg()
	app.session = s
	defer app.session = nil
	s.state = .Playing
	home := game.address_derive(1)
	there := game.address_derive(2)
	s.home, s.welcome.address = home, home
	in_ := music_input(app)
	testing.expect(t, in_.world_home && in_.playing && !in_.arrived)
	s.arrivals += 1
	s.welcome.address = there
	testing.expect(t, music_input(app).arrived, "a world not seen before")
	s.arrivals += 1
	s.welcome.address = home
	in_ = music_input(app)
	testing.expect(t, !in_.arrived && in_.world_home, "home again: not an arrival")
	s.arrivals += 1
	s.welcome.address = there
	testing.expect(t, !music_input(app).arrived, "seen before")
	s.died += 1
	testing.expect(t, music_input(app).died)
	testing.expect(t, !music_input(app).died)
	delete(app.music.seen)
}
