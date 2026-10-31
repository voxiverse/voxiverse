package server

import "core:os"
import "core:strings"
import "core:testing"

import "common:game"

// M45b: region protection. A protection holds out a non-member's edits, by
// hand, by fill and by flowing water; its members and the owner pass; the list
// survives a save and a load.

@(private = "file")
Guest :: struct {
	owner: [dynamic]game.Grant,
}

// guest_begin makes c an ordinary player (may edit, has every item, may use
// bulk commands, no bypass); guest_end gives c its grants back.
@(private = "file")
guest_begin :: proc(g: ^Grief) -> Guest {
	c := grief_client(g)
	gu := Guest {
		owner = c.grants,
	}
	c.grants = make([dynamic]game.Grant)
	append(&c.grants, game.Grant{"world.edit", true, 0})
	append(&c.grants, game.Grant{"items.infinite", true, 0})
	append(&c.grants, game.Grant{"world.edit.bulk", true, 0})
	return gu
}

@(private = "file")
guest_end :: proc(g: ^Grief, gu: Guest) {
	c := grief_client(g)
	delete(c.grants)
	c.grants = gu.owner
}

@(private = "file")
told :: proc(g: ^Grief, what: string) -> (n: int) {
	for note in g.sess.mirror.notices {if strings.contains(note, what) {n += 1}}
	return
}

@(private = "file")
protected_count :: proc(g: ^Grief) -> int {return told(g, "This place is protected (yard)")}

@(test)
test_protection_refuses :: proc(t: ^testing.T) {
	dir := scratch_dir("protect")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	defer grief_close(g)
	w := grief_world(g)
	name := strings.clone(client_name(grief_client(g)))
	defer delete(name)

	// The yard: x 3..7, y 0..2, z -2..2 around the player's feet.
	cmd(g, "protect add yard %s", box(g, {3, 0, -2}, {7, 2, 2}))
	testing.expect_value(t, len(w.protections), 1)
	cmd(g, "protect add yard %s", box(g, {3, 0, -2}, {7, 2, 2})) // (a name is used once)
	testing.expect_value(t, len(w.protections), 1)
	cmd(g, "protect add Bad_Name %s", box(g, {3, 0, -2}, {7, 2, 2}))
	testing.expect_value(t, len(w.protections), 1)

	// The owner has bypass: it builds in the yard.
	inside, edge := at(g, 4, 0, 0), at(g, 2, 0, 0)
	testing.expect(t, hand(g, inside, .Stone), "the owner could not build in the yard")
	testing.expect(t, hand(g, inside, .Air), "the owner could not break in the yard")

	// An ordinary player may not: the edit is refused, said once a second.
	gu := guest_begin(g)
	testing.expect(t, !hand(g, inside, .Stone), "a guest built in the yard")
	testing.expect_value(t, block_at_pos(w, inside), game.Block.Air)
	run(g, 3)
	testing.expect_value(t, protected_count(g), 1)
	testing.expect(t, !hand(g, inside, .Stone))
	run(g, 3)
	testing.expect_value(t, protected_count(g), 1) // (not again within a second)
	run(g, 40)
	testing.expect(t, !hand(g, inside, .Stone))
	run(g, 3)
	testing.expect_value(t, protected_count(g), 2)
	testing.expect(t, hand(g, edge, .Stone), "outside the yard is free")
	testing.expect(t, hand(g, edge, .Air))

	// A fill skips the protected blocks and says how many: x 0..4 on one row
	// (3 outside, 2 inside).
	row := box(g, {0, 0, 0}, {4, 0, 0})
	cmd(g, "fill %s stone", row)
	testing.expect_value(t, block_at_pos(w, at(g, 2, 0, 0)), game.Block.Stone)
	testing.expect_value(t, block_at_pos(w, at(g, 3, 0, 0)), game.Block.Air)
	testing.expect_value(t, block_at_pos(w, at(g, 4, 0, 0)), game.Block.Air)
	testing.expect_value(t, told(g, "fill: 3 blocks changed, 2 protected"), 1)

	// Water poured beside the yard does not flow into it.
	cmd(g, "setblock %d %d %d water", at(g, 2, 0, -1).x, at(g, 2, 0, -1).y, at(g, 2, 0, -1).z)
	run(g, 200)
	for x in i32(3) ..= 7 {
		for z in i32(-2) ..= 2 {
			b := block_at_pos(w, at(g, x, 0, z))
			testing.expectf(t, !is_water(b), "water flowed into the yard at %d %d: %v", x, z, b)
		}
	}
	testing.expect(
		t,
		is_water(block_at_pos(w, at(g, 1, 0, -1))) || is_water(block_at_pos(w, at(g, 2, 0, -2))),
		"the water did not flow at all",
	)
	guest_end(g, gu)

	// A member passes (by character name), until removed.
	cmd(g, "protect member add yard %s", name)
	gu = guest_begin(g)
	testing.expect(t, hand(g, inside, .Stone), "a member could not build in the yard")
	guest_end(g, gu)
	cmd(g, "protect member remove yard %s", name)
	cmd(g, "protect member add yard bob")
	gu = guest_begin(g)
	testing.expect(t, !hand(g, inside, .Air), "a former member broke a block in the yard")
	guest_end(g, gu)

	// The commands round trip, and the list survives a save and a load.
	cmd(g, "protect add pond 10 0 10 12 3 14")
	testing.expect_value(t, len(w.protections), 2)
	yard := Box{at(g, 3, 0, -2), at(g, 7, 2, 2)}
	testing.expect(t, world_save(w))
	grief_close_keep(g)
	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	w2 := grief_world(g2)
	testing.expect_value(t, len(w2.protections), 2)
	if len(w2.protections) == 2 {
		testing.expect_value(t, w2.protections[0].name, "yard")
		testing.expect_value(t, w2.protections[0].box, yard)
		testing.expect_value(t, len(w2.protections[0].members), 1)
		testing.expect_value(t, w2.protections[1].box, Box{{10, 0, 10}, {12, 3, 14}})
	}
	cmd(g2, "protect remove yard")
	testing.expect_value(t, len(w2.protections), 1)
	testing.expect_value(t, protection_find(w2, "pond"), 0)
	cmd(g2, "protect list")
	testing.expect_value(t, told(g2, "pond: 10 0 10 to 12 3 14, members: none"), 1)
}

@(private = "file")
is_water :: proc(b: game.Block) -> bool {
	_, water := game.water_level(b)
	return water
}
