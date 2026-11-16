package core

import "core:testing"

import "common:game"
import "common:protocol"

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

// An entity heals up to its most, and not past it (a building put up a little each tick).
@(test)
test_an_entity_heals_up_to_its_most :: proc(t: ^testing.T) {
	sess := new(Session)
	defer free(sess)
	defer session_stop(sess)
	kind, ok := sides_start(t, sess)
	if !ok {return}
	w := sess.h.srv.home
	e := entity_spawn(w, kind, {2.5, 0, 0.5}, false)
	entity_set_max_health(w, e, 10)
	entity_harm(w, e, {amount = 7, kind = .Game})
	testing.expect_value(t, entity_health_of(w, e), 3)
	entity_heal(w, e, 4)
	testing.expect_value(t, entity_health_of(w, e), 7)
	entity_heal(w, e, 40)
	testing.expect_value(t, entity_health_of(w, e), 10)
}

@(private = "file")
Fog_Rig :: struct {
	sess:  Session,
	guest: Harness_Player,
}

// motion_sent: whether viewer is told where the player `id` is (the snapshot it is sent).
@(private = "file")
motion_sent :: proc(viewer: ^Client, id: u16) -> bool {
	return(
		protocol.replica_get(
			&viewer.tx.cur,
			int(protocol.State_Kind.Player_Motion),
			protocol.key_player(id),
		) !=
		nil \
	)
}

// Under fog a client is sent nothing its side cannot see: another side's player only where
// one of its own sees it, and a player on no side only what is on no side near it.
@(test)
test_fog_hides_what_a_side_does_not_see :: proc(t: ^testing.T) {
	rig := new(Fog_Rig)
	defer free(rig)
	config := harness_world()
	config.game = harness_creatures()
	config.listen = true
	if !testing.expect(t, session_start(&rig.sess, {}, false, with = config)) {
		session_stop(&rig.sess)
		return
	}
	defer session_stop(&rig.sess)
	harness_player_join(&rig.sess.h, &rig.guest, "guest")
	defer harness_player_free(&rig.guest)
	ready :: proc(data: rawptr) -> bool {
		rig := (^Fog_Rig)(data)
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
	kind, _ := game.registry_kind(s.registry, "creatures:walker")
	host := &s.clients[0]
	guest := harness_player_client(&rig.guest)
	host_id, guest_id := player_id(s, host), player_id(s, guest)
	host.player.position, guest.player.position = {0.5, 0, 0.5}, {6.5, 0, 0.5}
	harness_step(&rig.sess.h, 4)
	testing.expect(t, motion_sent(host, guest_id), "without fog a near player is told")

	// Two sides with no eyes: neither is told where the other stands, near as they are.
	world_fog(w, true)
	client_set_team(host, 1)
	client_set_team(guest, 2)
	harness_step(&rig.sess.h, 4)
	testing.expect(t, !motion_sent(host, guest_id), "told where a foe its side does not see is")
	testing.expect(t, !motion_sent(guest, host_id), "told where a foe its side does not see is")
	// An eye of the host's side beside the guest: the host is told, the guest still not.
	eye := entity_spawn(w, kind, {8.5, 0, 0.5}, false)
	entity_set_team(w, eye, 1)
	entity_set_vision(w, eye, 6)
	harness_step(&rig.sess.h, 4)
	testing.expect(t, motion_sent(host, guest_id), "not told of a foe its side sees")
	testing.expect(t, !motion_sent(guest, host_id), "told of a foe by its foe's eye")
	testing.expect(t, entity_known(guest, entity_id(w, eye)) == false, "told of an unseen eye")

	// On no side under fog: what is on no team near it, nothing a side has.
	neutral := entity_spawn(w, kind, {3.5, 0, 0.5}, false)
	client_set_team(host, 0)
	harness_step(&rig.sess.h, 4)
	testing.expect(t, !entity_known(host, entity_id(w, eye)), "a watcher told of a side's eye")
	testing.expect(t, entity_known(host, entity_id(w, neutral)), "a watcher not told of a neutral")
	testing.expect(t, !motion_sent(host, guest_id), "a watcher told where a side's player is")
	client_set_team(guest, 0)
	harness_step(&rig.sess.h, 4)
	testing.expect(t, motion_sent(host, guest_id), "a watcher not told of another on no side")
}
