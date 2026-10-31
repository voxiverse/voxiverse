package server

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:testing"

import "common:base"

// M38: the simulation is a function of what reaches it at each tick boundary.
// A stepped server (no thread, inline chunk jobs) is run twice side by side
// through a scripted session, each with a mirror client on its pipe, and every
// tick's state hash is compared; the first difference is named by field.

Divergence :: struct {
	tick:    u64,
	section: Hash_Section,
	a, b:    string, // the first differing dump line of each
}
// session_land steps until the player has landed and the world is there
// (at most 900 ticks), unscripted: a failure is a test failure.
session_land :: proc(t: ^testing.T, sess: ^Session) -> bool {
	sess.scripted = false
	_, ok := harness_step_until(
		&sess.h,
		proc(data: rawptr) -> bool {return ready((^Session)(data))},
		sess,
		900,
	)
	return testing.expect(t, ok, "the player never landed")
}
@(private = "file")
dump_sections :: proc(s: ^Server, sections: Hash_Sections) -> string {
	b := strings.builder_make(context.temp_allocator)
	state_dump(s, sections, &b)
	return strings.to_string(b)
}

@(private = "file")
first_difference :: proc(a, b: string) -> (string, string) {
	la, lb :=
		strings.split_lines(a, context.temp_allocator),
		strings.split_lines(b, context.temp_allocator)
	for i in 0 ..< min(len(la), len(lb)) {
		if la[i] != lb[i] {return la[i], lb[i]}
	}
	if len(la) != len(lb) {return "(a line more)", "(a line fewer)"}
	return "", ""
}

// diverged names the first difference between two servers after the same tick.
@(private = "file")
diverged :: proc(a, b: ^Session, ha, hb: State_Hash) -> (d: Divergence, found: bool) {
	for sec in Hash_Section {
		if ha.sections[sec] == hb.sections[sec] {continue}
		la, lb := first_difference(dump_sections(&a.h.srv, {sec}), dump_sections(&b.h.srv, {sec}))
		return {tick = ha.tick, section = sec, a = la, b = lb}, true
	}
	return {}, false
}

@(private = "file")
divergence_text :: proc(d: Divergence) -> string {
	return fmt.tprintf("diverged at tick %d: %v: %s vs %s", d.tick, d.section, d.a, d.b)
}

@(private = "file")
maps_apart :: proc(a, b: ^Session) -> bool {
	table :: proc(s: ^Session) -> rawptr {
		return rawptr((^runtime.Raw_Map)(&s.h.srv.home.chunks.by_pos).data)
	}
	return table(a) != table(b)
}

// run_side_by_side runs two sessions the same way and compares every tick.
// perturb is applied to B only.
@(private = "file")
run_side_by_side :: proc(
	t: ^testing.T,
	ticks: int,
	perturb: Perturb,
	scripted: bool,
	log: bool,
) -> (
	d: Divergence,
	diverged_at: bool,
	a, b: ^Session,
) {
	a, b = new(Session), new(Session)
	if !testing.expect(t, session_start(a, {}, log && DETERMINISM_LOG != "")) {return}
	if !testing.expect(t, session_start(b, perturb, false)) {return}
	for i in 0 ..< 900 { 	// join, and stand until the world is there
		ha := session_step(a, false)
		hb := session_step(b, false)
		if dv, found := diverged(a, b, ha, hb); found {return dv, true, a, b}
		if ready(a) && ready(b) {break}
		if !testing.expect(t, i < 899, "the player never landed") {return}
	}
	for s in ([2]^Session{a, b}) {
		s.script_at = s.h.srv.tick
		s.mirror.corrections, s.mirror.mismatches, s.mirror.updates = 0, 0, 0
	}
	for _ in 0 ..< ticks {
		ha := session_step(a, scripted)
		hb := session_step(b, scripted)
		if dv, found := diverged(a, b, ha, hb); found {return dv, true, a, b}
		if ticks_of(a) % CHECKPOINT_EVERY == 0 || ticks_of(a) == u64(ticks) {
			ca, cb := checkpoint(a), checkpoint(b)
			append(&a.checkpoint, ca.server == ca.mirror && cb.server == cb.mirror)
			if a.logging {log_checkpoint(a, ca.server)}
		}
	}
	if a.logging {
		fmt.sbprintfln(&a.log, "end %016x", a.hashes[len(a.hashes) - 1].root)
		write_log(a)
	}
	return
}

@(private = "file")
log_checkpoint :: proc(sess: ^Session, world: u64) {
	fmt.sbprintfln(&sess.log, "dump %d", sess.h.srv.tick)
	all: Hash_Sections
	for sec in Hash_Section {all += {sec}}
	fmt.sbprint(&sess.log, dump_sections(&sess.h.srv, all))
	fmt.sbprintfln(&sess.log, "world %016x", world_hash(&sess.h.srv))
}

@(private = "file")
write_log :: proc(sess: ^Session) {
	path := DETERMINISM_LOG
	err := os.write_entire_file(path, strings.to_string(sess.log))
	if err != nil {fmt.eprintfln("determinism: cannot write %s: %v", path, err)}
}

@(private = "file")
finish :: proc(a, b: ^Session) {
	if a != nil && a.h.started {session_stop(a)}
	if b != nil && b.h.started {session_stop(b)}
	free(a)
	free(b)
}

// The side-by-side run: the same script on two servers whose maps sit at
// different addresses must hash alike at every tick.
@(test)
test_determinism_session :: proc(t: ^testing.T) {
	d, diverged_at, a, b := run_side_by_side(t, DETERMINISM_TICKS, {}, true, true)
	defer finish(a, b)
	if a == nil || b == nil {return}
	if !testing.expect(t, !diverged_at, divergence_text(d)) {return}
	testing.expect(t, maps_apart(a, b), "the two servers' maps sit at the same address")
	for sec in Hash_Section {
		if sec == .Containers || sec == .Gates {continue}
		if sec == .Rules && DETERMINISM_TICKS <= 7500 {continue} 	// (what the script does later)
		if sec == .Liquids && DETERMINISM_TICKS <= 2500 {continue}
		testing.expectf(t, len(a.seen[sec]) > 1, "the script never changed %v", sec)
	}
	for s in ([2]^Session{a, b}) {
		testing.expectf(
			t,
			s.mirror.mismatches == 0,
			"%d updates where prediction differed",
			s.mirror.mismatches,
		)
		testing.expectf(
			t,
			s.mirror.corrections == 0,
			"%d corrections, the first at tick %d",
			s.mirror.corrections,
			s.mirror.first_fix - s.script_at,
		)
		testing.expect(t, s.mirror.updates > DETERMINISM_TICKS / 2, "the mirror heard few updates")
	}
	for ok, i in a.checkpoint {
		testing.expectf(
			t,
			ok,
			"checkpoint %d: the mirror's chunks hash otherwise than the server's",
			i,
		)
	}
	testing.expect(t, len(a.checkpoint) > 0, "no checkpoint")
	for f in a.failures {testing.expect(t, false, f)}
}

// An introduced nondeterminism is caught by name, at its tick.
@(test)
test_divergence_named :: proc(t: ^testing.T) {
	Case :: struct {
		what:    Perturb_Kind,
		section: Hash_Section,
		path:    string,
	}
	cases := [?]Case {
		{.Entity_Yaw, .Entities, "entities[0].yaw"},
		{.Player_Velocity, .Players, "players[0].player.velocity.x"},
	}
	for c in cases {
		d, found, a, b := run_side_by_side(t, 600, {tick = 500, what = c.what}, true, false)
		defer finish(a, b)
		if !testing.expectf(t, found, "%v: no divergence", c.what) {continue}
		testing.expect_value(t, d.tick, 500)
		testing.expect_value(t, d.section, c.section)
		testing.expectf(
			t,
			strings.has_prefix(d.a, c.path) && strings.has_prefix(d.b, c.path),
			"%v: named %q vs %q, wanted %s",
			c.what,
			d.a,
			d.b,
			c.path,
		)
	}
}

// Two stepped servers hold the same pool slots for the same chunks after
// streaming and unloading.
@(test)
test_stepped_jobs_in_order :: proc(t: ^testing.T) {
	d, found, a, b := run_side_by_side(t, 400, {}, true, false)
	defer finish(a, b)
	if a == nil || b == nil {return}
	testing.expect(t, !found, divergence_text(d))
	slots :: proc(s: ^Session) -> [dynamic]u64 {
		out := make([dynamic]u64, context.temp_allocator)
		it: base.Pool_Iterator
		for c, h in base.pool_next(&s.h.srv.home.chunks.chunks, &it) {
			append(
				&out,
				u64(h) << 32 |
				u64(u32(c.pos.x)) ~
				u64(u32(c.pos.y)) << 11 ~
				u64(u32(c.pos.z)) << 22,
			)
		}
		return out
	}
	sa, sb := slots(a), slots(b)
	testing.expect(t, len(sa) > 100, "few chunks")
	testing.expect(t, slice.equal(sa[:], sb[:]), "the pool slots differ")
}
