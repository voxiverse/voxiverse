package core

import "core:testing"

import "common:game"

// Sides (sides.odin): no harm between two of a team, a team's look shown, and under fog a
// player on a team told of its own side's entities wherever they are and of the others only
// when one of its own sees them.

@(private = "file")
sides_start :: proc(t: ^testing.T, sess: ^Session) -> (kind: game.Kind_Id, ok: bool) {
	config := harness_world()
	config.game = harness_creatures()
	if !testing.expect(t, session_start(sess, {}, false, with = config)) {return}
	_, ok = harness_step_until(&sess.h, proc(data: rawptr) -> bool {
			sess := (^Session)(data)
			return sess.mirror.welcomed && sess.h.srv.clients[0].state == .Playing
		}, sess, 600)
	if !testing.expect(t, ok, "never playing") {return}
	kind, ok = game.registry_kind(sess.h.srv.registry, "creatures:walker")
	testing.expect(t, ok)
	return
}

@(test)
test_a_team_does_not_harm_its_own :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	defer session_stop(sess)
	kind, ok := sides_start(t, sess)
	if !ok {return}
	w := sess.h.srv.home
	a := entity_spawn(w, kind, {2.5, 0, 0.5}, false)
	b := entity_spawn(w, kind, {4.5, 0, 0.5}, false)
	foe := entity_spawn(w, kind, {6.5, 0, 0.5}, false)
	entity_set_team(w, a, 1)
	entity_set_team(w, b, 1)
	entity_set_team(w, foe, 2)
	testing.expect_value(t, entity_team(w, a), 1)
	// Its kind's team look shows its team.
	info := game.kind_info(w.server.registry, kind)
	looks := entity_looks(w, w.server.registry, foe)
	testing.expect(t, looks & game.kind_look(info, "team2") != 0, "no team2 look")
	testing.expect(t, looks & game.kind_look(info, "team1") == 0, "the other team's look")
	by_a := Entity_Harm {
		amount   = 1,
		kind     = .Hit,
		creature = entity_id(w, a),
	}
	entity_harm(w, b, by_a)
	testing.expect_value(t, entity_health_of(w, b), 4) // (its own side: no harm)
	entity_harm(w, foe, by_a)
	testing.expect_value(t, entity_health_of(w, foe), 3)
	// A player on a team hurts no entity of it.
	c := &sess.h.srv.clients[0]
	client_set_team(c, 2)
	entity_harm(w, foe, {amount = 1, kind = .Hit, by = c})
	testing.expect_value(t, entity_health_of(w, foe), 3)
	entity_harm(w, a, {amount = 1, kind = .Hit, by = c})
	testing.expect_value(t, entity_health_of(w, a), 3)
	// Nobody's side (0) is nobody's friend.
	entity_set_team(w, b, 0)
	entity_harm(w, b, by_a)
	testing.expect_value(t, entity_health_of(w, b), 3)
}

@(test)
test_fog_tells_a_team_what_it_sees :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	defer session_stop(sess)
	kind, ok := sides_start(t, sess)
	if !ok {return}
	s := &sess.h.srv
	w := s.home
	c := &s.clients[0]
	client_set_team(c, 1)
	world_fog(w, true)
	// The player stands at the spawn: a foe beside it, its own scout far off.
	foe := entity_spawn(w, kind, {6.5, 0, 0.5}, false)
	entity_set_team(w, foe, 2)
	scout := entity_spawn(w, kind, {150.5, 0, 0.5}, false)
	entity_set_team(w, scout, 1)
	entity_set_vision(w, scout, 10)
	harness_step(&sess.h, 6)
	testing.expect(t, !entity_known(c, entity_id(w, foe)), "told of a foe no eye of its team sees")
	testing.expect(t, entity_known(c, entity_id(w, scout)), "not told of its own, far off")
	// The scout comes near the foe: the foe is told.
	entity_set_pos(w, scout, {12.5, 0, 0.5})
	harness_step(&sess.h, 6)
	testing.expect(t, entity_known(c, entity_id(w, foe)), "not told of the foe its scout sees")
	// It goes again: the foe is no longer told.
	entity_set_pos(w, scout, {150.5, 0, 0.5})
	harness_step(&sess.h, 6)
	testing.expect(t, !entity_known(c, entity_id(w, foe)), "still told of a foe out of sight")
	// Without fog, the near foe is told as always.
	world_fog(w, false)
	harness_step(&sess.h, 6)
	testing.expect(t, entity_known(c, entity_id(w, foe)))
}
