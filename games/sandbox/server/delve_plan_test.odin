package sandbox_server

import "core:log"
import "core:testing"

import "common:game"
import "server:playtest"

// The delves' layouts over seeds (delve_plan, delve_draw): every one shut in its shells
// (nothing open touches the rock as the world made it), the boss's chamber walked to from
// the stair head, every room but a locked vault walked to, a locked vault and the reward vault
// shut until their door or ward goes and walked to then, the custodian's post in its hall,
// the same drawing every time for a seed.

LAYOUT_SEEDS :: 200

// room_point: where one stands at a room's edge on its cell's middle line (where nothing is
// drawn but floor), local.
@(private = "file")
room_point :: proc(d: ^Delve_Depth, room: ^Delve_Room, i: int) -> [3]i32 {
	m := delve_cell(i) * DELVE_CELL + DELVE_MID
	return {m.x, d.floor + 1, room.lo.y}
}

// opened: the drawing with every block of `block` in it made air (a door opened, a ward
// fallen; temporary memory).
@(private = "file")
opened :: proc(t: ^game.Template, block: game.Block) -> game.Template {
	o := game.Template{t.size, make([]u16, len(t.cells), context.temp_allocator)}
	for c, i in t.cells {o.cells[i] = u16(game.Block.Air) if c == u16(block) else c}
	return o
}

@(test)
test_delve_layouts_over_seeds :: proc(t: ^testing.T) {
	rig := new(Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	k := &delves_of(s).kit
	kinds: [Delve_Room_Kind]int
	posts: [Wild]int
	traps, vaults := 0, 0
	for n in 1 ..= LAYOUT_SEEDS {
		seed := u64(n) * 7919
		p := delve_plan(seed)
		again := delve_plan(seed)
		testing.expectf(t, p == again, "seed %d: two plans differ", seed)
		dr := delve_draw(&p, k)
		if leak, sealed := delve_sealed(&dr.t); !sealed {
			testing.expectf(t, false, "seed %d: the air at %v touches the rock", seed, leak)
			continue
		}
		head := [3]i32{p.entry.x + 3, DELVE_SURFACE + 1, p.entry.y}
		seen := delve_walk(&dr.t, head)
		walks := proc(t: ^game.Template, seen: []bool, p: [3]i32) -> bool {
			return seen[game.template_index(t, p)]
		}
		testing.expectf(
			t,
			delve_stands(&dr.t, head),
			"seed %d: nowhere to stand at the head",
			seed,
		)
		testing.expectf(
			t,
			walks(&dr.t, seen, dr.boss),
			"seed %d: the custodian's post is not walked to",
			seed,
		)
		deep := &p.depths[DELVE_DEPTHS - 1]
		testing.expectf(t, deep.rooms[deep.down].kind == .Boss, "seed %d: no boss's chamber", seed)
		for &d in p.depths {
			for &room, i in d.rooms {
				kinds[room.kind] += 1
				at := room_point(&d, &room, i)
				switch room.kind {
				case .Vault:
					vaults += 1
					testing.expectf(t, card(room.links) == 1, "seed %d: a vault on the way", seed)
					testing.expectf(
						t,
						!walks(&dr.t, seen, at),
						"seed %d: a locked vault is open",
						seed,
					)
				case .Landing,
				     .Descent,
				     .Guard_Post,
				     .Store_Room,
				     .Machine_Hall,
				     .Collapsed,
				     .Boss:
					testing.expectf(
						t,
						walks(&dr.t, seen, at),
						"seed %d: a %v is not walked to",
						seed,
						room.kind,
					)
				}
			}
		}
		// Keys open the locked vaults; the custodian's death, the reward vault.
		doors := opened(&dr.t, k.door)
		keyed := delve_walk(&doors, head)
		for &d in p.depths {
			if d.vault < 0 {continue}
			at := room_point(&d, &d.rooms[d.vault], d.vault)
			testing.expectf(
				t,
				walks(&doors, keyed, at),
				"seed %d: a key does not open its vault",
				seed,
			)
		}
		cell := delve_cell(deep.down)
		v := BOSS_VAULT
		inside := boss_place(cell, p.boss_from, DELVE_MID, v[1])
		reward := [3]i32{inside.x, deep.floor + 1, inside.y}
		testing.expectf(t, !walks(&dr.t, seen, reward), "seed %d: the reward vault is open", seed)
		warded := opened(&dr.t, k.ward)
		testing.expectf(
			t,
			delve_reaches(&warded, head, reward),
			"seed %d: the reward vault is not walked to",
			seed,
		)
		for c in dr.t.cells {
			if c == u16(k.plate) || c == u16(k.grid) {traps += 1}
		}
		for post in dr.posts[:dr.post_count] {
			posts[post.which] += 1
			testing.expectf(
				t,
				delve_stands(&dr.t, post.at),
				"seed %d: a %v posted in a block",
				seed,
				post.which,
			)
		}
	}
	log.infof(
		"delves over %d seeds: rooms %v, posts %v, trap blocks %d, locked vaults %d",
		LAYOUT_SEEDS,
		kinds,
		posts,
		traps,
		vaults,
	)
	testing.expect(t, vaults >= LAYOUT_SEEDS, "fewer than one locked vault a delve")
	testing.expect(t, traps > 0, "no traps")
}
