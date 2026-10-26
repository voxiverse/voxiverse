package server

import "core:fmt"
import "core:log"
import "core:math"
import "core:slice"
import "core:strings"

import "../base"
import "../game"
import "../worldgen"

// The world's generator, as players can change it: its parameters
// (worldgen.*, a cheat like rules: everyone is told in a Variables
// message) and regenerating the chunks around a player after a change.

// worldgen_variables: the generator's parameters for players (nothing for
// a generator without any).
worldgen_variables :: proc(w: ^World) -> (game.Variables, bool) {
	if w.chunks.gen.kind != .Earth {return {}, false}
	b := strings.builder_make(context.temp_allocator)
	for &v in worldgen.params_table().vars {
		t := worldgen.params_table()
		fmt.sbprintfln(&b, "%s = %s", base.var_name(t, &v), base.var_format(t, &w.params, &v))
	}
	return {strings.to_string(b)}, true
}

// set_worldgen changes a generator parameter for chunks generated from now
// on (`regen` makes those near again).
set_worldgen :: proc(s: ^Server, c: ^Client, name, value: string) {
	w := c.world
	if w.chunks.gen.kind != .Earth {
		notice(s, c, "This world's generator has no settings")
		return
	}
	switch err := base.var_set(worldgen.params_table(), &w.params, name, value); err {
	case .None, .Out_Of_Range:
		w.chunks.gen.params = w.params
		for &slot in w.natural {slot.valid = false} 	// the land's tops moved
		log.infof("server worldgen changed name=%s value=%s by=%s", name, value, client_name(c))
		if m, ok := worldgen_variables(w); ok {
			for &other in s.clients {
				if other.state == .Playing &&
				   other.world == w {state_put(s, &other, .Variables, &m)}
			}
		}
		notice(s, c, fmt.tprintf("%s changed: `regen` remakes the land near you", name))
	case .Unknown_Name, .Bad_Value:
		notice(s, c, fmt.tprintf("No setting %s, or not a value for it: %s", name, value))
	}
}

// regen remakes the chunks within radius (in chunks) around c from the
// generator as it is now, all but those edited (those keep their blocks):
// everyone who has them is told to drop them, and they are streamed again.
regen :: proc(w: ^World, c: ^Client, radius: i32) -> (count: int) {
	s := w.server
	p := c.player.position
	centre := game.chunk_of({i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))})
	drop := make([dynamic]game.Chunk_Pos, context.temp_allocator)
	for pos in w.chunks.by_pos {
		d := pos - centre
		if abs(d.x) > radius || abs(d.y) > radius || abs(d.z) > radius {continue}
		chunk := chunks_get(&w.chunks, pos)
		if chunk.state != .Ready || chunk.modified {continue}
		append(&drop, pos)
	}
	slice.sort_by(drop[:], game.chunk_pos_less) // (map order would decide pool slot reuse)
	for &other in s.clients {
		if other.state != .Playing || other.world != w {continue}
		dropped := false
		for pos in drop {
			if pos not_in other.has {continue}
			delete_key(&other.has, pos)
			send_message(s, &other, game.Unload_Chunk{pos})
			column := [2]i32{pos.x, pos.z}
			other.columns[column] -= 1
			if other.columns[column] == 0 {delete_key(&other.columns, column)}
			dropped = true
		}
		if dropped {other.cursor = 0} 	// stream them again, nearest first
	}
	for pos in drop {chunks_unload(&w.chunks, pos)}
	for &slot in w.natural {slot.valid = false}
	// The columns' tops, for those still holding chunks of them.
	for &other in s.clients {
		if other.state != .Playing || other.world != w {continue}
		for column, n in other.columns {
			d := column - [2]i32{centre.x, centre.z}
			if n > 0 &&
			   abs(d.x) <= radius &&
			   abs(d.y) <= radius {send_message(s, &other, column_message(w, column))}
		}
	}
	return len(drop)
}
