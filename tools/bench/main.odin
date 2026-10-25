package bench

import "core:flags"
import "core:fmt"
import "core:os"

import "../../base"
import "../../client/mesh"
import "../../game"
import "../../worldgen"

// The `chunks` benchmark scenario (PLAN.md, M19; `build bench chunks`):
// the chunk pipeline on one thread, without the game. An Earth world's
// chunks are generated around a point (every chunk from the bedrock to the
// sky), then each one the client would mesh is lit and meshed as the client
// does (game.light_chunk, then mesh.snapshot_fill and mesh.mesh_chunk), each
// stage a metric (base/metrics.odin), the whole done -repetitions times from
// scratch. Deterministic: the same chunks, faces and vertices every time
// (the counts), so a change shows as time alone. The result goes where the
// game's scenarios' do (base/bench_result.odin). Built optimized with line
// tables, for perf (`build perf bench`).

Options :: struct {
	seed:        i64 `usage:"world seed (default 1)"`,
	radius:      int `usage:"chunk columns each way from the centre (default 3)"`,
	x:           int `usage:"the centre, x (blocks)"`,
	z:           int `usage:"the centre, z (blocks)"`,
	repetitions: int `usage:"times the whole is done from scratch (default 3)"`,
	check:       bool `usage:"fail unless the counts are CHECK's and every stage's mean is within its budget (CI)"`,
}

// The default region is the scenario `chunks`; any other is `chunks-custom`
// (its results never compare with the default's).
SCENARIO_VERSION :: 1

// CHECK: what the default region (seed 1, radius 3, centre 0 0) gives.
// The counts are exact on every platform (worldgen's golden hashes; the
// mesher is integer work): a change to them is a change to generation or
// meshing, so update them knowingly. The budgets are mean ms per call,
// several times a fast desktop's, to catch real regressions on slow CI
// machines without flaking.
Check :: struct {
	chunks, meshed, vertices: int,
	budget_ms:                [4]Check_Budget,
}

Check_Budget :: struct {
	metric: base.Metric,
	ms:     f64,
}

@(rodata)
CHECK := Check {
	chunks    = 2592,
	meshed    = 844,
	vertices  = 786488, // greedy meshing (906448 without)
	budget_ms = {
		{.Generate_Chunk, 1.5},
		{.Column_Tops, 1.5},
		{.Light_Chunk, 1.0},
		{.Mesh_Faces, 1.1},
	},
}

STAGES :: [4]base.Metric{.Generate_Chunk, .Column_Tops, .Light_Chunk, .Mesh_Faces}

Counts :: struct {
	chunks, uniform, meshed, skipped, vertices: int,
	layers:                                     [mesh.Layer]int,
}

main :: proc() {
	opts := Options {
		seed        = 1,
		radius      = 3,
		repetitions = 3,
	}
	flags.parse_or_exit(&opts, os.args, .Odin)
	default_region := opts.seed == 1 && opts.radius == 3 && opts.x == 0 && opts.z == 0
	if opts.check && !default_region {
		fmt.eprintln("bench: -check is for the default region (no -seed, -radius, -x, -z)")
		os.exit(2)
	}
	result := base.Bench_Result {
		scenario = "chunks" if default_region else "chunks-custom",
		version  = SCENARIO_VERSION,
	}
	counts: Counts
	failures := make([dynamic]string, context.temp_allocator)
	for rep in 0 ..< max(opts.repetitions, 1) {
		c := run(opts)
		if rep ==
		   0 {counts = c} else if c != counts {append(&failures, "the counts differed between repetitions")}
		base.bench_repetition_end(&result)
		free_all(context.temp_allocator)
	}
	append(
		&result.counts,
		base.Bench_Count{"chunks", counts.chunks},
		base.Bench_Count{"meshed", counts.meshed},
		base.Bench_Count{"vertices", counts.vertices},
	)
	if !default_region {
		append(
			&result.counts,
			base.Bench_Count{"seed", int(opts.seed)},
			base.Bench_Count{"radius", opts.radius},
			base.Bench_Count{"x", opts.x},
			base.Bench_Count{"z", opts.z},
		)
	}

	side := 2 * opts.radius + 1
	fmt.printfln(
		"seed %d, %dx%d columns around (%d, %d): %d chunks generated (%d uniform); %d meshed, %d skipped; %d repetitions",
		opts.seed,
		side,
		side,
		opts.x,
		opts.z,
		counts.chunks,
		counts.uniform,
		counts.meshed,
		counts.skipped,
		len(result.repetitions),
	)
	m := f64(max(counts.meshed, 1))
	fmt.printfln(
		"vertices per meshed chunk: %.0f (opaque %.0f, cutout %.0f, translucent %.0f), %.1f KiB",
		f64(counts.vertices) / m,
		f64(counts.layers[.Opaque]) / m,
		f64(counts.layers[.Cutout]) / m,
		f64(counts.layers[.Translucent]) / m,
		f64(counts.vertices * size_of(mesh.Vertex)) / m / 1024,
	)
	// (Odin pads numbers given a width with zeros: strings are padded with spaces.)
	fmt.printfln("%-16s %8s %8s %8s %8s", "stage (ms)", "calls", "mean", "median", "p99")
	for stage in STAGES {
		means, medians, p99s := make([dynamic]f64), make([dynamic]f64), make([dynamic]f64)
		defer delete(means)
		defer delete(medians)
		defer delete(p99s)
		calls := 0
		for r in result.repetitions {
			append(&means, r[stage].mean)
			append(&medians, r[stage].median)
			append(&p99s, r[stage].p99)
			calls = r[stage].count
		}
		mean := base.median_of(means[:])
		fmt.printfln(
			"%-16s %8s %8s %8s %8s",
			base.METRIC_INFO[stage].name,
			fmt.tprint(calls),
			fmt.tprintf("%.3f", mean),
			fmt.tprintf("%.3f", base.median_of(medians[:])),
			fmt.tprintf("%.3f", base.median_of(p99s[:])),
		)
		if opts.check {
			for b in CHECK.budget_ms {
				if b.metric == stage && mean > b.ms {
					append(
						&failures,
						fmt.tprintf(
							"%s %.3f ms a call, over its %.3f",
							base.METRIC_INFO[stage].name,
							mean,
							b.ms,
						),
					)
				}
			}
		}
	}
	if opts.check {
		got := [3]int{counts.chunks, counts.meshed, counts.vertices}
		want := [3]int{CHECK.chunks, CHECK.meshed, CHECK.vertices}
		if got != want {
			append(
				&failures,
				fmt.tprintf("counts (chunks, meshed, vertices) %v, not %v", got, want),
			)
		}
	}
	if path := base.bench_result_write(&result); path != "" {fmt.printfln("result %s", path)}
	base.bench_result_destroy(&result)
	for f in failures {fmt.eprintfln("bench failed: %s", f)}
	if len(failures) > 0 {os.exit(1)}
	if opts.check {fmt.println("bench check passed")}
}

// run generates the region and lights and meshes it once, recording the
// stages' metrics.
run :: proc(opts: Options) -> (counts: Counts) {
	gen := worldgen.generator_make(.Earth, opts.seed)
	r := i32(opts.radius)
	centre := [2]i32{i32(opts.x) >> game.CHUNK_SHIFT, i32(opts.z) >> game.CHUNK_SHIFT}
	base.metrics_start()

	// Generate (a border of one more column all round: meshing needs its
	// neighbours).
	cache := new(worldgen.Column_Cache) // as each server worker has
	defer free(cache)
	chunks := make(map[game.Chunk_Pos]game.Chunk_Blocks)
	defer {
		for _, c in chunks {if c.array != nil {free(c.array)}}
		delete(chunks)
	}
	tops := make(map[[2]i32]worldgen.Tops)
	defer delete(tops)
	for cz in centre.y - r - 1 ..= centre.y + r + 1 {
		for cx in centre.x - r - 1 ..= centre.x + r + 1 {
			t: worldgen.Tops
			{
				base.metric_scope(.Column_Tops)
				worldgen.column_tops(&gen, {cx, cz}, &t)
			}
			tops[{cx, cz}] = t
			for cy in i32(game.CHUNK_MIN_Y) ..< game.CHUNK_MAX_Y {
				array := new(game.Block_Array)
				u: game.Block
				is_uniform: bool
				{
					base.metric_scope(.Generate_Chunk)
					u, is_uniform = worldgen.generate(&gen, {cx, cy, cz}, array, cache)
				}
				counts.chunks += 1
				if is_uniform {
					free(array)
					chunks[{cx, cy, cz}] = {
						uniform = u,
					}
					counts.uniform += 1
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
	defer {
		free(light_in)
		game.light_scratch_destroy(scratch)
		free(scratch)
		free(light)
		free(snapshot)
	}
	vertices: [dynamic]mesh.Vertex
	defer delete(vertices)
	for cz in centre.y - r ..= centre.y + r {
		for cx in centre.x - r ..= centre.x + r {
			for cy in i32(game.CHUNK_MIN_Y) ..< game.CHUNK_MAX_Y {
				pos := game.Chunk_Pos{cx, cy, cz}
				if trivially_empty(chunks, pos) {
					counts.skipped += 1
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
				{
					base.metric_scope(.Light_Chunk)
					game.light_chunk(light_in, scratch, light)
				}
				c: mesh.Counts
				{
					base.metric_scope(.Mesh_Faces)
					mesh.snapshot_fill(snapshot, &n)
					c = mesh.mesh_chunk(snapshot, light, &vertices)
				}
				for _, layer in c {
					n := mesh.counts_layer(c, layer)
					counts.layers[layer] += n
					counts.vertices += n
				}
				counts.meshed += 1
			}
		}
	}
	return
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
