package sandbox_server

import "core:fmt"
import "core:os"
import "core:testing"

import "common:game"
import "server:core"
import "server:playtest"

// copy_dir copies the directory from into to (made), files and directories.
@(private = "file")
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

// A sandbox universe saved by an older build (assets/fixtures/save-v6: save format 6)
// opens, brought up to date, with its sheep as they were: the shorn black one, the
// spotted one in love (one that came by itself: it does not go before a player is
// there to be far from), the lamb; and the stack of wool that lay on the ground.
@(test)
test_a_format_6_universe_keeps_its_sheep :: proc(t: ^testing.T) {
	dir :: "build/tmp/sandbox_save_v6"
	os.remove_all(dir)
	defer os.remove_all(dir)
	copy_dir("assets/fixtures/save-v6", dir)
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
		switch core.entity_kind(w, h) {
		case s.registry.engine.sheep:
			genes := core.entity_genes(w, h).genes
			br := core.entity_breeding(w, h)
			seen.shorn_black ||= core.entity_wool(w, h).shorn && game.genes_black(genes)
			seen.in_love ||= br.love > 0 && genes == {.Coat_A} && core.entity_is_natural(w, h)
			seen.lamb ||= br.growth < game.LAMB_TICKS && game.genes_spotted(genes) && br.wait > 0
		case s.registry.engine.item:
			seen.wool += core.entity_stack(w, h).count
		}
	}
	testing.expect_value(t, seen, Seen{true, true, true, 2})
}
