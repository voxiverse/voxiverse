package mesh

import "../../game"

// Chunk meshing: visible block faces with per-vertex ambient occlusion, from
// an immutable padded snapshot (the chunk plus a 1-block border from its 26
// neighbours), so it runs on worker threads while the world changes.
//
// Vertices are 8 bytes: chunk-local position (0..16), face, AO level and
// texture layer. Texture coordinates follow from position and face in the
// shader. Every quad is 4 vertices drawn with the shared index pattern
// 0 1 2 0 2 3; quads whose AO is brighter along the 1-3 diagonal are rotated
// so it splits them along that diagonal instead (avoids AO's classic
// diamond artifact).

PADDED :: game.CHUNK_SIZE + 2
PADDED_VOLUME :: PADDED * PADDED * PADDED

// Snapshot holds blocks at local positions -1..16 on each axis.
Snapshot :: [PADDED_VOLUME]game.Block

Vertex :: struct {
	// x | y << 5 | z << 10 | face << 15 | ao << 18 (ao: 0 darkest .. 3 open)
	packed: u32,
	layer:  u32, // texture array layer
}

Face :: enum u8 {
	Pos_X,
	Neg_X,
	Pos_Y,
	Neg_Y,
	Pos_Z,
	Neg_Z,
}

// snapshot_index of a local position, each axis in -1..16.
snapshot_index :: #force_inline proc(x, y, z: i32) -> int {
	return int(x + 1) + int(z + 1) * PADDED + int(y + 1) * PADDED * PADDED
}

// Neighbourhood lists the chunk and its 26 neighbours, by offset:
// n[(dx + 1) + (dy + 1) * 3 + (dz + 1) * 9].
Neighbourhood :: [27]^game.Chunk_Blocks

neighbour_index :: #force_inline proc(d: [3]i32) -> int {
	return int(d.x + 1) + int(d.y + 1) * 3 + int(d.z + 1) * 9
}

// snapshot_fill copies the chunk at the centre of n and its border.
snapshot_fill :: proc(s: ^Snapshot, n: ^Neighbourhood) {
	for y in i32(-1) ..= game.CHUNK_SIZE {
		cy := (y + game.CHUNK_SIZE) / game.CHUNK_SIZE - 1 // -1, 0 or 1
		for z in i32(-1) ..= game.CHUNK_SIZE {
			cz := (z + game.CHUNK_SIZE) / game.CHUNK_SIZE - 1
			for x in i32(-1) ..= game.CHUNK_SIZE {
				cx := (x + game.CHUNK_SIZE) / game.CHUNK_SIZE - 1
				c := n[neighbour_index({cx, cy, cz})]
				s[snapshot_index(x, y, z)] = game.chunk_get(c, game.local_of({x, y, z}))
			}
		}
	}
}

// Per face: the normal and two in-plane axes u, v with u × v = normal, so
// corners (0,0) (1,0) (1,1) (0,1) wind counter-clockwise seen from outside.
@(private = "file")
Face_Axes :: struct {
	normal, u, v: [3]i32,
}

@(private = "file", rodata)
FACE_AXES := [Face]Face_Axes {
	.Pos_X = {{1, 0, 0}, {0, 1, 0}, {0, 0, 1}},
	.Neg_X = {{-1, 0, 0}, {0, 0, 1}, {0, 1, 0}},
	.Pos_Y = {{0, 1, 0}, {0, 0, 1}, {1, 0, 0}},
	.Neg_Y = {{0, -1, 0}, {1, 0, 0}, {0, 0, 1}},
	.Pos_Z = {{0, 0, 1}, {1, 0, 0}, {0, 1, 0}},
	.Neg_Z = {{0, 0, -1}, {0, 1, 0}, {1, 0, 0}},
}

@(private = "file", rodata)
CORNERS := [4][2]i32{{0, 0}, {1, 0}, {1, 1}, {0, 1}}

// mesh_chunk appends the snapshot's visible faces to out (cleared first).
mesh_chunk :: proc(s: ^Snapshot, out: ^[dynamic]Vertex) {
	clear(out)
	for y in i32(0) ..< game.CHUNK_SIZE {
		for z in i32(0) ..< game.CHUNK_SIZE {
			for x in i32(0) ..< game.CHUNK_SIZE {
				b := s[snapshot_index(x, y, z)]
				if !game.block_solid(b) {continue}
				for axes, face in FACE_AXES {
					front := [3]i32{x, y, z} + axes.normal
					if game.block_solid(s[snapshot_index(front.x, front.y, front.z)]) {continue}
					emit_face(s, out, {x, y, z}, face, axes, block_texture(b, face))
				}
			}
		}
	}
}

@(private = "file")
emit_face :: proc(
	s: ^Snapshot,
	out: ^[dynamic]Vertex,
	p: [3]i32,
	face: Face,
	axes: Face_Axes,
	layer: u32,
) {
	solid :: #force_inline proc(s: ^Snapshot, p: [3]i32) -> int {
		return 1 if game.block_solid(s[snapshot_index(p.x, p.y, p.z)]) else 0
	}
	front := p + axes.normal
	// The face's plane: the far side of the block for positive normals.
	base := p + {max(axes.normal.x, 0), max(axes.normal.y, 0), max(axes.normal.z, 0)}
	quad: [4]Vertex
	ao: [4]u32
	for corner, i in CORNERS {
		du := axes.u if corner[0] == 1 else -axes.u
		dv := axes.v if corner[1] == 1 else -axes.v
		side1, side2 := solid(s, front + du), solid(s, front + dv)
		level := 0 if side1 == 1 && side2 == 1 else 3 - side1 - side2 - solid(s, front + du + dv)
		ao[i] = u32(level)
		v := base + corner[0] * axes.u + corner[1] * axes.v
		quad[i] = {
			packed = u32(
				v.x,
			) | u32(v.y) << 5 | u32(v.z) << 10 | u32(face) << 15 | u32(level) << 18,
			layer  = layer,
		}
	}
	if ao[0] + ao[2] < ao[1] + ao[3] {
		// Split along 1-3: start the quad at corner 1 (same winding).
		quad = {quad[1], quad[2], quad[3], quad[0]}
	}
	append(out, ..quad[:])
}

// Vertex fields, for tests and debugging (the shader unpacks the same way).
vertex_position :: proc(v: Vertex) -> [3]i32 {
	return {i32(v.packed & 31), i32(v.packed >> 5 & 31), i32(v.packed >> 10 & 31)}
}

vertex_face :: proc(v: Vertex) -> Face {
	return Face(v.packed >> 15 & 7)
}

vertex_ao :: proc(v: Vertex) -> u32 {
	return v.packed >> 18 & 3
}
