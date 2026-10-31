package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:game"

// The damage pipeline: abilities and the pvp rule decide, regeneration waits
// its delay, a death is counted and told from its source, the Respawn button
// stands the player at the spawn with the kit, once.

@(private = "file")
Result :: struct {
	invulnerable,
	pvp_off_player,
	pvp_off_fall,
	pvp_off_explosion,
	pvp_on,
	pvp_off_self: Damage_Result,
	health_after_invulnerable:                                                           f32,
	creative_health,
	creative_regen:                                                     f32,
	before_delay,
	at_delay,
	at_max,
	after_hit,
	rule_off:                                 f32,
	killed:                                                                              Damage_Result,
	bob_kills,
	alice_deaths:                                                             u64,
	dead,
	still_dead:                                                                    bool,
	after_respawn_health:                                                                f32,
	kit_first,
	kit_second:                                                               int,
	respawn_refused_alive:                                                               bool,
}

@(private = "file")
res: Result

@(private = "file")
sources_scenario :: proc(s: ^Server, _: rawptr) {
	alice, bob := client_by_name(s, "alice"), client_by_name(s, "bob")
	if alice == nil || bob == nil {return}
	bob_id := player_id(s, bob)
	s.tick += 20_000 // (a server that has run a while: the clock has room behind it)
	survival, _ := game.mode_find(s.registry, "survival")
	creative, _ := game.mode_find(s.registry, "creative")
	set_game_mode(s, alice, survival, {"test", ""})
	set_game_mode(s, bob, survival, {"test", ""})
	for c in ([]^Client{alice, bob}) {c.health, c.max_health = 20, 20}
	r := &alice.world.rules

	// Invulnerable: nothing happens (a creative player falling 20 blocks).
	set_game_mode(s, alice, creative, {"test", ""})
	res.invulnerable = damage(s, alice, 20, {kind = .Fall})
	res.health_after_invulnerable = alice.health
	res.creative_health = alice.health
	alice.last_damage = s.tick - 10_000
	regenerate(s, alice)
	res.creative_regen = alice.health
	set_game_mode(s, alice, survival, {"test", ""})
	alice.health, alice.max_health = 20, 20

	// pvp off blocks a player's damage, not falls or explosions or one's own.
	r.pvp = false
	res.pvp_off_player = damage(
		s,
		alice,
		1,
		{kind = .Weapon, attacker = bob_id, weapon = "pistol"},
	)
	res.pvp_off_fall = damage(s, alice, 1, {kind = .Fall})
	res.pvp_off_explosion = damage(s, alice, 1, {kind = .Explosion})
	res.pvp_off_self = damage(s, alice, 1, {kind = .Weapon, attacker = player_id(s, alice)})
	r.pvp = true
	alice.health = 20
	res.pvp_on = damage(s, alice, 1, {kind = .Weapon, attacker = bob_id, weapon = "pistol"})

	// Regeneration: nothing before 5 s, then a point a second, up to the maximum.
	alice.health = 10
	alice.last_damage = s.tick - (5 * game.TICK_RATE - 1)
	regenerate(s, alice)
	res.before_delay = alice.health
	alice.last_damage = s.tick - 5 * game.TICK_RATE
	for _ in 0 ..< game.TICK_RATE {regenerate(s, alice)} 	// (a second of ticks)
	res.at_delay = alice.health
	alice.health = 19.99
	regenerate(s, alice)
	res.at_max = alice.health
	alice.health = 10
	damage(s, alice, 1, {kind = .Fall})
	regenerate(s, alice)
	res.after_hit = alice.health
	r.natural_regeneration = false
	alice.health, alice.last_damage = 10, s.tick - 10_000
	regenerate(s, alice)
	res.rule_off = alice.health
	r.natural_regeneration = true

	// Death by bob's weapon: counted, and the screen waits for Respawn.
	alice.health = 5
	res.killed = damage(s, alice, 50, {kind = .Weapon, attacker = bob_id, weapon = "sniper"})
	res.dead = alice.dead
	res.bob_kills = bob.stats["kills"] or_else 0
	res.alice_deaths = alice.stats["deaths"] or_else 0
	res.still_dead = damage(s, alice, 5, {kind = .Fall}) == .Ignored // (the dead are not hurt)
}

@(private = "file")
respawn_scenario :: proc(s: ^Server, _: rawptr) {
	alice, bob := client_by_name(s, "alice"), client_by_name(s, "bob")
	if alice == nil || bob == nil {return}
	res.respawn_refused_alive = !respawn(s, bob)
	// A kit: three stone, given once and not doubled.
	survival := alice.mode
	old := s.registry.game_modes[survival].kit
	stone := game.item_of_block(s.registry, .Stone)
	s.registry.game_modes[survival].kit = {{item = stone, count = 3}}
	defer s.registry.game_modes[survival].kit = old
	alice.inventory = {}
	respawn(s, alice)
	res.after_respawn_health = alice.health
	res.kit_first = game.inventory_count(&alice.inventory, stone)
	alice.dead = true
	respawn(s, alice)
	res.kit_second = game.inventory_count(&alice.inventory, stone)
}

@(test)
test_the_damage_pipeline :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "damage"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	os.make_directory_all(dir)
	res = {}
	h: Harness
	srv := &h.srv
	if !testing.expect(
		t,
		harness_start(
			&h,
			Config {
				seed = 22,
				mode = "survival",
				view_radius = 2,
				view_height = 1,
				save_dir = dir,
				max_players = 4,
				listen = true,
				generator = .Classic,
				no_sheep = true,
			},
		),
	) {return}
	defer harness_stop(&h)
	alice, bob: Net_Client
	net_connect(&alice, 0, "alice", h = &h)
	net_connect(&bob, 0, "bob", h = &h)
	defer net_close(&alice)
	defer net_close(&bob)
	both := []^Net_Client{&alice, &bob}
	ok := net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		return cs[0].welcomed && cs[1].welcomed && cs[0].mode != "" && cs[1].mode != ""
	})
	if !testing.expect(t, ok, "never joined") {return}

	call(srv, sources_scenario, nil)
	testing.expect_value(t, res.invulnerable, Damage_Result.Blocked)
	testing.expect_value(t, res.health_after_invulnerable, f32(20))
	testing.expect_value(t, res.creative_regen, f32(20))
	testing.expect_value(t, res.pvp_off_player, Damage_Result.Blocked)
	testing.expect_value(t, res.pvp_off_fall, Damage_Result.Hurt)
	testing.expect_value(t, res.pvp_off_explosion, Damage_Result.Hurt)
	testing.expect_value(t, res.pvp_off_self, Damage_Result.Hurt)
	testing.expect_value(t, res.pvp_on, Damage_Result.Hurt)
	testing.expect_value(t, res.before_delay, f32(10))
	testing.expectf(
		t,
		abs(res.at_delay - 11) < 0.01,
		"a second of regeneration made %v",
		res.at_delay,
	)
	testing.expect_value(t, res.at_max, f32(20))
	testing.expect_value(t, res.after_hit, f32(9)) // (the damage reset the clock)
	testing.expect_value(t, res.rule_off, f32(10))
	testing.expect_value(t, res.killed, Damage_Result.Killed)
	testing.expect(t, res.dead && res.still_dead, "dead, and not hurt again")
	testing.expect_value(t, res.bob_kills, u64(1))
	testing.expect_value(t, res.alice_deaths, u64(1))

	// Everyone's chat has the line, once; the victim was told how.
	want := "alice was shot by bob (sniper)"
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		for c in cs {
			found := false
			for line in c.chat {
				if strings.contains(
					game.format_strip(line.text),
					"was shot by bob (sniper)",
				) {found = true}
			}
			if !found {return false}
		}
		return true
	})
	testing.expect(t, ok, "the death message did not reach both")
	for c in both {
		n := 0
		for line in c.chat {
			if game.format_strip(line.text) == want {n += 1}
		}
		testing.expect_value(t, n, 1)
	}
	// The P list's numbers: each is told their own (Tally) and the other's (Player).
	ok = net_wait(t, both, proc(cs: []^Net_Client) -> bool {
		a, b := cs[0], cs[1]
		return(
			a.tally.deaths >= 1 &&
			b.tally.kills == 1 &&
			a.counts[b.welcome.player] == {1, 0} &&
			b.counts[a.welcome.player] == {0, a.tally.deaths} \
		)
	})
	testing.expect(t, ok, "kills and deaths did not reach both")
	testing.expect_value(t, alice.death_cause, "weapon")
	testing.expect_value(t, alice.death_attacker, "bob")
	testing.expect(t, alice.health.dead && alice.hits > 0, "alice was told: dead, and hit")

	// Respawn: refused alive, the button when dead, the kit once.
	net_send(&bob, game.Respawn{})
	call(srv, respawn_scenario, nil)
	testing.expect(t, res.respawn_refused_alive, "respawn was accepted while alive")
	testing.expect_value(t, res.after_respawn_health, f32(20))
	testing.expect_value(t, res.kit_first, 3)
	testing.expect_value(t, res.kit_second, 3)
}

@(test)
test_death_messages_come_from_the_source :: proc(t: ^testing.T) {
	testing.expect_value(t, game.death_text(.Fall, "Sam", "", "", false), "Sam fell")
	testing.expect_value(t, game.death_text(.Explosion, "Alex", "", "", false), "Alex blew up")
	testing.expect_value(
		t,
		game.death_text(.Weapon, "Alex", "Sam", "sniper", false),
		"Alex was shot by Sam (sniper)",
	)
	testing.expect_value(t, game.death_text(.Fall, "Sam", "", "", true), "You fell")
	testing.expect_value(
		t,
		game.death_text(.Weapon, "Alex", "Sam", "pistol", true),
		"You were shot by Sam (pistol)",
	)
	for k in game.Source_Kind { 	// every source has its lines
		testing.expect(t, game.death_text(k, "A", "", "", false) != "")
		testing.expect(t, game.death_text(k, "A", "B", "w", true) != "")
		back, found := game.damage_source_parse(game.damage_source_name(k))
		testing.expect(t, found && back == k)
	}
}
