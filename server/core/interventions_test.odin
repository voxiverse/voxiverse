package core

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "common:intervention"

// The interventions log of a world: kept in order, saved in the save transaction, loaded
// again, listed by /interventions; a damaged file is moved aside, never half-read.

@(private = "file")
noted :: proc(g: ^Grief, what: string) -> (n: int) {
	for note in g.sess.mirror.notices {if strings.contains(note, what) {n += 1}}
	return
}

@(test)
test_interventions_save_and_load :: proc(t: ^testing.T) {
	dir := scratch_dir("interventions")
	defer delete(dir)
	defer os.remove_all(dir)
	g, ok := grief_open(t, dir)
	if !ok {grief_close(g); return}
	defer grief_close(g)
	w := grief_world(g)

	testing.expect(
		t,
		interventions_record(w, {day = 4, place = {1, 2, 3}, kind = .Built, actor = "ada"}),
	)
	testing.expect(
		t,
		interventions_record(
			w,
			{day = 1, place = {0, 0, 0}, kind = .Founded_Settlement, actor = "bob"},
		),
	)
	testing.expect(t, !interventions_record(w, {day = -3}))
	testing.expect_value(t, len(w.interventions.list), 2)
	cmd(g, "interventions")
	testing.expect_value(t, noted(g, "Founded_Settlement at 0 0 0 by bob"), 1)
	testing.expect_value(t, noted(g, "Built at 1 2 3 by ada"), 1)

	testing.expect(t, world_save(w))
	path := filepath.join({w.dir, INTERVENTIONS_FILE}, context.temp_allocator) or_else ""
	testing.expect(t, os.exists(path), "the save has no interventions file")
	grief_close_keep(g)

	g2, ok2 := grief_open(t, dir)
	defer grief_close(g2)
	if !ok2 {return}
	w2 := grief_world(g2)
	testing.expect_value(t, len(w2.interventions.list), 2)
	if len(w2.interventions.list) == 2 {
		testing.expect_value(t, w2.interventions.list[0].day, 1)
		testing.expect_value(t, w2.interventions.list[0].actor, "bob")
		testing.expect_value(t, w2.interventions.list[1].kind, intervention.Kind.Built)
	}
	// Saved again with nothing changed, it stays as it was.
	testing.expect(t, world_save(w2))
	grief_close_keep(g2)

	// Damage the file: the world refuses it whole, moves it aside and starts empty.
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	testing.expect(t, err == nil)
	data[len(data) / 2] ~= 0xff
	testing.expect(t, os.write_entire_file(path, data) == nil)
	// (loading reports it as an error, quieted here)
	quiet := context.logger
	quiet.lowest_level = .Fatal
	context.logger = quiet
	g3, ok3 := grief_open(t, dir)
	defer grief_close(g3)
	if !ok3 {return}
	testing.expect_value(t, len(grief_world(g3).interventions.list), 0)
	testing.expect(t, os.exists(strings.concatenate({path, ".bad"}, context.temp_allocator)))
}
