package render

import "core:fmt"
import "core:math"
import vk "vendor:vulkan"

import "client:gpu"

// world_cull_check runs world_cull.comp on a fixed set of chunks seen by a
// fixed set of cameras, outside the frames, and compares what it writes
// with cull_reference's (`--check cull`, on lavapipe in CI): every command,
// the bits of the meshes in view and the statistics. It returns what
// differed (none: it passed); it allocates in the temp allocator.
world_cull_check :: proc(p: ^World_Pass, g: ^gpu.Gpu) -> (failures: [dynamic]string) {
	failures = make([dynamic]string, context.temp_allocator)
	fail :: proc(failures: ^[dynamic]string, format: string, args: ..any) {
		append(failures, fmt.tprintf(format, ..args))
	}
	CAMERA_CHUNK :: [3]i32{5, -2, 7}
	REACH :: 3 // chunks round the camera's, each way
	SIDE :: 2 * REACH + 1
	N :: SIDE * SIDE * SIDE
	records := make([]Cull_Record, N, context.temp_allocator)
	for &r, i in records {
		offset := [3]i32{i32(i % SIDE), i32(i / SIDE % SIDE), i32(i / (SIDE * SIDE))} - REACH
		r = {
			chunk        = CAMERA_CHUNK + offset,
			slot         = u32(i + 1),
			first_vertex = u32(i * 4000),
		}
		// Groups of every size, some empty, and some cutout layers empty.
		for &count, c in r.counts {
			if (i + c) % 5 == 0 || i % 7 == 3 && c >= FACE_GROUPS {continue}
			count = u32(4 * ((i * 7 + c * 3) % 9 + 1))
		}
	}
	// The records with cutout faces first, as the pass keeps them.
	cutouts := 0
	for i in 0 ..< N {
		has: u32
		for n in records[i].counts[FACE_GROUPS:] {has += n}
		if has > 0 {
			records[i], records[cutouts] = records[cutouts], records[i]
			cutouts += 1
		}
	}
	if cutouts == 0 || cutouts == N {
		fail(
			&failures,
			"%d of %d records have cutout faces: not a test of the cutout prefix",
			cutouts,
			N,
		)
		return
	}
	Case :: struct {
		eye:        [3]f32, // from the camera chunk's origin
		yaw, pitch: f32,
	}
	CASES :: [?]Case {
		{{8.3, 9.1, 7.7}, 0.31, -0.12},
		{{1.2, 14.6, 3.9}, 2.27, -0.83},
		{{12.9, 0.4, 15.1}, -1.13, 0.47},
		{{6.6, 6.2, 0.7}, 3.71, 1.21},
	}
	scene, records_buffer, commands, stats: gpu.Buffer
	defer {
		gpu.destroy_buffer(g, &scene)
		gpu.destroy_buffer(g, &records_buffer)
		gpu.destroy_buffer(g, &commands)
		gpu.destroy_buffer(g, &stats)
	}
	usage := vk.BufferUsageFlags{.STORAGE_BUFFER, .SHADER_DEVICE_ADDRESS}
	ok: bool
	words := (N + 31) / 32
	stats_size := size_of(Cull_Stats) + words * size_of(u32)
	command_count := N * CULL_LAYERS * CULL_RUNS
	scene, ok = gpu.create_buffer(g, size_of(Scene), usage, true, "cull check scene")
	if ok {records_buffer, ok = gpu.create_buffer(g, N * size_of(Cull_Record), usage, true, "cull check records")}
	if ok {commands, ok = gpu.create_buffer(g, command_count * size_of(Cull_Command), usage, true, "cull check commands")}
	if ok {stats, ok = gpu.create_buffer(g, stats_size, usage, true, "cull check stats")}
	if !ok {
		fail(&failures, "could not make its buffers")
		return
	}
	copy(([^]Cull_Record)(records_buffer.mapped)[:N], records)
	for c, case_index in CASES {
		camera := Camera {
			chunk     = CAMERA_CHUNK,
			position  = c.eye,
			view_proj = perspective_reverse_z(
				math.PI / 2.5,
				16.0 / 9,
				0.1,
			) * view_matrix(c.eye, c.yaw, c.pitch),
		}
		(^Scene)(scene.mapped)^ = Scene {
			view_proj    = camera.view_proj,
			camera       = {c.eye.x, c.eye.y, c.eye.z, 0},
			camera_chunk = {CAMERA_CHUNK.x, CAMERA_CHUNK.y, CAMERA_CHUNK.z, 0},
		}
		// Neither zero nor what it writes: every command must be written.
		for &b in commands.mapped[:commands.size] {b = 0xa5}
		for &b in stats.mapped[:stats.size] {b = 0}
		run, started := gpu.one_shot_begin(g)
		if !started {
			fail(&failures, "could not record its commands")
			return
		}
		vk.CmdBindPipeline(run.cmd, .COMPUTE, p.cull_pipeline.handle)
		push := Cull_Push {
			scene    = gpu.buffer_address(g, scene),
			records  = gpu.buffer_address(g, records_buffer),
			commands = gpu.buffer_address(g, commands),
			stats    = gpu.buffer_address(g, stats),
			count    = N,
			cutouts  = u32(cutouts),
		}
		gpu.push_constants(g, run.cmd, &push)
		vk.CmdDispatch(run.cmd, (N + CULL_GROUP - 1) / CULL_GROUP, 1, 1)
		memory_barrier(run.cmd, {.COMPUTE_SHADER}, {.SHADER_STORAGE_WRITE}, {.HOST}, {.HOST_READ})
		if !gpu.one_shot_end(g, &run) {
			fail(&failures, "its commands did not run")
			return
		}

		planes := frustum_planes(camera.view_proj)
		got := ([^]Cull_Command)(commands.mapped)
		got_bits := ([^]u32)(stats.mapped[size_of(Cull_Stats):])
		want_stats: Cull_Stats
		bits := make([]u32, words, context.temp_allocator)
		seen := 0
		for r, i in records {
			want, s, in_view := cull_reference(r, &planes, c.eye, CAMERA_CHUNK)
			want_stats.drawn += s.drawn
			want_stats.triangles += s.triangles
			want_stats.commands += s.commands
			if in_view {
				bits[i >> 5] |= 1 << u32(i & 31)
				seen += 1
			}
			for layer in 0 ..< CULL_LAYERS {
				if layer == 1 && i >= cutouts {break} 	// (it writes none: it has no cutout faces)
				for run in 0 ..< CULL_RUNS {
					w := want[layer * CULL_RUNS + run]
					at := layer * N * CULL_RUNS + i * CULL_RUNS + run
					if got[at] != w {
						fail(
							&failures,
							"camera %d, chunk %v, layer %d, run %d: wrote %v, not %v",
							case_index,
							r.chunk,
							layer,
							run,
							got[at],
							w,
						)
					}
				}
			}
		}
		for b, w in bits {
			if got_bits[w] != b {
				fail(
					&failures,
					"camera %d: in view bits %d-%d %08x, not %08x",
					case_index,
					w * 32,
					w * 32 + 31,
					got_bits[w],
					b,
				)
			}
		}
		got_stats := (^Cull_Stats)(stats.mapped)^
		if got_stats != want_stats {
			fail(&failures, "camera %d: statistics %v, not %v", case_index, got_stats, want_stats)
		}
		// The cases must cull something and keep something, or they test little.
		if seen == 0 || seen == N {
			fail(
				&failures,
				"camera %d sees %d of %d chunks: not a test of culling",
				case_index,
				seen,
				N,
			)
		}
		if len(failures) > 20 {return}
	}
	return
}
