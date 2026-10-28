package mesh

import "base:runtime"
import "core:sync"
import "core:testing"

import "../../common/game"

// Meshing shaped blocks: boxes, cover culling, interior faces, interpolated corners.

@(private = "file")
SHAPED_BLOCKS :: `{
  "slab": {
    "states": {"type": ["bottom", "top", "double"]},
    "shape": "voxiverse:slab", "opaque": false, "shades": true,
    "textures": {"all": "voxiverse:planks"}
  },
  "stairs": {
    "states": {"facing": ["north", "east", "south", "west"], "half": ["bottom", "top"]},
    "shape": "voxiverse:stairs", "opaque": false, "shades": true,
    "textures": {"all": "voxiverse:stone"}
  },
  "lad": {
    "states": {"facing": ["north", "east", "south", "west"]},
    "collision": "voxiverse:ladder", "selection": "voxiverse:ladder", "render_shape": "voxiverse:ladder",
    "opaque": false, "layer": "cutout", "textures": {"all": "voxiverse:planks"}
  }
}`

@(private = "file")
shaped_once: sync.Once
@(private = "file")
shaped_reg: ^game.Registry

@(private = "file")
shaped :: proc() -> ^game.Registry {
	sync.once_do(&shaped_once, proc() {
		context.allocator = runtime.default_allocator()
		files := []game.Pack_File {
			{"pack.json", transmute([]u8)string(`{"format": 1, "namespace": "shapes", "version": "1", "title": "T", "requires": ["voxiverse"]}`)},
			{"data/blocks/shaped.json", transmute([]u8)string(SHAPED_BLOCKS)},
		}
		sources := []game.Pack_Source{game.base_pack_source(runtime.default_allocator()), {"shapes", files}}
		reg, errs := game.registry_build(sources, .Server, runtime.default_allocator())
		if reg == nil {
			for e in errs {runtime.print_string(game.pack_error_text(e)); runtime.print_string("\n")}
			panic("shaped registry")
		}
		shaped_reg = reg
	})
	return shaped_reg
}

@(private = "file")
state :: proc(text: string) -> game.Block {
	b, ok := game.state_parse(shaped(), text)
	if !ok {panic(text)}
	return b
}

// faces_at: the quads of one texture's faces (all of them if layer is 0xFFFFFFFF).
@(private = "file")
quads_of :: proc(out: []Vertex, face: Face) -> (n: int) {
	for i := 0; i < len(out); i += 4 {if vertex_face(out[i]) == face {n += 1}}
	return
}

@(private = "file")
y_range :: proc(q: []Vertex) -> (lo, hi: i32) {
	lo, hi = max(i32), min(i32)
	for v in q {
		y := vertex_position(v).y
		lo, hi = min(lo, y), max(hi, y)
	}
	return
}

@(test)
test_cube_vertices_are_sixteenths :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	s[snapshot_index(3, 4, 5)] = .Stone
	mesh_chunk(shaped(), s, nil, &out)
	testing.expect_value(t, len(out), 24)
	for v in out {
		p := vertex_position(v)
		testing.expect(t, p.x == 48 || p.x == 64)
		testing.expect(t, p.y == 64 || p.y == 80)
		testing.expect(t, p.z == 80 || p.z == 96)
		sky, block := vertex_light(v)
		testing.expect_value(t, sky, 15)
		testing.expect_value(t, block, 0)
	}
}

@(test)
test_lone_bottom_slab :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	light := new(Light_Snapshot)
	defer free(light)
	out: [dynamic]Vertex
	defer delete(out)
	slab := state("shapes:slab[type=bottom]")
	s[snapshot_index(3, 4, 5)] = slab
	light[snapshot_index(3, 4, 5)] = 10 << 4 | 2
	for &l in light {if l == 0 {l = 15 << 4}}
	light[snapshot_index(3, 4, 5)] = 10 << 4 | 2
	mesh_chunk(shaped(), s, light, &out, merge = false)
	testing.expect_value(t, len(out), 6 * 4) // five boundary faces and the interior top
	for f in Face {testing.expect_value(t, quads_of(out[:], f), 1)}
	for i := 0; i < len(out); i += 4 {
		q := out[i:][:4]
		lo, hi := y_range(q)
		switch vertex_face(q[0]) {
		case .Pos_Y:
			// The interior top: at half height, open (AO 3), lit by its own cell.
			testing.expect_value(t, lo, 4 * 16 + 8)
			testing.expect_value(t, hi, 4 * 16 + 8)
			for v in q {
				testing.expect_value(t, vertex_ao(v), 3)
				sky, block := vertex_light(v)
				testing.expect_value(t, sky, 10)
				testing.expect_value(t, block, 2)
			}
		case .Neg_Y:
			testing.expect_value(t, lo, 4 * 16)
		case .Pos_X, .Neg_X, .Pos_Z, .Neg_Z:
			testing.expect_value(t, lo, 4 * 16)
			testing.expect_value(t, hi, 4 * 16 + 8)
		}
	}
}

@(test)
test_slabs_hide_and_show :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	bottom := state("shapes:slab[type=bottom]")
	top := state("shapes:slab[type=top]")
	// A bottom slab on stone hides the stone's top (and the slab's bottom).
	s[snapshot_index(3, 3, 5)] = .Stone
	s[snapshot_index(3, 4, 5)] = bottom
	mesh_chunk(shaped(), s, nil, &out)
	stone := block_texture(shaped(), .Stone, .Pos_Y)
	stone_quads, slab_quads := 0, 0
	for i := 0; i < len(out); i += 4 {
		if out[i].layer & LAYER_BITS == stone {stone_quads += 1} else {slab_quads += 1}
	}
	testing.expect_value(t, stone_quads, 5)
	testing.expect_value(t, slab_quads, 5) // four sides and the top: its bottom is hidden by the stone
	// Stone on a bottom slab: the stone's bottom is drawn (the slab's top is half).
	s^ = {}
	s[snapshot_index(3, 4, 5)] = bottom
	s[snapshot_index(3, 5, 5)] = .Stone
	mesh_chunk(shaped(), s, nil, &out)
	stone_quads = 0
	for i := 0; i < len(out); i += 4 {if out[i].layer & LAYER_BITS == stone {stone_quads += 1}}
	testing.expect_value(t, stone_quads, 6)
	// Stone on a top slab: hidden (the slab's top is the whole face).
	s[snapshot_index(3, 4, 5)] = top
	mesh_chunk(shaped(), s, nil, &out)
	stone_quads = 0
	for i := 0; i < len(out); i += 4 {if out[i].layer & LAYER_BITS == stone {stone_quads += 1}}
	testing.expect_value(t, stone_quads, 5)
	// Two slabs side by side hide each other's sides; a top and a bottom slab do not.
	s^ = {}
	s[snapshot_index(3, 4, 5)] = bottom
	s[snapshot_index(4, 4, 5)] = bottom
	mesh_chunk(shaped(), s, nil, &out, merge = false)
	testing.expect_value(t, len(out) / 4, 2 * 5) // each: 3 sides, the bottom and the interior top
	s^ = {}
	s[snapshot_index(3, 4, 5)] = bottom
	s[snapshot_index(4, 4, 5)] = top
	mesh_chunk(shaped(), s, nil, &out, merge = false)
	testing.expect_value(t, len(out) / 4, 2 * 6)
}

@(test)
test_stair_faces :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	s[snapshot_index(3, 4, 5)] = state("shapes:stairs[facing=north,half=bottom]")
	mesh_chunk(shaped(), s, nil, &out, merge = false)
	testing.expect_value(t, len(out) / 4, 12) // two boxes, six faces each: all drawn (all inside or on the boundary, nothing around)
	// The riser: the upper box's +z face at z = 8, the step: the lower's top at y = 8.
	risers, steps := 0, 0
	for i := 0; i < len(out); i += 4 {
		q := out[i:][:4]
		p := vertex_position(q[0])
		if vertex_face(q[0]) == .Pos_Z && p.z == 5 * 16 + 8 {risers += 1}
		if vertex_face(q[0]) == .Pos_Y && p.y == 4 * 16 + 8 {steps += 1}
	}
	testing.expect_value(t, risers, 1)
	testing.expect_value(t, steps, 1)
}

@(test)
test_ladder_against_a_wall :: proc(t: ^testing.T) {
	s := new(Snapshot)
	defer free(s)
	out: [dynamic]Vertex
	defer delete(out)
	s[snapshot_index(3, 4, 5)] = state("shapes:lad[facing=north]")
	s[snapshot_index(3, 4, 6)] = .Stone
	grouped := mesh_chunk(shaped(), s, nil, &out, merge = false)
	testing.expect_value(t, counts_layer(grouped, .Cutout) / 4, 5) // the board's back is against the wall
	testing.expect_value(t, counts_layer(grouped, .Opaque) / 4, 6) // the stone: a ladder (cutout) hides nothing
}
