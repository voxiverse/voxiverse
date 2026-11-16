package core

import "core:testing"

import "common:game"

// Damage a game controls: a melee weapon's swing strikes what is in its arc for the
// weapon's damage, a hitscan weapon hurts a creature by its own, and the game's harming
// hook changes every harm before it is done: player to entity, entity to player,
// player to player.

@(private = "file")
HARM_PACK :: `{"format": 1, "namespace": "harm", "version": "1.0.0", "title": "Harm", "requires": ["voxiverse"]}`
@(private = "file")
HARM_KINDS :: `{
	"dummy": {"box": [0.8, 1.8], "health": 40, "hittable": true, "physics": "walker",
	          "walker": {"walk_speed": 2, "run_speed": 2, "jump": 0, "step": 0},
	          "brain": "steered", "attack": {"damage": 4, "reach": 1.5, "cooldown": 1},
	          "model": {"box": [120, 120, 120]}}
}`
@(private = "file")
HARM_ITEMS :: `{
	"sword": {"stack": 1, "melee": {"damage": 4, "reach": 3, "arc": 90, "cooldown": 0.5}},
	"wand": {"stack": 1, "weapon": {"damage": 5, "magazine": 50, "fire_rate": 2, "automatic": false,
	         "range": 40, "headshot": 1, "zoom": 0, "reload_time": 1, "spread": 0}}
}`

// Harm_Log: the test game's tally of what its hook saw.
@(private = "file")
Harm_Log :: struct {
	seen: [3]int, // player to entity, entity to player, player to player
}

@(private = "file")
Harm_Rig :: struct {
	sess:  Session,
	guest: Harness_Player,
	files: [3]game.Pack_File,
}

// harm_changed: the test's rules: a player's blow on a creature doubled, a creature's
// on a player halved, a player's on a player one more.
@(private = "file")
harm_changed :: proc(s: ^Server, h: ^Harming) {
	log := game_state(s, Harm_Log)
	switch {
	case h.by != nil && h.entity != 0:
		log.seen[0] += 1
		h.amount *= 2
	case h.creature != 0 && h.to != nil:
		log.seen[1] += 1
		h.amount /= 2
	case h.by != nil && h.to != nil:
		log.seen[2] += 1
		h.amount += 1
	}
}

@(test)
test_a_game_controls_damage :: proc(t: ^testing.T) {
	rig := new(Harm_Rig)
	defer free(rig)
	rig.files = {
		{"pack.json", transmute([]u8)string(HARM_PACK)},
		{"data/entities/dummy.json", transmute([]u8)string(HARM_KINDS)},
		{"data/items/weapons.json", transmute([]u8)string(HARM_ITEMS)},
	}
	config := harness_world()
	config.mode = "survival"
	config.listen = true
	config.game = {
		info = {id = "harm", name = "Harm"},
		pack = {"harm", rig.files[:]},
		server_state = Harm_Log,
		harming = harm_changed,
	}
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	harness_player_join(&rig.sess.h, &rig.guest, "guest")
	defer harness_player_free(&rig.guest)
	ready :: proc(data: rawptr) -> bool {
		rig := (^Harm_Rig)(data)
		g := harness_player_client(&rig.guest)
		return(
			rig.sess.mirror.welcomed &&
			rig.sess.h.srv.clients[0].state == .Playing &&
			g != nil &&
			g.state == .Playing \
		)
	}
	_, ok := harness_step_until(&rig.sess.h, ready, rig, 600)
	if !testing.expect(t, ok, "never played") {return}
	s := &rig.sess.h.srv
	w := s.home
	c := &s.clients[0]
	log := game_state(s, Harm_Log)
	g := harness_player_client(&rig.guest)
	g.player.position = {8.5, 0, 8.5} // (out of the way until its turn)
	game_rule(s, w, "pvp", "true")
	sword, _ := game.registry_item(s.registry, "harm:sword")
	wand, _ := game.registry_item(s.registry, "harm:wand")
	dummy, _ := game.registry_kind(s.registry, "harm:dummy")

	// The sword: the dummy in front (c faces -z) is struck for 4, doubled; the one
	// behind is not; a second swing at once is too soon.
	c.inventory.slots = {} // (the kit out of the way: the sword in slot 0, the wand in 1)
	item_give(s, c, sword, 1)
	item_give(s, c, wand, 1)
	hotbar_select(s, c, 0)
	c.look = {0, 0}
	front := entity_spawn(w, dummy, c.player.position + {0, 0, -2}, false)
	back := entity_spawn(w, dummy, c.player.position + {0, 0, 2.5}, false)
	for e in ([]game.Entity_Handle{front, back}) {entity_stand(w, e)}
	held := game.inventory_held(&c.inventory)
	info, _ := game.item_info(s.registry, held.item)
	melee, swings := info.melee.?
	if !testing.expect(t, swings && held.item == sword) {return}
	testing.expect_value(t, swing(s, c, held, melee), 1)
	testing.expect_value(t, entity_health_of(w, front), 40 - 8)
	testing.expect_value(t, entity_health_of(w, back), 40)
	testing.expect_value(t, swing(s, c, held, melee), 0)
	harness_step(&rig.sess.h, 16)
	testing.expect_value(t, swing(s, c, held, melee), 1)
	testing.expect_value(t, entity_health_of(w, front), 40 - 16)

	// The wand: a shot hurts the dummy by the wand's 5, doubled.
	hotbar_select(s, c, 1)
	c.inventory.slots[1].ammo = 50
	entity_gone(w, back)
	entity_set_pos(w, front, c.player.position + {0, 0, -2})
	before := entity_health_of(w, front)
	testing.expect(t, weapon_shoot(s, c, {slot = 1, press = true, yaw = 0, pitch = -0.3}, 0))
	testing.expect_value(t, entity_health_of(w, front), before - 10)

	// The dummy strikes back: its 4, halved.
	full := c.health
	entity_set_pos(w, front, c.player.position + {0, 0, -1.2})
	testing.expect_value(t, entity_strike(w, front, c), Strike.Hit)
	testing.expect_value(t, c.health, full - 2)

	// A swing at the guest standing in front: the sword's 4, one more.
	entity_gone(w, front)
	g.player.position = c.player.position + {0, 0, -1.5}
	hotbar_select(s, c, 0)
	harness_step(&rig.sess.h, 16)
	guest_full := g.health
	testing.expect_value(t, swing(s, c, game.inventory_held(&c.inventory), melee), 1)
	testing.expect_value(t, g.health, guest_full - 5)
	testing.expect_value(t, log.seen, [3]int{3, 1, 1})
}
