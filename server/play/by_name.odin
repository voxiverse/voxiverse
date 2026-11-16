package play

import "core:fmt"
import "core:strings"

import "common:game"

// By_Name: what a game keeps of each player across sessions, by the player's name (a
// racer's best, a hero's level, a commander's wins): at most N rows of the game's T, found
// or made by name, written to the universe's game.cfg as `<key> = <T's numbers> <name>`
// lines (the game says how T is written and read: its numbers, in order) and read back
// from the lines settings_read handed the game.
By_Name :: struct($T: typeid, $N: int) {
	rows:  [N]Named(T),
	count: int,
}

// Named: one row of a By_Name: a player's name and the game's T for it (its fields are the
// row's own, by `using`).
Named :: struct($T: typeid) {
	name:        [game.MAX_NAME_LENGTH]u8,
	name_len:    int,
	using value: T,
}

// named_name: whose a row is.
named_name :: proc(r: ^Named($T)) -> string {return string(r.name[:r.name_len])}

// by_name: the row of a name (made zero when make_it and there is room; nil otherwise).
by_name :: proc(t: ^By_Name($T, $N), name: string, make_it := false) -> ^Named(T) {
	for &r in t.rows[:t.count] {if named_name(&r) == name {return &r}}
	if !make_it || t.count >= N || len(name) == 0 || len(name) > game.MAX_NAME_LENGTH {return nil}
	r := &t.rows[t.count]
	t.count += 1
	r^ = {}
	r.name_len = copy(r.name[:], name)
	return r
}

// by_name_rows: the rows kept, in the order they were first made.
by_name_rows :: proc(t: ^By_Name($T, $N)) -> []Named(T) {return t.rows[:t.count]}

// by_name_save: a line a row, `<key> = <numbers> <name>`; write gives a row's numbers
// (space-separated) and may skip it (false: nothing worth keeping).
by_name_save :: proc(
	t: ^By_Name($T, $N),
	key: string,
	out: ^strings.Builder,
	write: proc(b: ^strings.Builder, v: ^T) -> bool,
) {
	for &r in t.rows[:t.count] {
		numbers := strings.builder_make(context.temp_allocator)
		if !write(&numbers, &r.value) {continue}
		fmt.sbprintfln(out, "%s = %s %s", key, strings.to_string(numbers), named_name(&r))
	}
}

// by_name_read: one saved line of the key read into its name's row: its fields but the
// last (the name) given to read, which judges them (out of bounds: false). False for a line
// that is not of this key, has no name, or does not fit.
by_name_read :: proc(
	t: ^By_Name($T, $N),
	key: string,
	line: Saved_Line,
	read: proc(fields: []string, v: ^T) -> bool,
) -> bool {
	if line.key != key {return false}
	f := strings.fields(line.value, context.temp_allocator)
	if len(f) < 1 {return false}
	r := by_name(t, f[len(f) - 1], make_it = true)
	if r == nil {return false}
	return read(f[:len(f) - 1], &r.value)
}
