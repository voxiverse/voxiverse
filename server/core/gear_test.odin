package core

import "core:math"
import "core:testing"

import "common:game"
import "common:protocol"

// Gear as data, on a test game's own pack: a block that asks a tier 2 tool and takes
// time to break, a pick that gathers it (faster than hands, one more of its drop), worn
// defence and fall guard, and a consumable used up from the hand. None of it is a game's.

@(private = "file")
GEAR_PACK :: `{"format": 1, "namespace": "gear", "version": "1.0.0", "title": "Gear", "requires": ["voxiverse"]}`
@(private = "file")
GEAR_BLOCKS :: `{"ore": {"material": "stone", "tier": 2, "hardness": 1, "tool": "pick"}}`
@(private = "file")
GEAR_ITEMS :: `{
	"pick": {"stack": 1, "gather": {"tier": 2, "yield": 1, "speed": 4, "kind": "pick"}},
	"salve": {"consume": {"heal": 4, "regen": 3, "defence": 0.2, "seconds": 10}},
	"vest": {"stack": 1, "equip": "chest", "modifiers": [{"stat": "defence", "amount": 0.5}, {"stat": "fall_guard", "amount": 0.5}]}
}`

@(private = "file")
Gear_Rig :: struct {
	sess:  Session,
	files: [3]game.Pack_File,
}

// gear_edit: the mirror's player sends an edit of face `face` at p after its last input.
@(private = "file")
gear_edit :: proc(rig: ^Gear_Rig, p: game.Block_Pos, face: u8) {
	m := &rig.sess.mirror
	id: u32 = 0
	if face != game.EDIT_FACE_BREAK_BEGIN {
		m.edit_id += 1
		id = m.edit_id
	}
	e := protocol.Edit {
		id    = id,
		after = m.prediction.next_sequence - 1,
		pos   = p,
		block = .Air,
		face  = face,
	}
	mirror_send(m, e)
	harness_step(&rig.sess.h, 3)
}

@(test)
test_gear_tiers_break_time_and_protection :: proc(t: ^testing.T) {
	rig := new(Gear_Rig)
	defer free(rig)
	rig.files = {
		{"pack.json", transmute([]u8)string(GEAR_PACK)},
		{"data/blocks/gear.json", transmute([]u8)string(GEAR_BLOCKS)},
		{"data/items/gear.json", transmute([]u8)string(GEAR_ITEMS)},
	}
	config := harness_world()
	config.mode = "survival"
	config.rules = harness_rules()
	config.rules.break_time = 1
	config.game = {
		info = {id = "gear", name = "Gear"},
		pack = {"gear", rig.files[:]},
	}
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	ready :: proc(data: rawptr) -> bool {
		rig := (^Gear_Rig)(data)
		return rig.sess.mirror.welcomed && rig.sess.h.srv.clients[0].state == .Playing
	}
	_, ok := harness_step_until(&rig.sess.h, ready, rig, 600)
	if !testing.expect(t, ok, "never played") {return}
	harness_step(&rig.sess.h, 30)
	s := &rig.sess.h.srv
	w := s.home
	c := &s.clients[0]
	ore, _ := game.registry_block(s.registry, "gear:ore")
	pick, _ := game.registry_item(s.registry, "gear:pick")
	salve, _ := game.registry_item(s.registry, "gear:salve")
	vest, _ := game.registry_item(s.registry, "gear:vest")
	ore_item := game.block_drop(s.registry, ore)
	feet := c.player.position
	at := game.Block_Pos {
		i32(math.floor(feet.x)) + 1,
		i32(math.floor(feet.y)) + 1,
		i32(math.floor(feet.z)),
	}
	act := game_act(s, w, .Command)
	c.inventory.slots = {}
	c.inv_changed = true

	// Bare hands: refused, told the tier, the block stays.
	set_block(w, at, ore, act)
	gear_edit(rig, at, game.EDIT_FACE_BREAK)
	if b, _ := block_at(w, at); !testing.expect_value(t, b, ore) {return}
	told := false
	for n in rig.sess.mirror.notices {if n == "That needs a tier 2 tool" {told = true}}
	testing.expect(t, told, "not told the tier")

	// The pick: a break sent at once after its begin is too soon (1 s of hardness over a
	// speed of 4 is 8 ticks); one sent after the ticks breaks it and leaves two.
	item_give(s, c, pick, 1)
	hotbar_select(s, c, 0)
	need := game.break_ticks(s.registry, &w.rules, ore, game.inventory_held(&c.inventory), {})
	testing.expect_value(t, need, 8)
	testing.expect_value(t, game.break_ticks(s.registry, &w.rules, ore, {}, {}), 30)
	testing.expect_value(t, game.break_ticks(s.registry, &w.rules, ore, {}, {.Instant_Break}), 0)
	gear_edit(rig, at, game.EDIT_FACE_BREAK_BEGIN)
	gear_edit(rig, at, game.EDIT_FACE_BREAK)
	if b, _ := block_at(w, at); !testing.expect_value(t, b, ore) {return}
	gear_edit(rig, at, game.EDIT_FACE_BREAK_BEGIN)
	harness_step(&rig.sess.h, need)
	gear_edit(rig, at, game.EDIT_FACE_BREAK)
	b, _ := block_at(w, at)
	testing.expect_value(t, b, game.Block.Air)
	harness_step(&rig.sess.h, 40) // (the drops picked up)
	testing.expect_value(t, item_count(c, ore_item), 2)

	// Worn defence and fall guard: a fall's 8 is 8 x 0.5 x 0.5, a blast's 8 is 4.
	c.protected_until = 0
	c.inventory.equipment[game.Equip_Slot.Chest] = {vest, 1, 0, 0}
	c.health = 20
	damage(s, c, 8, {kind = .Fall})
	testing.expect_value(t, c.health, 18)
	damage(s, c, 8, {kind = .Explosion})
	testing.expect_value(t, c.health, 14)
	c.inventory.equipment[game.Equip_Slot.Chest] = {}
	damage(s, c, 4, {kind = .Explosion})
	testing.expect_value(t, c.health, 10)

	// The salve: 4 at once, then a fifth of harm off and 3 a second for its 10 s.
	testing.expect(t, item_consume(s, c) != "", "used up a pick")
	item_give(s, c, salve, 1)
	for st, i in c.inventory.slots {if st.item == salve {hotbar_select(s, c, i)}}
	testing.expect_value(t, item_consume(s, c), "")
	testing.expect_value(t, c.health, 14)
	testing.expect_value(t, item_count(c, salve), 0)
	damage(s, c, 5, {kind = .Explosion})
	testing.expect_value(t, c.health, 10)
	harness_step(&rig.sess.h, game.TICK_RATE)
	testing.expectf(
		t,
		c.health >= 12.9 && c.health <= 13.1,
		"health %v after a second of regen",
		c.health,
	)
	harness_step(&rig.sess.h, 10 * game.TICK_RATE)
	before := c.health
	damage(s, c, 5, {kind = .Explosion})
	testing.expect_value(t, c.health, before - 5)
}
