package sandbox_server

import "core:fmt"
import "core:os"
import "core:testing"

import "games:sandbox"
import "server:core"
import "server:playtest"

// copy_dir copies the directory from into to (made), files and directories.
copy_dir :: proc(from, to: string) {
	os.make_directory_all(to)
	entries, _ := os.read_all_directory_by_path(from, context.temp_allocator)
	for e in entries {
		src, dst := fmt.tprintf("%s/%s", from, e.name), fmt.tprintf("%s/%s", to, e.name)
		if e.type == .Directory {
			copy_dir(src, dst)
		} else if data, err := os.read_entire_file_from_path(src, context.temp_allocator);
		   err == nil {
			_ = os.write_entire_file(dst, data)
		}
	}
}

// A sandbox universe saved by an older build opens, brought up to date, with its sheep as
// they were, now the sandbox's (sandbox:sheep, their records the game's): the shorn black
// one, the spotted one in love (one that came by itself: it does not go before a player is
// there to be far from), the lamb; and the stack of wool that lay on the ground. Format 6
// (assets/fixtures/save-v6) from before the entities' fields were named, format 7
// (assets/fixtures/save-v7) from the commit before the sheep left the engine.
@(test)
test_an_older_universe_keeps_its_sheep :: proc(t: ^testing.T) {
	for fixture in ([]string{"assets/fixtures/save-v6", "assets/fixtures/save-v7"}) {
		keeps_its_sheep(t, fixture)
	}
}

// A sandbox universe of format 8 (assets/fixtures/save-v8, from the commit before the
// markets left the engine) opens with its markets as they were, now the sandbox's: the
// world's economy file and interventions log read back, and the trader's silver, cargo and
// the prices it saw its character's record.
@(test)
test_an_older_universe_keeps_its_markets :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_save_markets"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_dir("assets/fixtures/save-v8", dir)
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	sw := world_of(s.home)
	testing.expect(t, sw.economy != nil, "the economy file was not read")
	testing.expect_value(t, len(sw.interventions.list), 2)
	if len(sw.interventions.list) == 2 {
		testing.expect_value(
			t,
			sw.interventions.list[0].kind,
			Intervention_Kind.Founded_Settlement,
		)
		testing.expect_value(t, sw.interventions.list[0].actor, "trader")
	}
	r, found := core.player_record(s, "trader")
	defer core.counters_free(&r.stats)
	if !testing.expect(t, found, "the trader's character is gone") {return}
	rec := (^Trader_Record)(&r.character_data.bytes)
	testing.expect_value(t, rec.cash, 9897.249825109646)
	testing.expect_value(t, rec.cargo[sandbox.Good.Grain], 217.4607)
	testing.expect_value(t, rec.count, 8)
	testing.expect(t, rec.given, "a trader of format 8 would be given the purse again")
	seen, known := trader_known(rec, 82623, .Salt)
	testing.expect(t, known && seen.price == 3 && seen.month == 3, "the prices it saw are gone")
}

@(private = "file")
keeps_its_sheep :: proc(t: ^testing.T, fixture: string) {
	dir :: "build/tmp/sandbox_save_older"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_dir(fixture, dir)
	rig := new(playtest.Rig)
	defer free(rig)
	if !playtest.start(t, rig, GAME, {save_dir = dir}) {return}
	defer playtest.stop(rig)
	s := playtest.srv(rig)
	w := s.home
	Seen :: struct {
		shorn_black, in_love, lamb: bool,
		wool:                       int,
	}
	seen: Seen
	it := core.entities_each(w)
	for h in core.entities_next(&it) {
		if d := sheep(s, w, h); d != nil {
			seen.shorn_black ||= d.shorn && sandbox.genes_black(d.genes)
			seen.in_love ||= d.love > 0 && d.genes == {.Coat_A} && core.entity_is_natural(w, h)
			seen.lamb ||= d.grows > 0 && sandbox.genes_spotted(d.genes) && d.wait > 0
		} else if core.entity_kind(w, h) == s.registry.engine.item {
			seen.wool += core.entity_stack(w, h).count
		}
	}
	testing.expectf(
		t,
		seen == {true, true, true, seen.wool} && seen.wool >= 2,
		"%s: %v",
		fixture,
		seen,
	)
}
