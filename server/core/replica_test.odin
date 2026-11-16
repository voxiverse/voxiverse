package core

import "core:testing"

import "common:base"
import "common:game"
import "common:protocol"

// A game's records keyed by entity (a creature's name and rank): put to a player for the
// entities it knows (entity_known), they reach it under the entity's id and go when the
// entity does.

@(private = "file")
Tag :: struct {
	name:  string `net:"max=24"`,
	elite: bool,
}

@(private = "file")
TAG_KINDS :: protocol.Game_Kinds {
	states = {{name = "tags.tag", value = Tag, key = .Entity, max_records = 64}},
}

@(test)
test_game_records_keyed_by_entity :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	config := harness_world()
	config.game = {
		info = {id = "tags", name = "Tags"},
		kinds = TAG_KINDS,
		tick = proc(s: ^Server) {
			for &c in s.clients {
				if c.state != .Playing {continue}
				it := entities_each(s.home)
				for h in entities_next(&it) {
					id := entity_id(s.home, h)
					if !entity_known(&c, id) {continue}
					tag := Tag{"Grimtooth", true}
					game_put(s, &c, &tag, protocol.key_entity(id))
				}
			}
		},
	}
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {
		session_stop(sess)
		return
	}
	defer session_stop(sess)
	_, ok := harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok) {return}
	s := &sess.h.srv
	near := entity_spawn(s.home, s.registry.engine.sheep, {3.5, 0, 0.5}, false)
	far := entity_spawn(s.home, s.registry.engine.sheep, {200.5, 0, 0.5}, false)
	harness_step(&sess.h, 10)
	tag := mirror_game_record(&sess.mirror, Tag, protocol.key_entity(entity_id(s.home, near)))
	if testing.expect(t, tag != nil, "the near sheep's tag never came") {
		testing.expect_value(t, tag.name, "Grimtooth")
		testing.expect(t, tag.elite)
	}
	testing.expect(
		t,
		mirror_game_record(&sess.mirror, Tag, protocol.key_entity(entity_id(s.home, far))) == nil,
		"a tag for an entity the player does not know",
	)
	id := entity_id(s.home, near)
	entity_gone(s.home, near)
	harness_step(&sess.h, 4)
	testing.expect(
		t,
		mirror_game_record(&sess.mirror, Tag, protocol.key_entity(id)) == nil,
		"the tag stayed",
	)
}

// Past MAX_KNOWN_ENTITIES a client is told of the nearest: a crowd far off (the lower
// ids) gives way to the few beside it.
@(test)
test_entities_told_nearest_first :: proc(t: ^testing.T) {
	h := new(Harness)
	defer free(h)
	config := harness_world()
	if !testing.expect(t, harness_start(h, config)) {return}
	defer harness_stop(h)
	s := &h.srv
	w := s.home
	sheep := test_reg().engine.sheep
	for i in 0 ..< protocol.MAX_KNOWN_ENTITIES {
		a := f64(i) / protocol.MAX_KNOWN_ENTITIES * 6.28
		entity_spawn(w, sheep, {50 * base.cos(a), 0, 50 * base.sin(a)}, false)
	}
	near: [10]u32
	for &id, i in near {id = entity_id(w, entity_spawn(w, sheep, {f64(i) - 5, 0, 2}, false))}
	game.store_apply(&w.entity_world.store)
	entities_sync_spatial(w)
	c := new(Client)
	defer free(c)
	c.state, c.world = .Playing, w
	protocol.sender_init(&c.tx, &s.schema)
	defer protocol.sender_destroy(&c.tx)
	entities_put(s, c)
	for id in near {
		testing.expectf(
			t,
			protocol.replica_get(
				&c.tx.cur,
				int(protocol.State_Kind.Entity),
				protocol.key_entity(id),
			) !=
			nil,
			"the entity %d beside it was not told",
			id,
		)
	}
}
