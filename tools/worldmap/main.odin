package worldmap

import "core:flags"
import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"

import "../../base"
import "../../game"
import "../../worldgen"

// Renders a top-down map of an Earth world to a PNG, without the game:
// each pixel a block column's biome, its water shaded by depth and its
// land by slope (lit from the north-west), from the generator's climate
// alone (no caves or trees: fast).
//
//	build worldmap -seed:42 -size:4096
//	build worldmap -seed:42 -size:1024 -x:3000 -z:-800 -out:build/here.png

Options :: struct {
	seed:  i64 `usage:"world seed"`,
	size:  int `usage:"blocks across (default 4096)"`,
	scale: int `usage:"blocks per pixel (default: size / 1024, at least 1)"`,
	x:     int `usage:"the map's centre, x"`,
	z:     int `usage:"the map's centre, z"`,
	out:   string `usage:"PNG to write (default build/worldmap.png)"`,
	bench: int `usage:"instead: generate this many chunk columns around the centre (every chunk from the bedrock to the sky) and report the time each chunk took"`,
}

BIOME_COLOURS := [worldgen.Biome][3]f32 {
	.Ocean        = {40, 70, 150},
	.Frozen_Ocean = {150, 180, 215},
	.Beach        = {222, 206, 150},
	.River        = {60, 110, 190},
	.Plains       = {120, 175, 80},
	.Forest       = {50, 110, 45},
	.Taiga        = {60, 110, 90},
	.Tundra       = {225, 232, 240},
	.Desert       = {225, 195, 120},
	.Mountains    = {128, 124, 120},
}

Job :: struct {
	gen:    ^worldgen.Generator,
	opts:   ^Options,
	width:  int,
	pixels: []u8,
	next:   ^int, // the next row to draw (atomic)
	counts: [worldgen.Biome]int,
}

main :: proc() {
	opts := Options {
		seed = 1,
		size = 4096,
		out  = "build/worldmap.png",
	}
	flags.parse_or_exit(&opts, os.args, .Odin)
	if opts.scale <= 0 {opts.scale = max(1, opts.size / 1024)}
	width := opts.size / opts.scale
	if width <= 0 {
		fmt.eprintln("worldmap: -size must be at least -scale")
		os.exit(1)
	}
	gen := worldgen.generator_make(.Earth, opts.seed)
	if opts.bench > 0 {
		bench(&gen, &opts)
		return
	}
	pixels := make([]u8, width * width * 4)
	start := time.tick_now()

	next := 0
	jobs := make([]Job, max(1, os.get_processor_core_count()))
	threads := make([]^thread.Thread, len(jobs))
	for &j, i in jobs {
		j = {&gen, &opts, width, pixels, &next, {}}
		threads[i] = thread.create_and_start_with_poly_data(&j, draw_rows)
	}
	counts: [worldgen.Biome]int
	for t, i in threads {
		thread.join(t)
		thread.destroy(t)
		for n, b in jobs[i].counts {counts[b] += n}
	}
	// Structures, marked: a square of their colour (dungeons are under
	// the land, marked all the same).
	MARKS := [worldgen.Structure_Kind][3]u8 {
		.Tower   = {220, 40, 40},
		.Ruin    = {240, 140, 30},
		.Well    = {40, 220, 230},
		.Dungeon = {150, 60, 200},
	}
	structures := make([dynamic]worldgen.Structure)
	half := opts.size / 2
	worldgen.structures_near(
		&gen,
		{i32(opts.x - half), i32(opts.z - half)},
		{i32(opts.x + half), i32(opts.z + half)},
		&structures,
	)
	marked: [worldgen.Structure_Kind]int
	for st in structures {
		marked[st.kind] += 1
		cx := (int(st.lo.x + st.hi.x) / 2 - (opts.x - half)) / opts.scale
		cz := (int(st.lo.z + st.hi.z) / 2 - (opts.z - half)) / opts.scale
		for dz in -2 ..= 2 {
			for dx in -2 ..= 2 {
				px, pz := cx + dx, cz + dz
				if px < 0 || pz < 0 || px >= width || pz >= width {continue}
				i := (pz * width + px) * 4
				c := MARKS[st.kind] if abs(dx) < 2 && abs(dz) < 2 else [3]u8{0, 0, 0}
				pixels[i], pixels[i + 1], pixels[i + 2] = c.r, c.g, c.b
			}
		}
	}
	seconds := time.duration_seconds(time.tick_since(start))

	png, err := base.png_encode(width, width, pixels)
	if err != nil || os.write_entire_file(opts.out, png) != nil {
		fmt.eprintfln("worldmap: cannot write %s", opts.out)
		os.exit(1)
	}
	fmt.printfln(
		"worldmap seed %d: %d x %d blocks, %d blocks per pixel, %.1f s -> %s",
		opts.seed,
		opts.size,
		opts.size,
		opts.scale,
		seconds,
		opts.out,
	)
	for n, k in marked {
		if n > 0 {fmt.printfln("  %-13s %5d", worldgen.STRUCTURE_NAMES[k], n)}
	}
	total := width * width
	for n, b in counts {
		if n >
		   0 {fmt.printfln("  %-13s %5.1f%%", worldgen.BIOME_NAMES[b], 100 * f64(n) / f64(total))}
	}
}

draw_rows :: proc(j: ^Job) {
	o := j.opts
	p := &j.gen.params
	sea := f32(p.sea_level)
	for {
		row := sync.atomic_add(j.next, 1)
		if row >= j.width {return}
		z := i32(o.z - o.size / 2 + row * o.scale)
		for col in 0 ..< j.width {
			x := i32(o.x - o.size / 2 + col * o.scale)
			c := worldgen.column_at(p, j.gen.seed, x, z)
			j.counts[c.biome] += 1
			colour := BIOME_COLOURS[c.biome]
			if c.height < sea {
				// Deeper water darker; frozen seas stay pale.
				depth := clamp((sea - c.height) / 40, 0, 1)
				if c.biome != .Frozen_Ocean {colour = colour * (1 - 0.55 * depth)}
			} else {
				// Lit from the north-west: the slope towards it.
				west :=
					worldgen.column_at(p, j.gen.seed, x - i32(o.scale), z - i32(o.scale)).height
				slope := clamp((c.height - west) / f32(o.scale) * 0.6, -0.5, 0.5)
				colour = colour * (1 + slope) * (0.85 + 0.25 * clamp((c.height - sea) / 140, 0, 1))
				if c.height > sea + 95 {colour = {235, 238, 242}} 	// snow caps
			}
			i := (row * j.width + col) * 4
			j.pixels[i + 0] = u8(clamp(colour.r, 0, 255))
			j.pixels[i + 1] = u8(clamp(colour.g, 0, 255))
			j.pixels[i + 2] = u8(clamp(colour.b, 0, 255))
			j.pixels[i + 3] = 255
		}
	}
}

// bench generates whole chunk columns in a square around the centre, and
// their tops, on one thread, timing each chunk.
bench :: proc(gen: ^worldgen.Generator, o: ^Options) {
	side := int(math.ceil(math.sqrt(f64(o.bench))))
	times := make([dynamic]f64)
	tops_times := make([dynamic]f64)
	arr := new(game.Block_Array)
	blocks: [game.Block]int
	for i in 0 ..< side * side {
		cx := i32(o.x / game.CHUNK_SIZE + i % side - side / 2)
		cz := i32(o.z / game.CHUNK_SIZE + i / side - side / 2)
		start := time.tick_now()
		tops: worldgen.Tops
		worldgen.column_tops(gen, {cx, cz}, &tops)
		append(&tops_times, time.duration_milliseconds(time.tick_since(start)))
		for cy in i32(game.CHUNK_MIN_Y) ..< game.CHUNK_MAX_Y {
			start = time.tick_now()
			uniform, is_uniform := worldgen.generate(gen, {cx, cy, cz}, arr)
			append(&times, time.duration_milliseconds(time.tick_since(start)))
			if is_uniform {blocks[uniform] += game.CHUNK_VOLUME} else {for b in arr {blocks[b] += 1}}
		}
		free_all(context.temp_allocator)
	}
	report :: proc(name: string, t: []f64) {
		slice.sort(t)
		sum: f64
		for v in t {sum += v}
		fmt.printfln(
			"  %-6s %6d   avg %.3f ms   p50 %.3f   p99 %.3f   max %.3f",
			name,
			len(t),
			sum / f64(len(t)),
			t[len(t) / 2],
			t[len(t) * 99 / 100],
			t[len(t) - 1],
		)
	}
	fmt.printfln("worldmap bench seed %d: %d chunk columns", o.seed, side * side)
	report("chunks", times[:])
	report("tops", tops_times[:])
	total := 0
	for n in blocks {total += n}
	for n, b in blocks {
		if n > 0 &&
		   b != .Air &&
		   b != .Stone {fmt.printfln("  %-14v %8.4f%%", b, 100 * f64(n) / f64(total))}
	}
}
