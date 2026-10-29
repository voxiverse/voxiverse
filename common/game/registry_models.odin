package game

import "core:fmt"
import "core:strconv"

// Voxel models in the registry: data/models/<name>.json,
//
//	{"pocket_gun": {"size": [4, 3, 1], "palette": ["#2b2d33", "#6f7480", "#a5acb8"],
//	                "slices": [["2211", "..11", "..1."]], "grip": [2, 1, 0]}}
//
// `size` is [length, height, width]; each slice is a side view of `height`
// rows of `length` characters, row 0 on top, column 0 at the front, slice 0
// on the left; `.` is empty, `1`..`4` a palette colour; `grip` is [column,
// row, slice] of the voxel the hand holds.

@(private)
read_model :: proc(b: ^Reg_Build, m: ^Merged_Def) -> Model_Def {
	def := Model_Def {
		id = m.id,
	}
	size: [3]int
	have_size := false
	if f := field_of(m, "size"); f != nil {
		ok := f.value.kind == .Array && len(f.value.items) == 3
		if ok {
			for e, i in f.value.items {
				if e.kind != .Int || e.i < 1 || e.i > MODEL_MAX_SIZE {ok = false; break}
				size[i] = int(e.i)
			}
		}
		if ok {
			have_size = true
			def.size = {u8(size[0]), u8(size[1]), u8(size[2])}
		} else {
			fail_field(
				b,
				f,
				f.value,
				fmt.aprintf(
					"size is [length, height, width], each a whole number 1..%d",
					MODEL_MAX_SIZE,
				),
			)
		}
	} else {
		fail(b, m.pack, m.file, m.line, m.column, "a model needs \"size\"")
	}
	if f := field_of(m, "palette"); f != nil {
		n := len(f.value.items) if f.value.kind == .Array else 0
		if n < MODEL_MIN_COLORS || n > MODEL_MAX_COLORS {
			fail_field(
				b,
				f,
				f.value,
				fmt.aprintf(
					"palette is %d or %d colours such as \"#a5acb8\"",
					MODEL_MIN_COLORS,
					MODEL_MAX_COLORS,
				),
			)
		} else {
			def.colors = u8(n)
			for e, i in f.value.items {
				c, ok := parse_hex_color(e)
				if !ok {fail_field(b, f, e, "a palette colour is \"#rrggbb\"")}
				def.palette[i] = c
			}
		}
	} else {
		fail(b, m.pack, m.file, m.line, m.column, "a model needs \"palette\"")
	}
	if f := field_of(m, "slices"); f != nil && have_size {
		read_model_slices(b, f, &def, size)
	} else if f == nil {
		fail(b, m.pack, m.file, m.line, m.column, "a model needs \"slices\"")
	}
	if f := field_of(m, "grip"); f != nil {
		if have_size {
			ok := f.value.kind == .Array && len(f.value.items) == 3
			at: [3]int // column, row, slice
			if ok {
				for e, i in f.value.items {
					if e.kind != .Int || e.i < 0 || e.i >= i64(size[i]) {ok = false; break}
					at[i] = int(e.i)
				}
			}
			if ok {
				// Model space: x the slice, y up from the bottom row, z the column.
				def.grip = {u8(at[2]), u8(size[1] - 1 - at[1]), u8(at[0])}
			} else {
				fail_field(b, f, f.value, "grip is [column, row, slice], a voxel inside the size")
			}
		}
	} else {
		fail(b, m.pack, m.file, m.line, m.column, "a model needs \"grip\"")
	}
	return def
}

@(private = "file")
parse_hex_color :: proc(v: Json_Value) -> (c: [4]u8, ok: bool) {
	if v.kind != .String || len(v.s) != 7 || v.s[0] != '#' {return}
	n, parsed := strconv.parse_uint(v.s[1:], 16)
	if !parsed {return}
	return {u8(n >> 16), u8(n >> 8), u8(n), 255}, true
}

@(private = "file")
read_model_slices :: proc(b: ^Reg_Build, f: ^Def_Field, def: ^Model_Def, size: [3]int) {
	before := len(b.errs)
	length, height, width := size[0], size[1], size[2]
	if f.value.kind != .Array || len(f.value.items) != width {
		fail_field(
			b,
			f,
			f.value,
			fmt.aprintf("slices is a list of %d slices (the width), got another count", width),
		)
		return
	}
	voxels := make([]u8, length * height * width)
	any_voxel := false
	for slice, x in f.value.items {
		if slice.kind != .Array || len(slice.items) != height {
			fail_field(
				b,
				f,
				slice,
				fmt.aprintf("a slice is a list of %d rows (the height)", height),
			)
			continue
		}
		for row, ry in slice.items {
			if row.kind != .String || len(row.s) != length {
				fail_field(
					b,
					f,
					row,
					fmt.aprintf("a row is a text of %d characters (the length)", length),
				)
				continue
			}
			y := height - 1 - ry
			for ch, c in transmute([]u8)row.s {
				v: u8
				switch {
				case ch == '.':
				case ch >= '1' && ch <= '4':
					v = ch - '0'
					if def.colors != 0 && v > def.colors {
						fail_field(
							b,
							f,
							row,
							fmt.aprintf(
								"\"%c\" is not in the palette of %d colours",
								rune(ch),
								def.colors,
							),
						)
						v = 0
					}
				case:
					fail_field(
						b,
						f,
						row,
						fmt.aprintf(
							"\"%c\" is not a voxel: \".\" or a palette number 1..4",
							rune(ch),
						),
					)
				}
				// Column 0 is the front (-z): z grows towards the back.
				voxels[x + c * width + y * width * length] = v
				if v != 0 {any_voxel = true}
			}
		}
	}
	if !any_voxel && len(b.errs) == before {
		fail_field(b, f, f.value, "a model has at least one voxel")
	}
	def.voxels = voxels
}
