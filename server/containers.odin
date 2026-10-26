package server

import "core:fmt"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

import "../base"
import "../game"

// Blocks that hold things (M30): a chest's contents are a record kept with
// its block, by position, owned by the server, saved with the world
// (containers.cfg). Made when someone first opens the chest, dropped when the
// block is gone (its contents spill out). A player looking into a chest has
// its slots in their Inventory (chest, chest_open: game/inventory.odin), so
// the ordinary requests move stacks in and out of it, predicted by the
// client like the rest; the record is the truth, copied in before each
// request and out after it, and told to everyone else looking at it.

CONTAINERS_FILE :: "containers.cfg"

// CONTAINER_SWEEP_TICKS: how often the records and the lookers are checked
// against their blocks and reach.
@(private = "file")
CONTAINER_SWEEP_TICKS :: 10

// Chests are looked into from this far beyond the reach before they close.
@(private = "file")
CHEST_LEASH :: 2.0

Container :: struct {
	slots: [game.CHEST_SLOTS]game.Stack,
}

// use_block: c used the block at pos (right click): a chest opens.
@(private)
use_block :: proc(s: ^Server, c: ^Client, pos: game.Block_Pos) {
	w := c.world
	block, loaded := chunks_block(&w.chunks, pos)
	if !loaded || block != .Chest {return}
	if !game.in_reach(
		game.player_eye(c.player),
		pos,
		f64(w.rules.reach) + game.EDIT_REACH_SLACK,
	) {return}
	if _, was := c.open_chest.?; was {chest_close(c)}
	if pos not_in w.containers {w.containers[pos] = {}}
	c.open_chest = pos
	c.inventory.chest_open = true
	c.inventory.chest = w.containers[pos].slots
	c.inv_changed = true
	record(s, c, .Item_Used, "chest", at = pos)
}

// chest_close: c looks into nothing now.
@(private)
chest_close :: proc(c: ^Client) {
	c.open_chest = nil
	if c.inventory.chest_open {c.inv_changed = true}
	c.inventory.chest, c.inventory.chest_open = {}, false
}

// chest_valid: the chest c looks into is still there, and near.
@(private = "file")
chest_valid :: proc(c: ^Client, pos: game.Block_Pos) -> bool {
	block, loaded := chunks_block(&c.world.chunks, pos)
	return(
		loaded &&
		block == .Chest &&
		game.in_reach(game.player_eye(c.player), pos, f64(c.world.rules.reach) + CHEST_LEASH) \
	)
}

// chest_refresh: before a request, what c sees in its chest is what the
// record holds (others may have changed it); a chest no longer there or near
// closes.
@(private)
chest_refresh :: proc(s: ^Server, c: ^Client) {
	pos, open := c.open_chest.?
	if !open {return}
	if !chest_valid(c, pos) {
		chest_close(c)
		return
	}
	if rec, known := c.world.containers[pos]; known {c.inventory.chest = rec.slots}
}

// chest_keep: after a request, the record is what c's chest holds now, and
// everyone else looking at it is told; or c closed it.
@(private)
chest_keep :: proc(s: ^Server, c: ^Client) {
	pos, open := c.open_chest.?
	if !open {return}
	if !c.inventory.chest_open {
		c.open_chest = nil
		return
	}
	w := c.world
	rec := &w.containers[pos]
	if rec.slots == c.inventory.chest {return}
	rec.slots = c.inventory.chest
	for &other in s.clients {
		if &other == c || other.state != .Playing || other.world != w {continue}
		if p, looking := other.open_chest.?; looking && p == pos {
			other.inventory.chest = rec.slots
			other.inv_changed = true
		}
	}
}

// chest_gone: the block at pos is not a chest any more: everyone looking
// closes it, and what it held spills out (a world without drops spills too:
// they were somebody's).
@(private)
chest_gone :: proc(w: ^World, pos: game.Block_Pos) {
	rec, known := w.containers[pos]
	if !known {return}
	delete_key(&w.containers, pos)
	for &c in w.server.clients {
		if c.world != w {continue}
		if p, looking := c.open_chest.?; looking && p == pos {chest_close(&c)}
	}
	r := &w.entities.rng
	at := [3]f64{f64(pos.x) + 0.5, f64(pos.y) + 0.3, f64(pos.z) + 0.5}
	for st in rec.slots {
		if game.stack_empty(st) {continue}
		v := [3]f32{base.rng_f32_range(r, -1, 1), 2.5, base.rng_f32_range(r, -1, 1)}
		spawn_item(w, at, st, v, -1)
	}
}

// containers_tick: records whose block is gone (blown up, edited in bulk)
// are dropped with their contents spilled, and lookers who walked off or
// whose chest vanished close it.
@(private)
containers_tick :: proc(w: ^World) {
	s := w.server
	if s.tick % CONTAINER_SWEEP_TICKS != 0 {return}
	if len(w.containers) > 0 {
		gone := make([dynamic]game.Block_Pos, context.temp_allocator)
		for pos in w.containers {
			block, loaded := chunks_block(&w.chunks, pos)
			if loaded && block != .Chest {append(&gone, pos)}
		}
		slice.sort_by(gone[:], game.block_pos_less)
		for pos in gone {
			log.infof("server chest without its block dropped pos=%v", pos)
			chest_gone(w, pos)
		}
	}
	for &c in s.clients {
		if c.state != .Playing || c.world != w {continue}
		if pos, open := c.open_chest.?; open && !chest_valid(&c, pos) {chest_close(&c)}
	}
}

// containers.cfg: one line per chest: x y z, then slot:item:count for each
// stack in it.
@(private)
write_containers :: proc(w: ^World) -> bool {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintln(
		&b,
		"# Voxiverse containers (written by the server): x y z [slot:item:count ...]",
	)
	for pos, rec in w.containers {
		fmt.sbprintf(&b, "%d %d %d", pos.x, pos.y, pos.z)
		for st, i in rec.slots {
			if game.stack_empty(st) {continue}
			fmt.sbprintf(&b, " %d:%s:%d", i, game.item_name(st.item), st.count)
		}
		strings.write_byte(&b, '\n')
	}
	return write_atomically(
		filepath.join({w.dir, CONTAINERS_FILE}, context.temp_allocator) or_else CONTAINERS_FILE,
		b.buf[:],
	)
}

// load_containers brings back a saved world's chests. A record that does not
// read, or whose block is not there (checked as its chunk loads: the sweep),
// is dropped.
@(private)
load_containers :: proc(w: ^World) {
	if w.dir == "" {return}
	path := filepath.join({w.dir, CONTAINERS_FILE}, context.temp_allocator) or_else CONTAINERS_FILE
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {return} 	// none saved (a new world, or an older one)
	rest := string(data)
	skipped := 0
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || l[0] == '#' {continue}
		f := strings.fields(l, context.temp_allocator)
		ok := len(f) >= 3
		pos: game.Block_Pos
		rec: Container
		if ok {
			x, ok1 := strconv.parse_int(f[0])
			y, ok2 := strconv.parse_int(f[1])
			z, ok3 := strconv.parse_int(f[2])
			ok = ok1 && ok2 && ok3 && abs(x) < game.WORLD_LIMIT && abs(z) < game.WORLD_LIMIT
			pos = {i32(x), i32(y), i32(z)}
		}
		if ok {
			for token in f[3:] {
				parts := strings.split(token, ":", context.temp_allocator)
				if len(parts) != 3 {ok = false; break}
				slot, ok1 := strconv.parse_int(parts[0])
				item, known := game.item_by_name(parts[1])
				n, ok2 := strconv.parse_int(parts[2])
				if !ok1 ||
				   !known ||
				   !ok2 ||
				   slot < 0 ||
				   slot >= game.CHEST_SLOTS ||
				   n <= 0 ||
				   n > game.item_stack_size(item) {
					ok = false
					break
				}
				rec.slots[slot] = {item, n}
			}
		}
		if ok {w.containers[pos] = rec} else {skipped += 1}
	}
	log.infof("server chests loaded count=%d skipped=%d", len(w.containers), skipped)
}
