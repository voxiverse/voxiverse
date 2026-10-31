package tests

import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

import "../common/game"
import "../common/telemetry"
import "../server"
import "../server/collector"

// The collector and the uploader on their threads, over real UDP and the OS's
// clock; their logic (what is refused, what is written once) is tested in
// server/collector without any of it.

@(private = "file")
loopback :: proc(port: int) -> net.Endpoint {
	return {net.IP4_Loopback, port}
}

@(private = "file")
lake_text :: proc(dir: string) -> (text: string, files: int) {
	b := strings.builder_make(context.temp_allocator)
	walk :: proc(dir: string, b: ^strings.Builder, files: ^int) {
		infos, _ := os.read_all_directory_by_path(dir, context.temp_allocator)
		for info in infos {
			if info.type == .Directory {
				walk(info.fullpath, b, files)
			} else if strings.has_suffix(info.name, ".jsonl") {
				data, _ := os.read_entire_file_from_path(info.fullpath, context.temp_allocator)
				strings.write_string(b, string(data))
				files^ += 1
			}
		}
	}
	walk(fmt.tprintf("%s/lake", dir), &b, &files)
	return strings.to_string(b), files
}

@(private = "file")
wait_for :: proc(seconds: f64, done: proc(data: rawptr) -> bool, data: rawptr) -> bool {
	end := time.tick_add(time.tick_now(), time.Duration(seconds * f64(time.Second)))
	for time.tick_diff(time.tick_now(), end) > 0 {
		if done(data) {return true}
		time.sleep(10 * time.Millisecond)
	}
	return done(data)
}

// A log is uploaded by the thread's own passes and arrives whole.
@(test)
test_an_uploader_thread_reaches_a_collector_thread :: proc(t: ^testing.T) {
	lake := "build/tmp/smoke_upload_lake"
	logs := "build/tmp/smoke_upload_log"
	for d in ([]string{lake, logs}) {os.remove_all(d)}
	defer for d in ([]string{lake, logs}) {os.remove_all(d)}
	os.make_directory_all(logs)
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 50 {
		telemetry.write_event(
			&b,
			{
				time_ms = 1_700_000_000_000 + i64(i) * 60_000,
				tick = u32(i),
				session = 9,
				kind = .Block_Mined,
				text = telemetry.short("stone"),
			},
		)
	}
	text := strings.to_string(b)
	testing.expect(
		t,
		os.write_entire_file(fmt.tprintf("%s/2023-11-14.jsonl", logs), transmute([]u8)text) == nil,
	)
	c: collector.Collector
	if !testing.expect(t, collector.collector_start(&c, lake, 0)) {return}
	defer collector.collector_stop(&c)
	u: collector.Uploader
	collector.uploader_start(
		&u,
		logs,
		loopback(c.port),
		game.account_key_make(),
		100 * time.Millisecond,
	)
	ok := wait_for(10, proc(data: rawptr) -> bool {
			return collector.collector_stats((^collector.Collector)(data)).accepted_lines == 50
		}, &c)
	collector.uploader_stop(&u)
	testing.expect(t, ok, "the log never arrived")
	got, files := lake_text(lake)
	testing.expect_value(t, strings.count(got, "\n"), 50)
	testing.expect(t, files >= 1)
	free_all(context.temp_allocator)
}

@(private = "file")
play_a_little :: proc(t: ^testing.T, config: server.Config) -> bool {
	srv: server.Server
	if !testing.expect(t, server.start(&srv, config, {})) {return false}
	// (what a player's joining writes: a kind that carries no name)
	telemetry.emit(&srv.sink, {kind = .Block_Mined, text = telemetry.short("stone")})
	time.sleep(300 * time.Millisecond)
	server.stop(&srv) // the last pass: what was written goes
	return true
}

// A server that uploads: its log is in the collector's lake after it stops, with
// an anonymous pid; one that does not (no consent) sends nothing.
@(test)
test_a_server_uploads_its_log_only_when_told_to :: proc(t: ^testing.T) {
	lake := "build/tmp/smoke_server_lake"
	saves := "build/tmp/smoke_server_saves"
	quiet := "build/tmp/smoke_server_quiet"
	for d in ([]string{lake, saves, quiet}) {os.remove_all(d)}
	defer for d in ([]string{lake, saves, quiet}) {os.remove_all(d)}
	c: collector.Collector
	if !testing.expect(t, collector.collector_start(&c, lake, 0)) {return}
	defer collector.collector_stop(&c)
	config := server.Config {
		seed        = 28,
		generator   = .Classic,
		rules       = game.RULES_DEFAULTS,
		view_radius = 3,
		view_height = 2,
		workers     = 2,
		no_sheep    = true,
		save_dir    = quiet,
	}
	// No consent: no upload configured. Nothing arrives.
	if !play_a_little(t, config) {return}
	time.sleep(300 * time.Millisecond)
	stats := collector.collector_stats(&c)
	testing.expect(
		t,
		stats.accepted_batches == 0 && stats.refused == 0 && stats.forged == 0,
		"a server that was not told to upload talked to the collector",
	)
	_, files := lake_text(lake)
	testing.expect_value(t, files, 0)
	// Told to: it goes (singleplayer's own key, here a made one).
	config.save_dir = saves
	config.upload = server.Upload {
		loopback(c.port),
		game.account_key_make(),
		200 * time.Millisecond,
	}
	if !play_a_little(t, config) {return}
	time.sleep(300 * time.Millisecond)
	text, files2 := lake_text(lake)
	testing.expect(t, files2 >= 1, "nothing reached the lake")
	testing.expect(t, strings.contains(text, `"k":"block_mined"`), "the events are not there")
	testing.expect(t, strings.has_prefix(text, `{"pid":"`), "no pid")
	free_all(context.temp_allocator)
}
