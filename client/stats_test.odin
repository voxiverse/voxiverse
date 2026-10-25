package client

import "core:testing"
import "core:time"

import "../game"
import "../telemetry"
import "../ui"

// The tree of counters: groups with totals, closed until opened (open all
// the time when searching), by their dotted names.
@(test)
test_stats_tree :: proc(t: ^testing.T) {
	lines := []string {
		"blocks.mined.sand 6",
		"blocks.mined.stone 4",
		"blocks.placed.dirt 2",
		"sessions 3",
	}
	rows := stats_rows(lines, nil, false)
	// Closed: the top level, with totals.
	testing.expect_value(t, len(rows), 2)
	testing.expect(t, rows[0].path == "blocks" && rows[0].total == 12 && !rows[0].leaf)
	testing.expect(t, rows[1].path == "sessions" && rows[1].total == 3 && rows[1].leaf)
	// One group open: its children.
	expanded: map[string]bool
	expanded["blocks"] = true
	defer delete(expanded)
	rows = stats_rows(lines, expanded, false)
	paths := make([dynamic]string, context.temp_allocator)
	for r in rows {append(&paths, r.path)}
	testing.expect_value(t, len(rows), 4) // blocks, mined, placed, sessions
	testing.expect(t, rows[1].path == "blocks.mined" && rows[1].total == 10 && rows[1].depth == 1)
	// Searching: everything.
	rows = stats_rows(lines, nil, true)
	testing.expect_value(t, len(rows), 7)
	testing.expect(t, rows[2].path == "blocks.mined.sand" && rows[2].leaf && rows[2].depth == 2)
	free_all(context.temp_allocator)
}

@(test)
test_stats_numbers_by_unit :: proc(t: ^testing.T) {
	testing.expect_value(t, stats_format("distance.walked", 250), "2.5 m")
	testing.expect_value(t, stats_format("distance", 123_456_00), "123.46 km")
	testing.expect_value(t, stats_format("time.played", 59), "59s")
	testing.expect_value(t, stats_format("time.played", 125), "2m 05s")
	testing.expect_value(t, stats_format("time.played", 3 * 3600 + 7 * 60), "3h 07m")
	testing.expect_value(t, stats_format("blocks.mined", 1234567), "1,234,567")
	testing.expect_value(t, stats_format("sessions", 12), "12")
	free_all(context.temp_allocator)
}

// received: what the client sent to its server (decoded).
@(private = "file")
received :: proc(f: ^Overlay_Fixture) -> []game.Client_Message {
	out := make([dynamic]game.Client_Message, context.temp_allocator)
	packets := make([dynamic]game.Packet, context.temp_allocator)
	server := game.Endpoint{&f.pipe, .Server}
	game.receive(server, &packets)
	for p in packets {
		defer game.packet_free(server, p)
		if m, ok := game.decode_client(p); ok {append(&out, m)}
	}
	return out[:]
}

// The overlay: opening asks the server; the page it sends is shown as a
// tree; a click opens a group; a search asks again (not at once).
@(test)
test_stats_overlay :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer stats_view_destroy(&f.app.stats_view)
	defer {stats_data_clear(&f.s.player_stats); delete(f.s.player_stats.lines)}
	inventory_close(f.app)
	received(&f)
	stats_open(f.app)
	msgs := received(&f)
	testing.expect_value(t, len(msgs), 1)
	if req, is_req := msgs[0].(game.Stats_Request);
	   testing.expect(t, is_req) {testing.expect_value(t, req.filter, "")}
	stats_data_take(
		&f.s.player_stats,
		{0, 1, "blocks.mined.sand 6\nblocks.mined.stone 4\nsessions 3"},
	)
	overlay_frame(&f, {})
	th := &f.app.ui.theme
	panel := ui.rect_center(f.app.ui.screen, 560, 520)
	inner := ui.rect_shrink(panel, th.padding)
	first := ui.Vec2{inner.x + 30, inner.y + 2 * (th.row_height + th.spacing) + th.row_height / 2}
	// Click the "blocks" group: it opens.
	overlay_frame(&f, {mouse = first})
	overlay_frame(&f, {mouse = first, mouse_pressed = {.Left}, mouse_down = {.Left}})
	testing.expect(t, f.app.stats_view.expanded["blocks"], "the group did not open")
	rows := stats_rows(f.s.player_stats.lines[:], f.app.stats_view.expanded, false)
	testing.expect_value(t, len(rows), 3)
	// A search: the view asks again once the quarter second has passed.
	append(&f.app.stats_view.filter, "san")
	overlay_frame(&f, {})
	testing.expect_value(t, len(received(&f)), 0) // (too soon after the last ask)
	time.sleep(300 * time.Millisecond)
	overlay_frame(&f, {})
	msgs = received(&f)
	if len(msgs) == 1 {
		req, is_req := msgs[0].(game.Stats_Request)
		testing.expect(t, is_req && req.filter == "san", "the search was not asked for")
	} else {
		testing.expect_value(t, len(msgs), 1)
	}
	// The key closes it again (not while typing).
	free_all(context.temp_allocator)
}

// The client's reports: info on joining, how long an overlay was open; sent in a
// Telemetry_Report the server can validate.
@(test)
test_client_reports :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer reporter_destroy(&f.app.reporter)
	f.app.launched = time.tick_now()
	received(&f)
	telemetry_update(f.app) // joined: info queued
	testing.expect(
		t,
		len(f.app.reporter.queue) >= 1 && f.app.reporter.queue[0].kind == .Client_Info,
	)
	// The inventory was already open (the fixture opened it): close it.
	inventory_close(f.app)
	time.sleep(20 * time.Millisecond)
	telemetry_update(f.app)
	found := false
	for q in f.app.reporter.queue {if q.kind == .Client_Overlay {found = true}}
	testing.expect(t, found, "no overlay report")
	telemetry_send(f.s, &f.app.reporter)
	msgs := received(&f)
	report: game.Telemetry_Report
	for m in msgs {
		if r, ok := m.(game.Telemetry_Report); ok {report = r}
	}
	testing.expect(t, report.count >= 2, "the report did not arrive")
	if report.count >= 2 {
		info := telemetry.KIND_INFO[telemetry.Kind(report.entries[0].kind)]
		testing.expect(t, info.client && info.name == "client_info")
		testing.expect(t, report.entries[0].text == "linux" || report.entries[0].text != "")
	}
	testing.expect_value(t, len(f.app.reporter.queue), 0)
	free_all(context.temp_allocator)
}

// The question about sharing play data: asked once, on the title screen (not
// in scripts); each answer is kept and closes it; nothing is shared until yes.
@(test)
test_the_consent_question :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	defer reporter_destroy(&f.app.reporter)
	inventory_close(f.app)
	f.app.session = nil
	f.app.screen = .Title
	testing.expect(
		t,
		!f.app.settings.share_data && !f.app.settings.share_asked,
		"sharing starts off, unasked",
	)
	// A script does not get asked.
	f.app.scripted = true
	telemetry_update(f.app)
	testing.expect(t, !overlay_is_open(&f.app.overlays, .Consent))
	f.app.scripted = false
	telemetry_update(f.app)
	testing.expect(t, overlay_is_open(&f.app.overlays, .Consent), "not asked")
	// "Share" is the left button, "No thanks" the right.
	buttons :: proc(f: ^Overlay_Fixture) -> (share, no: ui.Vec2) {
		th := &f.app.ui.theme
		box := ui.rect_center(f.app.ui.screen, 520, 260)
		inner := ui.rect_shrink(box, 2 * th.padding)
		row := ui.cut_bottom(&inner, th.row_height)
		right := ui.cut_right(&row, (row.w - th.spacing) / 2)
		return {
			row.x + row.w / 2,
			row.y + row.h / 2,
		}, {right.x + right.w / 2, right.y + right.h / 2}
	}
	click :: proc(f: ^Overlay_Fixture, at: ui.Vec2) {
		overlay_frame(f, {mouse = at})
		overlay_frame(f, {mouse = at, mouse_pressed = {.Left}, mouse_down = {.Left}})
		overlay_frame(f, {mouse = at, mouse_released = {.Left}})
	}
	overlay_frame(&f, {})
	share, no := buttons(&f)
	click(&f, no)
	testing.expect(
		t,
		f.app.settings.share_asked && !f.app.settings.share_data,
		"no thanks was not kept",
	)
	testing.expect(t, !overlay_is_open(&f.app.overlays, .Consent), "the question stayed")
	// Not asked again; and a yes, when it is (the settings reset), is kept.
	f.app.reporter.asked = false
	telemetry_update(f.app)
	testing.expect(t, !overlay_is_open(&f.app.overlays, .Consent), "asked twice")
	f.app.settings.share_asked = false
	f.app.reporter.asked = false
	telemetry_update(f.app)
	overlay_frame(&f, {})
	click(&f, share)
	testing.expect(
		t,
		f.app.settings.share_data && f.app.settings.share_asked,
		"share was not kept",
	)
	free_all(context.temp_allocator)
}
