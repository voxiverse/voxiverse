package client

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"
import "core:time"

import "../common/game"
import "ui"

// The loading screen (docs/plan.md M20): joining a world, or arriving in one
// through a gate, shows what is happening instead of a world building
// itself in view, until every chunk around the player is there and meshed
// (as wait_world waits). A bar counts them; a map of the columns around
// fills in. Cancel goes back. A failure gets its own screen: why, in plain
// words, and Back.

LOADING_SHOW_AFTER :: 0.25 // seconds: a world ready sooner just appears, without the screen
LOADING_LIMIT :: 60 * time.Second // never stuck behind it: the world shows anyway

// Loading: where the session is (Session.loading while it is on).
Loading :: struct {
	since:   time.Tick,
	arrival: bool, // through a gate (or /travel): "Arriving"
}

// loading_begin puts the loading screen up (a new session, an arrival).
loading_begin :: proc(s: ^Session, arrival: bool) {
	s.loading = Loading{time.tick_now(), arrival}
}

// loading_update takes it down once the world around is ready.
loading_update :: proc(s: ^Session) {
	l, on := s.loading.?
	if !on || s.state != .Playing {return}
	if world_near_ready(s) {
		ready, _ := world_progress(s, nil)
		log.infof(
			"session loaded near=%d seconds=%.2f",
			ready,
			time.duration_seconds(time.tick_since(l.since)),
		)
		s.loading = nil
	} else if time.tick_since(l.since) > LOADING_LIMIT {
		ready, total := world_progress(s, nil)
		log.warnf(
			"session loading gave up waiting ready=%d of %d to_mesh=%d uploads=%d busy=%d (showing the world)",
			ready,
			total,
			len(s.world.to_mesh),
			len(s.world.uploads),
			s.world.stats.mesh_jobs_busy,
		)
		s.loading = nil
	}
}

// NEAR_RADIUS: the columns around the player (each way) loading waits for.
NEAR_RADIUS :: 2

// world_near_ready: the ground around the player is here. Loading waits for
// this, not for the whole interest area (the far chunks arrive and mesh with
// the game running).
world_near_ready :: proc(s: ^Session) -> bool {
	f := s.prediction.state.position
	centre := game.chunk_of({i32(math.floor(f.x)), i32(math.floor(f.y)), i32(math.floor(f.z))})
	return world_near_ready_at(
		&s.world,
		centre,
		i32(s.welcome.view_radius),
		i32(s.welcome.view_height),
	)
}

// world_near_ready_at: for each column within NEAR_RADIUS of centre in the
// interest area (radius, height): known, and every chunk from one above
// centre down to one below it, or to its lowest ground if that is lower
// (never below the interest area or the world), here and meshed (or empty,
// or with a neighbour missing that keeps it from meshing).
world_near_ready_at :: proc(w: ^World, centre: game.Chunk_Pos, radius, height: i32) -> bool {
	for dz in i32(-NEAR_RADIUS) ..= NEAR_RADIUS {
		for dx in i32(-NEAR_RADIUS) ..= NEAR_RADIUS {
			if !game.in_interest({dx, 0, dz}, radius, height) {continue}
			x, z := centre.x + dx, centre.z + dz
			if !game.in_world({x, centre.y, z}) {continue}
			column, known := w.columns[{x, z}]
			if !known {return false}
			lowest := column.heights[0]
			for h in column.heights {lowest = min(lowest, h)}
			lo := min(centre.y - 1, lowest >> game.CHUNK_SHIFT)
			lo = max(lo, centre.y - height, game.CHUNK_MIN_Y)
			for y in lo ..= centre.y + 1 {
				p := game.Chunk_Pos{x, y, z}
				if !game.in_world(p) {continue}
				c := world_get(w, p)
				if c == nil || c.queued || c.waiting {return false}
				if c.dirty && neighbours_present(w, p) {return false}
			}
		}
	}
	return true
}

// world_settled: in a world whose interest area has arrived and been meshed.
world_settled :: proc(app: ^App) -> bool {
	s := app.session
	if s == nil || s.state != .Playing {return false}
	ready, total := world_progress(s, nil)
	return ready == total && world_meshing_done(&s.world)
}

world_meshing_done :: proc(w: ^World) -> bool {
	return len(w.to_mesh) == 0 && len(w.uploads) == 0 && w.stats.mesh_jobs_busy == 0
}

// world_progress counts the chunks of the interest area around the player
// (around the feet, as the server streams them) that are here;
// columns (if given, (2r+1)^2 of them, x fastest) gets each column's share.
world_progress :: proc(s: ^Session, columns: []f32) -> (ready, total: int) {
	r, h := i32(s.welcome.view_radius), i32(s.welcome.view_height)
	w := &s.world
	f := s.prediction.state.position
	centre := game.chunk_of({i32(math.floor(f.x)), i32(math.floor(f.y)), i32(math.floor(f.z))})
	side := 2 * r + 1
	for z in -r ..= r {
		for x in -r ..= r {
			column_ready, column_total := 0, 0
			for y in -h ..= h {
				p := centre + {x, y, z}
				if !game.in_interest({x, y, z}, r, h) || !game.in_world(p) {continue}
				column_total += 1
				// (Here is enough: one on the area's edge never meshes, its
				// neighbours beyond never come; the queues tell meshing.)
				if world_get(w, p) != nil {column_ready += 1}
			}
			ready += column_ready
			total += column_total
			if len(columns) == int(side * side) {
				i := (z + r) * side + (x + r)
				columns[i] = f32(column_ready) / f32(column_total) if column_total > 0 else -1
			}
		}
	}
	return
}

// loading_screen: what is happening, the bar, the map, Cancel.
loading_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "loading")
	defer ui.pop_id(ctx)
	s := app.session
	t := &ctx.theme
	starfield_update(&app.stars, app.last_frame_ms / 1000, app.settings.reduce_motion)
	starfield_draw(ctx, &app.stars, app.settings.reduce_motion)
	// A world that is ready within a moment just appears: only the stars till then.
	if l, on := s.loading.?;
	   on && time.duration_seconds(time.tick_since(l.since)) < LOADING_SHOW_AFTER {
		return
	}

	words := "Loading the world"
	switch {
	case s.state == .Connecting:
		words = "Starting the world" if session_hosting(s) else "Connecting to the server"
	case s.loading.?.arrival:
		words = "Arriving"
	}
	r := i32(s.welcome.view_radius)
	side := 2 * r + 1
	columns := make([]f32, side * side, context.temp_allocator)
	ready, total := 0, 1
	if s.state == .Playing {ready, total = world_progress(s, columns)}

	MAP_CELL :: 6
	map_size := f32(side) * MAP_CELL if s.state == .Playing else 0
	column := ui.rect_center(ctx.screen, 420, map_size + 3 * t.row_height + 4 * t.spacing + 40)
	ui.label(ctx, words, ui.cut_top(&column, t.row_height), .Center)
	ui.cut_top(&column, t.spacing)
	// The bar: whole pixels, filled as chunks are ready.
	bar := ui.rect_center(ui.cut_top(&column, 12), 300, 12)
	ui.stroke_rect(ctx, bar, 1, t.border)
	fill := math.floor((bar.w - 4) * f32(ready) / f32(max(total, 1)))
	ui.fill_rect(ctx, {bar.x + 2, bar.y + 2, fill, bar.h - 4}, t.text)
	ui.cut_top(&column, 2 * t.spacing)
	if s.state == .Playing {
		// The map: a square per column around, by how much of it is ready.
		m := ui.rect_center(ui.cut_top(&column, map_size), map_size, map_size)
		for share, i in columns {
			if share < 0 {continue}
			cell := ui.Rect {
				m.x + f32(i32(i) % side) * MAP_CELL,
				m.y + f32(i32(i) / side) * MAP_CELL,
				MAP_CELL - 1,
				MAP_CELL - 1,
			}
			grey := u8(40 + 215 * share) if share < 1 else 255
			ui.fill_rect(ctx, cell, {grey, grey, grey, 255 if share >= 1 else 200})
		}
		ui.cut_top(&column, t.spacing)
	}
	ui.label(
		ctx,
		fmt.tprintf("%d%%", 100 * ready / max(total, 1)) if s.state == .Playing else "",
		ui.cut_top(&column, t.row_height),
		.Center,
		t.text_muted,
	)
	ui.cut_top(&column, t.spacing)
	ui.default_focus(ctx)
	if ui.button(
		ctx,
		"Cancel",
		ui.rect_center(ui.cut_top(&column, t.row_height), 200, t.row_height),
	) {
		leave_world(app)
	}
}

// failed_screen: why the game ended, and the way back.
failed_screen :: proc(app: ^App, ctx: ^ui.Context) {
	ui.push_id(ctx, "failed")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	column := ui.rect_center(ctx.screen, 560, 3 * t.row_height + 120)
	ui.title(ctx, app.failed.title, ui.cut_top(&column, 80))
	ui.label(ctx, app.failed.reason, ui.cut_top(&column, t.row_height), .Center, t.text_muted)
	ui.cut_top(&column, 2 * t.row_height)
	back := "Back to Multiplayer" if app.failed.back == .Multiplayer else "Back to Title Screen"
	if ui.button(ctx, back, ui.rect_center(ui.cut_top(&column, t.row_height), 300, t.row_height)) {
		failed_back(app)
	}
}

// sentence: a reason as a sentence of its own (capital, full stop),
// allocated.
sentence :: proc(reason: string) -> string {
	if reason == "" {return strings.clone("No reason was given.")}
	s := strings.concatenate(
		{strings.to_upper(reason[:1], context.temp_allocator), reason[1:]},
		context.temp_allocator,
	)
	if !strings.has_suffix(s, ".") {s = strings.concatenate({s, "."}, context.temp_allocator)}
	return strings.clone(s)
}

// Failed: the failure screen's words, and where Back goes.
Failed :: struct {
	title:  string,
	reason: string, // (allocated)
	back:   Screen,
}

failed_back :: proc(app: ^App) {
	delete(app.failed.reason)
	back := app.failed.back
	app.failed = {}
	if back == .Multiplayer {multiplayer_open(app)} else {app.screen = .Title}
}
