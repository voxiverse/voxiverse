package engine

import "common:base"
import "common:game"
import "common:worldgen"
import "core:time"

Audio_Check_Phase :: enum u8 {
	Off,
	Loading,
	Running,
}

Audio_Check :: struct {
	using check: Exit_Check,
	phase:       Audio_Check_Phase,
	started:     time.Tick,
	next:        time.Tick,
	events:      int,
	frames0:     u64,
	cb_max_ns:   u32, // the worst callback seen (each look at the stats resets it)
	shot:        u8, // the inspector's turn: 0 not yet, 1 open (waiting to draw), 2 drawn, 3 done
	shot_frames: int,
	shot_error:  string, // what went wrong with the inspector, for the verdict
}

Bench_Kind :: enum u8 {
	Load, // joining until the world around is loaded and meshed
	Views, // still views all round: the GPU's work
	Flight, // flying over the land: streaming while drawing
	Edits, // explosions round the spawn: bulk edits re-meshed, water let loose
	Audio, // the mixer alone: 64 voices on 4 buses, the reverb and a stream (no world, no GPU)
	Viewmodel, // the view model's vertices for a frame, the biggest model (no world, no GPU)
	Avatars, // other players in view: BENCH_AVATARS walking, each holding a weapon
}

Scenario :: struct {
	name:        string,
	kind:        Bench_Kind,
	version:     int, // bump when what it does changes: results of other versions never compare
	repetitions: int,
	description: string,
	view:        [2]i32, // view radius and height, chunks ({}: BENCHMARK_SETTINGS')
}

// The avatars scenario: how many, and for how long.
BENCH_AVATARS :: 8

BENCH_EDITS :: 12 // explosions, on a ring round the spawn

Bench_Phase :: enum u8 {
	Off,
	Joining, // entering the world, waiting for it to load and mesh
	Warming,
	Lifting, // (flight) up and the flying rules, waiting for the server
	Measuring,
}

Bench :: struct {
	scenario:  Scenario,
	smoke:     bool, // one short repetition (CI)
	size:      [2]u32, // drawn at (BENCH_SIZE, or --bench-size)
	phase:     Bench_Phase,
	rep:       int,
	frames:    int, // in this phase
	started:   time.Tick, // this phase's start
	view:      int,
	start_x:   f64, // (flight)
	targets:   [BENCH_EDITS]game.Block_Pos, // (edits) where the explosions go
	crowd:     [BENCH_AVATARS][3]f64, // (avatars) where each stands
	fired:     int,
	next_shot: time.Tick,
	first:     time.Tick, // the first explosion
	result:    base.Bench_Result,
	failed:    bool,
	done:      bool,
}

Blast_Test_Phase :: enum u8 {
	Off,
	Loading,
	Rising, // teleport requested; waiting to be up there, flying
	Firing,
	Settling, // the last shot is out: everything arriving, meshed
	Comparing, // asked the server for its hash
}

Blast_Test :: struct {
	using check:  Exit_Check,
	phase:        Blast_Test_Phase,
	shots:        int,
	fired:        int,
	started:      time.Tick, // of the phase
	next_shot:    time.Tick,
	tick_max:     f32, // the server's slowest tick seen while firing
	server_count: int, // the server's hash of the chunks it sent us
	server_sum:   u64,
	late_before:  int,
	shown_before: int,
}

Exit_Check :: struct {
	name:         string,
	quit:         bool,
	failed:       bool,
	frames:       base.Frame_Stats, // frame times while it measures
	client_arena: uint,
	server_arena: uint,
}

Fly_Test_Phase :: enum u8 {
	Off,
	Loading,
	Lifting, // teleport and rule change requested, waiting for the server
	Flying,
}

Fly_Test :: struct {
	using check: Exit_Check,
	phase:       Fly_Test_Phase,
	distance:    f64, // blocks to fly
	start:       [3]f64,
	waited:      f32, // seconds spent loading
	rss_start:   int,
	pad:         bool, // the synthetic gamepad flies it, not the autopilot (fly_pad)
	pad_step:    int, // the pad's script: connect, the double tap, the stick
	pad_ticks:   int, // ticks flown on the pad
}

Scene_Phase :: enum u8 {
	Off,
	Script, // its script running (the main loop's)
	Clearing, // chat lines and toasts taken down, the UI drawn without them
	Shooting, // the picture asked for, not yet written
	Done,
}

Scene_Run :: struct {
	name:    string,
	phase:   Scene_Phase,
	frames:  int, // in this phase
	counts:  Scene_Counts, // what the picture's frame drew (written beside it)
	counted: bool,
	menu:    bool, // a menu's scene: no world, its animations stand still
}

// Scene_Counts: what a scene's frame drew,
// written to images/<scene>.counts beside its picture, one `name value` a
// line, and compared with the baseline's by `build images`. Every count is
// computed from integers (the cull pass's statistics, the draw calls), so
// each must be equal.
Scene_Counts :: struct {
	world_meshes:         int,
	world_triangles:      int,
	draw_calls:           int,
	api_draw_calls:       int,
	world_api_draw_calls: int,
	frame_triangles:      int,
}

Tour_Test_Phase :: enum u8 {
	Off,
	Loading,
	Locating, // asked the server; waiting for its answer
	Arriving, // there: waiting for the land around to load and mesh
}

Tour_Test :: struct {
	using check: Exit_Check,
	phase:       Tour_Test_Phase,
	biome:       worldgen.Biome, // the one being visited
	started:     time.Tick, // of the phase
	missing:     bit_set[worldgen.Biome], // not found within reach
	measuring:   bool, // memory baseline taken (after the first biome)
}
