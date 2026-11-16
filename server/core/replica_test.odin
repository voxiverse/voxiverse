package core

import "core:testing"

import "common:game"

// A game's records keyed by entity (a creature's name and rank): put to a player for the
// entities it knows (entity_known), they reach it under the entity's id and go when the
// entity does.

@(private = "file")
Tag :: struct {
	name:  string `net:"max=24"`,
	elite: bool,
}

@(private = "file")
TAG_KINDS :: game.Game_Kinds {
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
					game_put(s, &c, &tag, game.key_entity(id))
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
	tag := mirror_game_record(&sess.mirror, Tag, game.key_entity(entity_id(s.home, near)))
	if testing.expect(t, tag != nil, "the near sheep's tag never came") {
		testing.expect_value(t, tag.name, "Grimtooth")
		testing.expect(t, tag.elite)
	}
	testing.expect(
		t,
		mirror_game_record(&sess.mirror, Tag, game.key_entity(entity_id(s.home, far))) == nil,
		"a tag for an entity the player does not know",
	)
	id := entity_id(s.home, near)
	entity_gone(s.home, near)
	harness_step(&sess.h, 4)
	testing.expect(
		t,
		mirror_game_record(&sess.mirror, Tag, game.key_entity(id)) == nil,
		"the tag stayed",
	)
}
