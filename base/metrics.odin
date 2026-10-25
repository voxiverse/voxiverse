package base

import "core:slice"
import "core:sync"
import "core:time"

// Metrics: named measurements a benchmark reports (PLAN.md, M19), in every
// build. Each is a ring of samples (ms, or a count) written from any thread:
// an atomic index, no lock. Recording happens only between metrics_start
// and metrics_stop (a benchmark's measured part), so outside one a metric
// costs a load and a branch:
//
//	base.metric_scope(.Mesh_Chunk) // times the rest of the block
//	base.metric_add(.Triangles, f32(n))

Metric :: enum u8 {
	// The client, a frame at a time.
	Frame, // wall clock, ms
	Frame_Record, // recording the frame's commands, ms
	Frame_Session, // the session's update (messages, prediction, meshing jobs started), ms
	Triangles, // drawn, thousands
	Draws, // chunk meshes drawn
	// The GPU's passes (gpu timing sections), ms.
	Gpu_Frame,
	Gpu_World,
	Gpu_Water,
	Gpu_Sky,
	Gpu_Entities,
	Gpu_UI,
	// Work on the pools, per job, ms.
	Generate_Chunk,
	Column_Tops,
	Light_Chunk, // a chunk's light (game.light_chunk)
	Mesh_Faces, // its faces (the snapshot and mesh.mesh_chunk)
	Mesh_Chunk, // both: a meshing job
	// The server, a tick at a time, ms.
	Server_Tick,
	Server_Stream,
	Server_Collect,
	// One value per run.
	Load_Seconds, // joining to the world loaded and meshed, s
}

Metric_Info :: struct {
	name: string, // in result files
	unit: string,
}

@(rodata)
METRIC_INFO := [Metric]Metric_Info {
	.Frame          = {"frame", "ms"},
	.Frame_Record   = {"frame_record", "ms"},
	.Frame_Session  = {"frame_session", "ms"},
	.Triangles      = {"triangles", "k"},
	.Draws          = {"draws", "meshes"},
	.Gpu_Frame      = {"gpu_frame", "ms"},
	.Gpu_World      = {"gpu_world", "ms"},
	.Gpu_Water      = {"gpu_water", "ms"},
	.Gpu_Sky        = {"gpu_sky", "ms"},
	.Gpu_Entities   = {"gpu_entities", "ms"},
	.Gpu_UI         = {"gpu_ui", "ms"},
	.Generate_Chunk = {"generate_chunk", "ms"},
	.Column_Tops    = {"column_tops", "ms"},
	.Light_Chunk    = {"light_chunk", "ms"},
	.Mesh_Faces     = {"mesh_faces", "ms"},
	.Mesh_Chunk     = {"mesh_chunk", "ms"},
	.Server_Tick    = {"server_tick", "ms"},
	.Server_Stream  = {"server_stream", "ms"},
	.Server_Collect = {"server_collect", "ms"},
	.Load_Seconds   = {"load", "s"},
}

METRIC_SAMPLES :: 1 << 16 // kept per metric (the newest, if more come)

@(private = "file")
Metric_Ring :: struct {
	count:   int, // samples ever added (atomic)
	samples: [METRIC_SAMPLES]f32,
}

@(private = "file")
metrics: [Metric]Metric_Ring
@(private = "file")
recording: bool // (atomic)

// metrics_start empties every metric and starts recording.
metrics_start :: proc() {
	for &m in metrics {sync.atomic_store(&m.count, 0)}
	sync.atomic_store(&recording, true)
}

// metrics_stop stops recording (metrics_resume goes on, keeping what was
// recorded).
metrics_stop :: proc() {
	sync.atomic_store(&recording, false)
}

metrics_resume :: proc() {
	sync.atomic_store(&recording, true)
}

metrics_recording :: proc() -> bool {
	return sync.atomic_load(&recording)
}

metric_add :: proc "contextless" (m: Metric, value: f32) {
	if !sync.atomic_load(&recording) {return}
	ring := &metrics[m]
	i := sync.atomic_add(&ring.count, 1)
	ring.samples[i % METRIC_SAMPLES] = value
}

// metric_scope times the rest of the enclosing block into m (ms).
@(deferred_out = metric_scope_end)
metric_scope :: proc "contextless" (m: Metric) -> (Metric, time.Tick) {
	return m, time.tick_now()
}

@(private)
metric_scope_end :: proc "contextless" (m: Metric, start: time.Tick) {
	if !sync.atomic_load(&recording) {return}
	metric_add(m, f32(time.duration_milliseconds(time.tick_since(start))))
}

Metric_Summary :: struct {
	count:                       int,
	mean, median, p10, p90, p99: f64,
}

// metric_summary: m's samples so far (call once recording has stopped).
metric_summary :: proc(m: Metric) -> (s: Metric_Summary) {
	ring := &metrics[m]
	n := min(sync.atomic_load(&ring.count), METRIC_SAMPLES)
	if n == 0 {return}
	sorted := make([]f32, n, context.temp_allocator)
	copy(sorted, ring.samples[:n])
	slice.sort(sorted)
	sum: f64
	for v in sorted {sum += f64(v)}
	at :: proc(sorted: []f32, q: f64) -> f64 {return f64(
			sorted[min(len(sorted) - 1, int(q * f64(len(sorted))))],
		)}
	return {
		count = sync.atomic_load(&ring.count),
		mean = sum / f64(n),
		median = at(sorted, 0.5),
		p10 = at(sorted, 0.1),
		p90 = at(sorted, 0.9),
		p99 = at(sorted, 0.99),
	}
}
