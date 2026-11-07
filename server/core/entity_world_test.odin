package core

import "core:testing"

import "common:game"

@(private = "file")
test_registry :: proc() -> ^game.Registry {
	reg, _ := game.registry_build({game.base_pack_source(context.temp_allocator)})
	return reg
}

@(test)
test_spawn_tag_kill :: proc(t: ^testing.T) {
	reg := test_registry()
	if reg == nil {return}
	defer game.registry_destroy(reg)
	sheep, _ := game.registry_kind(reg, "sheep")
	rocket, _ := game.registry_kind(reg, "rocket")

	ew: Entity_World
	entity_world_init(&ew, 1, 8)
	defer entity_world_destroy(&ew)
	act := Act{}

	// errors
	_, _, err := entity_world_spawn(&ew, reg, 0, {}, act)
	testing.expect_value(t, err, Spawn_Error.Unknown_Kind)
	_, _, err = entity_world_spawn(&ew, reg, 99, {}, act)
	testing.expect_value(t, err, Spawn_Error.Unknown_Kind)

	id, h, e1 := entity_world_spawn(&ew, reg, sheep, {1, 2, 3}, act)
	testing.expect_value(t, e1, Spawn_Error.None)
	testing.expect(t, id != 0)
	game.store_apply(&ew.store)
	tf := game.store_get(&ew.store, h, game.C_TRANSFORM, game.Transform)
	testing.expect_value(t, tf.position, [3]f64{1, 2, 3})
	testing.expect_value(
		t,
		game.store_get(&ew.store, h, game.C_HEALTH, game.Entity_Health).health,
		4,
	)
	testing.expect_value(t, game.spatial_count_entries(&ew.spatial), 1)
	testing.expect_value(t, game.spatial_count(&ew.spatial, {1, 2, 3}, 2, {}), 1)

	// tags
	// the first tag adds the component, so it shows after store_apply
	testing.expect_value(t, entity_tag(&ew, h, "flock"), Tag_Error.None)
	game.store_apply(&ew.store)
	testing.expect_value(t, entity_tag(&ew, h, "flock"), Tag_Error.None)
	testing.expect(t, entity_has_tag(&ew, h, "flock"))
	testing.expect(t, !entity_has_tag(&ew, h, "herd"))
	testing.expect_value(t, entity_tag(&ew, h, "Bad Name"), Tag_Error.Bad_Name)
	testing.expect_value(t, entity_tag(&ew, h, ""), Tag_Error.Bad_Name)
	for n in ([?]string{"a", "b", "c"}) {
		testing.expect_value(t, entity_tag(&ew, h, n), Tag_Error.None)
	}
	testing.expect_value(t, entity_tag(&ew, h, "d"), Tag_Error.Tags_Full)
	entity_untag(&ew, h, "flock")
	testing.expect(t, !entity_has_tag(&ew, h, "flock"))

	// the 257th name is refused
	other, oh, _ := entity_world_spawn(&ew, reg, sheep, {}, act)
	_ = other
	game.store_apply(&ew.store)
	buf: [8]u8
	made := 0
	_ = entity_tag(&ew, oh, "x")
	game.store_apply(&ew.store)
	entity_untag(&ew, oh, "x")
	for i in 0 ..< 300 {
		buf[0] = 'n'
		buf[1] = u8('a' + i / 26 % 26)
		buf[2] = u8('a' + i % 26)
		if entity_tag(&ew, oh, string(buf[:3])) == .None {
			made += 1
			entity_untag(&ew, oh, string(buf[:3]))
		} else {
			testing.expect_value(t, len(ew.tag_names), MAX_TAG_NAMES)
			break
		}
	}
	testing.expect_value(t, made + 6, MAX_TAG_NAMES) // a, b, c, d, flock, x were interned first

	// a sheep hurt by a rocket dies with it as killer; with none 11 s later
	rid, _, _ := entity_world_spawn(&ew, reg, rocket, {}, act)
	game.store_apply(&ew.store)
	entity_world_begin_tick(&ew)
	testing.expect(t, entity_hurt(&ew, h, 4, act, rid, 7))
	testing.expect_value(t, len(ew.deaths), 1)
	testing.expect_value(t, ew.deaths[0].killer, rid)
	testing.expect_value(t, ew.deaths[0].id, id)
	testing.expect_value(t, ew.deaths[0].kind, sheep)
	testing.expect_value(t, ew.deaths[0].cause, u8(7))
	testing.expect_value(t, ew.deaths[0].position, [3]f64{1, 2, 3})
	game.store_apply(&ew.store)
	_, found := game.store_find(&ew.store, id)
	testing.expect(t, !found)
	testing.expect(t, entity_hurt(&ew, h, 1, act, 0) == false)

	entity_world_begin_tick(&ew)
	testing.expect_value(t, len(ew.deaths), 0)
	_, h2, _ := entity_world_spawn(&ew, reg, sheep, {}, act)
	game.store_apply(&ew.store)
	entity_hurt(&ew, h2, 1, act, rid)
	for _ in 0 ..< 11 * game.TICK_RATE {entity_world_begin_tick(&ew)}
	entity_kill(&ew, h2, 0, act)
	testing.expect_value(t, len(ew.deaths), 1)
	testing.expect_value(t, ew.deaths[0].killer, game.Entity_Id(0))
}

@(test)
test_spawn_full :: proc(t: ^testing.T) {
	reg := test_registry()
	if reg == nil {return}
	defer game.registry_destroy(reg)
	sheep, _ := game.registry_kind(reg, "sheep")
	ew: Entity_World
	entity_world_init(&ew, 1, 4)
	defer entity_world_destroy(&ew)
	for _ in 0 ..< 4 {
		_, _, err := entity_world_spawn(&ew, reg, sheep, {}, Act{})
		testing.expect_value(t, err, Spawn_Error.None)
	}
	_, _, err := entity_world_spawn(&ew, reg, sheep, {}, Act{})
	testing.expect_value(t, err, Spawn_Error.Full)
	game.store_apply(&ew.store)
	testing.expect_value(t, game.store_count(&ew.store), 4)
	testing.expect_value(t, game.spatial_count_entries(&ew.spatial), 4)
}

@(test)
test_world_holds_entity_world :: proc(t: ^testing.T) {
	// the world's entity world is live and counts ticks beside the fixed list
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	before := w.entity_world.tick
	entities_tick(w)
	testing.expect_value(t, w.entity_world.tick, before + 1)
	testing.expect_value(t, game.store_count(&w.entity_world.store), 0)
}

@(test)
test_world_spawn_not_loaded :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	sheep, _ := game.registry_kind(h.srv.registry, "sheep")
	_, _, err := world_entity_spawn(w, sheep, {1e6, 64, 1e6}, Act{})
	testing.expect_value(t, err, Spawn_Error.Not_Loaded)
	testing.expect_value(t, game.store_count(&w.entity_world.store), 0)
	// a kill nobody knew of records the death and sends nothing
	id, eh, err2 := entity_world_spawn(w.entity_world, h.srv.registry, sheep, {1, 64, 1}, Act{})
	testing.expect_value(t, err2, Spawn_Error.None)
	game.store_apply(&w.entity_world.store)
	world_entity_kill(w, eh, 3, Act{})
	testing.expect_value(t, len(w.entity_world.deaths), 1)
	testing.expect_value(t, w.entity_world.deaths[0].id, id)
}

@(test)
test_tag_near :: proc(t: ^testing.T) {
	reg := test_registry()
	if reg == nil {return}
	defer game.registry_destroy(reg)
	sheep, _ := game.registry_kind(reg, "sheep")
	rocket, _ := game.registry_kind(reg, "rocket")
	ew: Entity_World
	entity_world_init(&ew, 1, 8)
	defer entity_world_destroy(&ew)
	_, near, _ := entity_world_spawn(&ew, reg, sheep, {1, 2, 3}, Act{})
	_, far, _ := entity_world_spawn(&ew, reg, sheep, {100, 2, 3}, Act{})
	_, rk, _ := entity_world_spawn(&ew, reg, rocket, {2, 2, 3}, Act{})
	game.store_apply(&ew.store)

	n, err := entity_tag_near(&ew, sheep, {0, 2, 3}, 10, true, "flock")
	testing.expect_value(t, err, Tag_Error.None)
	testing.expect_value(t, n, 1)
	game.store_apply(&ew.store)
	testing.expect(t, entity_has_tag(&ew, near, "flock"))
	testing.expect(t, !entity_has_tag(&ew, far, "flock"))
	testing.expect(t, !entity_has_tag(&ew, rk, "flock"))

	n, _ = entity_tag_near(&ew, 0, {0, 2, 3}, 10, true, "flock")
	testing.expect_value(t, n, 2)
	n, _ = entity_tag_near(&ew, 0, {0, 2, 3}, 10, false, "flock")
	testing.expect_value(t, n, 2)
	testing.expect(t, !entity_has_tag(&ew, near, "flock"))
	_, err = entity_tag_near(&ew, 0, {0, 2, 3}, 10, true, "Bad Name")
	testing.expect_value(t, err, Tag_Error.Bad_Name)
}

@(private = "file")
Player_Probe :: struct {
	name:      string,
	travel_to: Maybe(game.Address),
	players:   int, // player entities in the client's world (by the spatial service)
	stored:    int, // the store's count
	same:      bool, // its Transform equals the client's position
	in_world:  bool, // the entity is in the client's own world
}

@(private = "file")
player_probe :: proc(s: ^Server, data: rawptr) {
	d := (^Player_Probe)(data)
	c := client_by_name(s, d.name)
	if c == nil {return}
	if a, ok := d.travel_to.?; ok {
		_ = travel(s, c, a)
		d.travel_to = nil
		return
	}
	ew := c.world.entity_world
	d.players = 0
	found: [dynamic]game.Entity_Id
	found.allocator = context.temp_allocator
	game.spatial_sphere(&ew.spatial, c.player.position, 1e4, {all = {.Player}}, &found)
	d.players = len(found)
	d.stored = game.store_count(&ew.store)
	h, ok := game.store_find(&ew.store, c.entity_id)
	d.in_world = ok && c.entity_world == c.world
	d.same = false
	if ok {
		if tf := game.store_get(&ew.store, h, game.C_TRANSFORM, game.Transform); tf != nil {
			d.same = tf.position == c.player.position
		}
	}
}

@(test)
test_players_are_entities :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	config := harness_world()
	config.listen = true
	if !testing.expect(t, harness_start(h, config)) {return}
	stopped := false
	defer if !stopped {harness_stop(h)}
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	if !testing.expect(
		t,
		net_wait(
			t,
			{a},
			proc(cs: []^Net_Client) -> bool {return cs[0].welcomed && cs[0].update.acked > 0},
			30,
		),
		"never joined",
	) {return}
	d := Player_Probe {
		name = "a",
	}
	home := h.srv.home
	// arriving: one player entity, where the player is, after every tick
	for _ in 0 ..< 5 {
		harness_step(h)
		call(&h.srv, player_probe, &d)
		testing.expect_value(t, d.players, 1)
		testing.expect(t, d.same, "the entity is not where the player is")
		testing.expect(t, d.in_world)
	}
	// travelling: it moves to the new world's store, and the old one is empty
	d.travel_to = game.address_derive(31)
	call(&h.srv, player_probe, &d)
	for _ in 0 ..< 3 {
		harness_step(h)
		call(&h.srv, player_probe, &d)
		testing.expect_value(t, d.players, 1)
		testing.expect(t, d.same, "the entity is not where the player is")
		testing.expect(t, d.in_world)
	}
	testing.expect(t, h.srv.clients[0].world != home)
	testing.expect_value(t, game.store_count(&home.entity_world.store), 0)
	testing.expect_value(t, game.spatial_count_entries(&home.entity_world.spatial), 0)
	// leaving: despawned
	world := h.srv.clients[0].world
	net_close(a)
	a^ = {}
	for _ in 0 ..< 600 {
		harness_step(h)
		if h.srv.clients[0].state != .Playing {break}
	}
	harness_step(h, 2)
	testing.expect_value(t, h.srv.clients[0].state, Client_State.Free)
	testing.expect_value(t, game.store_count(&world.entity_world.store), 0)
	testing.expect_value(t, game.spatial_count_entries(&world.entity_world.spatial), 0)
	testing.expect(t, harness_stop(h))
	stopped = true
}

@(private = "file")
Sync_Probe :: struct {
	listed:    int, // entities in the list
	entries:   int, // spatial entries, players excluded
	at_rest:   int, // listed entities whose spatial box is their own box
	moved:     bool, // some entity is no longer where it spawned
	spawned:   [dynamic][3]f64,
	spawn_now: bool,
}

@(private = "file")
sync_probe :: proc(s: ^Server, data: rawptr) {
	d := (^Sync_Probe)(data)
	c := client_by_name(s, "a")
	if c == nil {return}
	w := c.world
	if d.spawn_now {
		d.spawn_now = false
		for dx in ([]f64{-3, 0, 3}) {
			p := c.player.position + {dx, 6, 3}
			ent := entity_spawn(w, test_reg().engine.sheep, p, false)
			append(&d.spawned, p)
			_ = ent
		}
		return
	}
	ew := w.entity_world
	d.listed, d.at_rest = entity_count(w), 0
	found: [dynamic]game.Entity_Id
	found.allocator = context.temp_allocator
	game.spatial_sphere(&ew.spatial, c.player.position, 1e4, {none = {.Player}}, &found)
	d.entries = len(found)
	for &e, i in entities_view(w) {
		if entity_pos(w, &e) != d.spawned[i] {d.moved = true}
		h, ok := game.store_find(&ew.store, game.Entity_Id(e.id))
		if !ok {continue}
		sl := game.store_get(&ew.store, h, C_SPATIAL_LINK, Spatial_Link)
		if sl == nil {continue}
		lo, hi := game.entity_box(game.kind_info(test_reg(), e.kind), entity_pos(w, &e))
		got := game.spatial_get(&ew.spatial, sl.handle)
		if got.lo == lo && got.hi == hi {d.at_rest += 1}
	}
}

// The spatial service follows the list: after every tick each listed
// entity's spatial box is its own box where it now is (it was left where the
// entity spawned, so queries saw a falling sheep in the air it left).
@(test)
test_spatial_follows_list :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	config := harness_world()
	config.listen = true
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	if !testing.expect(
		t,
		net_wait(
			t,
			{a},
			proc(cs: []^Net_Client) -> bool {return cs[0].welcomed && cs[0].update.acked > 0},
			30,
		),
		"never joined",
	) {return}
	d := Sync_Probe {
		spawn_now = true,
	}
	defer delete(d.spawned)
	call(&h.srv, sync_probe, &d)
	for _ in 0 ..< 40 {
		harness_step(h)
		call(&h.srv, sync_probe, &d)
		testing.expect_value(t, d.listed, 3)
		testing.expect_value(t, d.entries, 3)
		testing.expect_value(t, d.at_rest, 3)
	}
	testing.expect(t, d.moved, "the sheep never fell: the test proves nothing")
}

Mate_Probe :: struct {
	spawn_now: bool,
	checked:   int, // sheep asked
	found:     int, // of those, how many had a mate
	wrong:     int, // answers that differ from the list's own nearest
}

@(private = "file")
mate_probe :: proc(s: ^Server, data: rawptr) {
	d := (^Mate_Probe)(data)
	c := client_by_name(s, "a")
	if c == nil {return}
	w := c.world
	if d.spawn_now {
		d.spawn_now = false
		for i in 0 ..< 6 {
			p := c.player.position + {f64(i) * 1.5 - 4, 0, 4}
			if ent := entity_spawn(w, test_reg().engine.sheep, p, false); ent != nil {
				entity_breeding(w, ent).love = 1000 if i % 3 != 2 else 0
				entity_breeding(w, ent).growth = game.LAMB_TICKS if i != 4 else 0
			}
		}
		return
	}
	for &ent in entities_view(w) {
		if ent.kind != test_reg().engine.sheep {continue}
		want: ^Entity
		best := f64(game.BREED_RANGE * game.BREED_RANGE)
		for &o in entities_view(w) {
			if o.id == ent.id ||
			   o.kind != test_reg().engine.sheep ||
			   entity_breeding(w, &o).love <= 0 {continue}
			if entity_breeding(w, &o).growth < game.LAMB_TICKS {continue}
			v := entity_pos(w, &o) - entity_pos(w, &ent)
			if dd := v.x * v.x + v.y * v.y + v.z * v.z; dd < best {want, best = &o, dd}
		}
		d.checked += 1
		if want != nil {d.found += 1}
		if mate_for(w, &ent) != want {d.wrong += 1}
	}
}

// mate_for asks the spatial service: for sheep in love and not, lambs among
// them, falling and standing, it names the same mate a search of the list does.
@(test)
test_mate_for_matches_list :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	config := harness_world()
	config.listen = true
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	a := new(Net_Client)
	defer free(a)
	net_connect(a, 0, "a", h = h)
	defer net_close(a)
	if !testing.expect(
		t,
		net_wait(
			t,
			{a},
			proc(cs: []^Net_Client) -> bool {return cs[0].welcomed && cs[0].update.acked > 0},
			30,
		),
		"never joined",
	) {return}
	d := Mate_Probe {
		spawn_now = true,
	}
	call(&h.srv, mate_probe, &d)
	for _ in 0 ..< 10 {
		harness_step(h)
		call(&h.srv, mate_probe, &d)
	}
	testing.expect_value(t, d.wrong, 0)
	testing.expect(t, d.found > 0, "no sheep had a mate: the test proves nothing")
}

// entity_matches_store: an entity has the store's transform, health and age.
@(private = "file")
entity_matches_store :: proc(t: ^testing.T, w: ^World, ent: ^Entity) {
	tf := entity_transform(w, ent)
	hp := entity_health(w, ent)
	age := entity_age(w, ent)
	if tf == nil || hp == nil || age == nil || entity_physics(w, ent) == nil {
		testing.expect(t, false, "an entity lacks transform, physics, health or age")
		return
	}
}

@(test)
test_store_copies_follow_the_list :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	reg := w.server.registry
	sheep := entity_spawn(w, reg.engine.sheep, {8.5, 40, 8.5}, true)
	item := spawn_item(w, {10.5, 40, 8.5}, {game.item_of_block(reg, .Wool), 1, 0}, {1, 2, 3}, -1)
	testing.expect(t, sheep != nil && item != nil)
	if sheep == nil || item == nil {return}
	// the components exist when the spawn returns
	entity_matches_store(t, w, sheep)
	entity_matches_store(t, w, item)
	testing.expect(t, entity_is_natural(w, sheep))
	sheep_id, item_id := sheep.id, item.id
	for _ in 0 ..< 30 {
		entities_tick(w)
		a, _ := entity_find(w, sheep_id)
		b, _ := entity_find(w, item_id)
		if a != nil {entity_matches_store(t, w, a)}
		if b != nil {entity_matches_store(t, w, b)}
	}
	if a, _ := entity_find(w, sheep_id); a != nil {
		entity_attack(w, a, {0, 40, 0})
		entity_matches_store(t, w, a)
	}
}

// The exit test of the entity store: a sheep and an item go in through the
// door and live, move, are hurt, age and despawn with every field read from
// the store (Entity holds none of body, yaw, pitch, health, natural, age).
@(test)
test_entities_live_in_the_store :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	reg := w.server.registry
	sheep := entity_spawn(w, reg.engine.sheep, {8.5, 40, 8.5}, false)
	item := spawn_item(w, {10.5, 40, 8.5}, {game.item_of_block(reg, .Wool), 1, 0}, {1, 2, 3}, -1)
	if !testing.expect(t, sheep != nil && item != nil) {return}
	sheep_id, item_id := sheep.id, item.id
	// spawned: in the store, with what the spawn gave
	testing.expect_value(t, entity_pos(w, sheep), [3]f64{8.5, 40, 8.5})
	testing.expect_value(t, entity_health_of(w, sheep), game.kind_info(reg, sheep.kind).health)
	testing.expect_value(t, entity_age_of(w, sheep), 0)
	testing.expect(t, !entity_is_natural(w, sheep))
	wild := entity_spawn(w, reg.engine.sheep, {20.5, 40, 8.5}, true)
	testing.expect(t, wild != nil && entity_is_natural(w, wild))
	testing.expect_value(t, entity_velocity(w, item), [3]f32{1, 2, 3})
	// moved: the store says where, and how fast
	for _ in 0 ..< 5 {entities_tick(w)}
	item, _ = entity_find(w, item_id)
	sheep, _ = entity_find(w, sheep_id)
	if !testing.expect(t, item != nil && sheep != nil) {return}
	entity_set_pos(w, item, {11.5, 41, 8.5})
	entity_set_velocity(w, item, {4, 5, 6})
	entity_set_on_ground(w, item, true)
	testing.expect_value(t, entity_pos(w, item), [3]f64{11.5, 41, 8.5})
	testing.expect_value(t, entity_velocity(w, item), [3]f32{4, 5, 6})
	testing.expect(t, entity_on_ground(w, item))
	testing.expect_value(t, entity_age_of(w, item), 5)
	testing.expect_value(t, entity_age_of(w, sheep), 5)
	// hurt: health and knockback are in the store
	before := entity_health_of(w, sheep)
	entity_attack(w, sheep, {0, 40, 0})
	testing.expect(t, entity_health_of(w, sheep) < before, "health did not drop")
	testing.expect(t, !entity_on_ground(w, sheep))
	testing.expect(t, entity_velocity(w, sheep) != {}, "no knockback")
	// aged: set, then read back
	entity_set_age(w, item, 100)
	testing.expect_value(t, entity_age_of(w, item), 100)
	// despawned: gone from the list and from the store
	testing.expect(t, entity_remove(w, sheep_id))
	game.store_apply(&w.entity_world.store)
	_, found := game.store_find(&w.entity_world.store, game.Entity_Id(sheep_id))
	testing.expect(t, !found, "the despawned sheep is still in the store")
}

// A sheep's wool, genes and breeding, a dropped stack and a rocket's owner
// live in the store's components: written through the door, they are in the
// component rows, and a rocket without wool reads the defaults.
@(test)
test_plain_components_live_in_the_store :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	if !testing.expect(t, harness_start(h, harness_world())) {return}
	defer harness_stop(h)
	w := h.srv.home
	reg := w.server.registry
	st := &w.entity_world.store
	sheep := entity_spawn(w, reg.engine.sheep, {8.5, 40, 8.5}, false)
	item := spawn_item(w, {10.5, 40, 8.5}, {game.item_of_block(reg, .Wool), 3, 0}, {}, 7)
	rocket := entity_spawn(w, reg.engine.rocket, {12.5, 40, 8.5}, false)
	if !testing.expect(t, sheep != nil && item != nil && rocket != nil) {return}
	// the spawn's values
	testing.expect_value(t, entity_breeding(w, sheep).growth, game.LAMB_TICKS)
	testing.expect(t, !entity_wool(w, sheep).shorn)
	testing.expect_value(t, entity_owner(w, rocket).client, -1)
	// shorn, bred (genes and a lamb's growth), picked up, owned: all in the rows
	entity_wool(w, sheep).shorn = true
	entity_genes(w, sheep).genes = game.WOOL_BLACK
	entity_breeding(w, sheep).love = 9
	entity_owner(w, rocket).client = 3
	entity_owner(w, rocket).action = 42
	wool := game.store_get(st, sheep.handle, game.C_WOOL, game.Wool)
	genes := game.store_get(st, sheep.handle, game.C_GENES, game.Component_Genes)
	breeding := game.store_get(st, sheep.handle, game.C_BREEDING, game.Breeding)
	stack := game.store_get(st, item.handle, game.C_STACK, game.Component_Stack)
	owner := game.store_get(st, rocket.handle, game.C_OWNER, game.Owner)
	if !testing.expect(
		t,
		wool != nil && genes != nil && breeding != nil && stack != nil && owner != nil,
	) {return}
	testing.expect(t, wool.shorn)
	testing.expect_value(t, genes.genes, game.WOOL_BLACK)
	testing.expect_value(t, breeding.love, 9)
	testing.expect_value(t, stack.stack.count, 3)
	testing.expect_value(t, owner.client, 3)
	testing.expect_value(t, owner.action, 42)
	testing.expect_value(t, entity_owner(w, item).client, 7)
	// a rocket has no wool: reads give the default, and no row appears
	testing.expect(t, !entity_wool(w, rocket).shorn)
	testing.expect(t, game.store_get(st, rocket.handle, game.C_WOOL, game.Wool) == nil)
}
