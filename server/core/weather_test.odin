package core

import "core:math"
import "core:strings"
import "core:testing"

import "common:game"
import "common:protocol"

// What the Weather record says is enough for a client to work out the weather the
// server has, whether the world follows its spells or /weather set it; the hum
// sources a game marks reach the players near them and go when unmarked.
@(test)
test_weather_reaches_the_client :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	srv := &h.srv
	config := Config {
		seed              = 27,
		generator         = .Earth,
		rules             = quiet_rules(),
		view_radius       = 3,
		view_height       = 2,
		max_players       = 2,
		listen            = true,
		everyone_cheats   = true,
		no_natural_spawns = true,
	}
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	clients := []^Net_Client{a}
	if !testing.expect(
		t,
		net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return landed(cs[0])}),
	) {
		return
	}
	pump :: proc(t: ^testing.T, clients: []^Net_Client) {
		net_wait(t, clients, proc(cs: []^Net_Client) -> bool {return false}, 0.3)
	}
	w := srv.home
	theirs :: proc(c: ^Net_Client, clock: f64) -> game.Weather {
		return game.weather_at(c.weather.seed, clock, protocol.weather_forced(c.weather))
	}
	testing.expect_value(t, a.weather.seed, world_weather_seed(w))
	p := a.update.state.position
	testing.expect_value(
		t,
		game.Climate(a.weather.climate),
		climate_at(w, i32(math.floor(p.x)), i32(math.floor(p.z))),
	)
	for at in ([]f64{0.5, 3.3, 41.7}) {
		w.clock = at
		testing.expect_value(t, theirs(a, at), world_weather(w))
	}

	// Set, it stands for the client too; given back, it follows its spells; a kind there
	// is not is refused with the usage.
	net_send(a, protocol.Command{"weather storm"})
	pump(t, clients)
	testing.expect_value(t, protocol.weather_forced(a.weather), game.Weather_Kind.Storm)
	testing.expect_value(t, theirs(a, w.clock), game.WEATHER_OF[.Storm])
	testing.expect_value(t, world_weather(w), game.WEATHER_OF[.Storm])
	net_send(a, protocol.Command{"weather auto"})
	net_send(a, protocol.Command{"weather hail"})
	net_send(a, protocol.Command{"weather"})
	pump(t, clients)
	testing.expect_value(t, a.weather.forced, 0)
	testing.expect(t, w.weather_forced == nil)
	usage, told := false, false
	for n in a.notices {
		usage ||= strings.contains(n, "Usage: weather")
		told ||= strings.contains(n, "The weather is")
	}
	testing.expect(t, usage && told, "the usage for hail, the weather for a bare /weather")

	// A hum source near the player is told; unmarked, it goes.
	near := game.Block_Pos{i32(p.x) + 5, i32(p.y), i32(p.z)}
	far := game.Block_Pos{i32(p.x) + HUM_RANGE + 50, i32(p.y), i32(p.z)}
	world_hum(w, near, 0.8)
	world_hum(w, far, 1)
	pump(t, clients)
	testing.expect_value(t, len(a.hums), 1)
	testing.expect_value(t, a.hums[near], 0.8)
	world_hum(w, near, 0)
	pump(t, clients)
	testing.expect_value(t, len(a.hums), 0)
	testing.expect_value(t, len(w.hums), 1)
}
