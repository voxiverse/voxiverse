package bench

import "core:flags"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:time"

import "../../client/mesh"
import "../../game"
import "../../worldgen"

// The chunk pipeline on one thread, without the game: an Earth world's
// chunks generated around a point (every chunk from the bedrock to the
// sky), then each one the client would mesh lit and meshed as the client
// does (game.light_chunk, mesh.snapshot_fill, mesh.mesh_chunk), each stage
// timed. Deterministic: the same numbers of chunks, faces and vertices on
// every run, so a change shows as time alone. Built optimized with line
// tables, for perf:
//
//	build bench -seed:1 -radius:6
//	perf record -g build/bench -radius:6 && perf report

Options :: struct {
	seed:   i64 `usage:"world seed (default 1)"`,
	radius: int `usage:"chunk columns each way from the centre (default 6)"`,
	x:      int `usage:"the centre, x (blocks)"`,
	z:      int `usage:"the centre, z (blocks)"`,
	repeat: int `usage:"light and mesh every chunk this many times (default 1)"`,
}

Stage :: enum {
	Generate,
	Tops,
	Light,
	Snapshot,
	Mesh,
}

Times :: [Stage][dynamic]f64 // ms per call

main :: proc() {
	opts := Options {
		seed   = 1,
		radius = 6,
		repeat = 1,
	}
	flags.parse_or_exit(&opts, os.args, .Odin)
	gen := worldgen.generator_make(.Earth, opts.seed)
	times: Times
	r := i32(opts.radius)
	centre := [2]i32{i32(opts.x) >> game.CHUNK_SHIFT, i32(opts.z) >> game.CHUNK_SHIFT}

	// Generate (a border of one more column all round: meshing needs its
	// neighbours).
	cache := new(worldgen.Column_Cache) // as each server worker has
	chunks := make(map[game.Chunk_Pos]game.Chunk_Blocks)
	tops := make(map[[2]i32]worldgen.Tops)
	uniform_count := 0
	for cz in centre.y - r - 1 ..= centre.y + r + 1 {
		for cx in centre.x - r - 1 ..= centre.x + r + 1 {
			t: worldgen.Tops
			start := time.tick_now()
			worldgen.column_tops(&gen, {cx, cz}, &t)
			append(&times[.Tops], ms_since(start))
			tops[{cx, cz}] = t
			for cy in i32(game.CHUNK_MIN_Y) ..< game.CHUNK_MAX_Y {
				array := new(game.Block_Array)
				start = time.tick_now()
				u, is_uniform := worldgen.generate(&gen, {cx, cy, cz}, array, cache)
				append(&times[.Generate], ms_since(start))
				if is_uniform {
					free(array)
					chunks[{cx, cy, cz}] = {
						uniform = u,
					}
					uniform_count += 1
				} else {
					chunks[{cx, cy, cz}] = {
						array = array,
					}
				}
			}
		}
	}

	// Light and mesh what the client would (it skips air, and uniform
	// chunks closed in on all six sides).
	light_in := new(game.Light_Input)
	scratch := new(game.Light_Scratch)
	light := new(mesh.Light_Snapshot)
	snapshot := new(mesh.Snapshot)
	vertices: [dynamic]mesh.Vertex
	counts: [mesh.Layer]int
	meshed, skipped := 0, 0
	for _ in 0 ..< opts.repeat {
		for cz in centre.y - r ..= centre.y + r {
			for cx in centre.x - r ..= centre.x + r {
				for cy in i32(game.CHUNK_MIN_Y) ..< game.CHUNK_MAX_Y {
					pos := game.Chunk_Pos{cx, cy, cz}
					if trivially_empty(chunks, pos) {
						skipped += 1
						continue
					}
					n: mesh.Neighbourhood
					for i in 0 ..< 27 {
						d := game.Chunk_Pos{i32(i % 3) - 1, i32(i / 3 % 3) - 1, i32(i / 9) - 1}
						n[i] = neighbour(&chunks, pos + d)
					}
					light_in.chunks = n
					light_in.origin = game.chunk_origin(pos)
					for dz in i32(-1) ..= 1 {
						for dx in i32(-1) ..= 1 {
							t := tops[{cx + dx, cz + dz}]
							for z in 0 ..< game.CHUNK_SIZE {
								for x in 0 ..< game.CHUNK_SIZE {
									rx := int(dx + 1) * game.CHUNK_SIZE + x
									rz := int(dz + 1) * game.CHUNK_SIZE + z
									light_in.heights[rx + rz * game.LIGHT_REGION] =
										t[x + z * game.CHUNK_SIZE]
								}
							}
						}
					}
					start := time.tick_now()
					game.light_chunk(light_in, scratch, light)
					append(&times[.Light], ms_since(start))
					start = time.tick_now()
					mesh.snapshot_fill(snapshot, &n)
					append(&times[.Snapshot], ms_since(start))
					start = time.tick_now()
					c := mesh.mesh_chunk(snapshot, light, &vertices)
					append(&times[.Mesh], ms_since(start))
					for k, layer in c {counts[layer] += k}
					meshed += 1
				}
			}
		}
	}

	side := 2 * opts.radius + 1
	fmt.printfln(
		"seed %d, %dx%d columns around (%d, %d): %d chunks generated (%d uniform); %d meshed, %d skipped (x%d)",
		opts.seed,
		side,
		side,
		opts.x,
		opts.z,
		len(times[.Generate]),
		uniform_count,
		meshed / opts.repeat,
		skipped / opts.repeat,
		opts.repeat,
	)
	total_vertices := counts[.Opaque] + counts[.Cutout] + counts[.Translucent]
	fmt.printfln(
		"vertices per meshed chunk: %.0f (opaque %.0f, cutout %.0f, translucent %.0f), %.1f KiB",
		f64(total_vertices) / f64(meshed),
		f64(counts[.Opaque]) / f64(meshed),
		f64(counts[.Cutout]) / f64(meshed),
		f64(counts[.Translucent]) / f64(meshed),
		f64(total_vertices * size_of(mesh.Vertex)) / f64(meshed) / 1024,
	)
	fmt.printfln(
		"%-9s %8s %10s %8s %8s %8s %8s",
		"stage",
		"calls",
		"total ms",
		"mean",
		"p50",
		"p99",
		"max",
	)
	for &t, stage in times {
		if len(t) == 0 {continue}
		total: f64
		for v in t {total += v}
		slice.sort(t[:])
		fmt.printfln(
			"%-9v %8s %10s %8s %8s %8s %8s",
			stage,
			fmt.tprint(len(t)),
			fmt.tprintf("%.1f", total),
			ms(total / f64(len(t))),
			ms(t[len(t) / 2]),
			ms(t[min(len(t) - 1, len(t) * 99 / 100)]),
			ms(t[len(t) - 1]),
		)
		// (Odin pads numbers given a width with zeros: strings are padded with spaces.)
		ms :: proc(v: f64) -> string {return fmt.tprintf("%.3f", v)}
	}
}

ms_since :: proc(start: time.Tick) -> f64 {
	return time.duration_milliseconds(time.tick_since(start))
}

AIR_CHUNK := game.Chunk_Blocks {
	uniform = .Air,
}

// neighbour: the blocks at pos (above and below the world: air).
neighbour :: proc(
	chunks: ^map[game.Chunk_Pos]game.Chunk_Blocks,
	pos: game.Chunk_Pos,
) -> ^game.Chunk_Blocks {
	if c, ok := &chunks[pos]; ok {return c}
	return &AIR_CHUNK
}

// trivially_empty: as client/world.odin decides.
trivially_empty :: proc(
	chunks: map[game.Chunk_Pos]game.Chunk_Blocks,
	pos: game.Chunk_Pos,
) -> bool {
	c := chunks[pos]
	if c.array != nil {return false}
	if c.uniform == .Air {return true}
	for d in ([6]game.Chunk_Pos{{1, 0, 0}, {-1, 0, 0}, {0, 1, 0}, {0, -1, 0}, {0, 0, 1}, {0, 0, -1}}) {
		n, ok := chunks[pos + d]
		if !ok {n = AIR_CHUNK}
		if n.array != nil || !game.block_opaque(n.uniform) {return false}
	}
	return true
}
