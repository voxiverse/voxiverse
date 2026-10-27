package server

import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"

import "../common/game"
import "collector"

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
play_a_little :: proc(t: ^testing.T, config: Config) -> bool {
	srv: Server
	if !testing.expect(t, start(&srv, config, {})) {return false}
	a: Net_Client
	net_connect(&a, srv.host.socket.port, "alice")
	defer net_close(&a)
	ok := net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return landed(cs[0])})
	net_send(&a, game.Chat{"hello"})
	net_send(&a, game.Command{"time noon"})
	net_wait(t, {&a}, proc(cs: []^Net_Client) -> bool {return false}, 0.5)
	net_close(&a)
	a = {}
	time.sleep(100 * time.Millisecond)
	stop(&srv) // the last pass: what was written goes
	return ok
}

// A server that uploads: its log is in the collector's lake after it stops, with
// an anonymous pid and no name; one that does not (no consent) sends nothing.
@(test)
test_a_server_uploads_its_log_only_when_told_to :: proc(t: ^testing.T) {
	lake := "build/test/upload_lake"
	saves := "build/test/upload_saves"
	quiet := "build/test/upload_quiet"
	for d in ([]string{lake, saves, quiet}) {os.remove_all(d)}
	defer for d in ([]string{lake, saves, quiet}) {os.remove_all(d)}
	c: collector.Collector
	if !testing.expect(t, collector.collector_start(&c, lake, 0)) {return}
	defer collector.collector_stop(&c)
	config := Config {
		seed            = 28,
		generator       = .Classic,
		rules           = quiet_rules(),
		view_radius     = 3,
		view_height     = 2,
		workers         = 2,
		max_players     = 2,
		listen          = true,
		allow_cheats    = true,
		everyone_cheats = true,
		no_sheep        = true,
		save_dir        = quiet,
	}
	// No consent: no upload configured. Nothing arrives.
	testing.expect(t, play_a_little(t, config))
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
	config.upload = Upload {
		net.Endpoint{net.IP4_Address{127, 0, 0, 1}, c.port},
		game.account_key_make(),
		200 * time.Millisecond,
	}
	testing.expect(t, play_a_little(t, config))
	time.sleep(300 * time.Millisecond)
	text, files2 := lake_text(lake)
	testing.expect(t, files2 >= 1, "nothing reached the lake")
	testing.expect(
		t,
		strings.contains(text, `"k":"session_start"`) && strings.contains(text, `"k":"chat_line"`),
		"the events are not there",
	)
	testing.expect(t, strings.has_prefix(text, `{"pid":"`), "no pid")
	testing.expect(
		t,
		!strings.contains(text, "alice") && !strings.contains(text, "hello"),
		"a name or chat text got into the lake",
	)
	// The log kept on the server's own disk is still there, whole.
	_, local_err := os.stat(
		filepath.join({saves, "telemetry"}, context.temp_allocator) or_else "",
		context.temp_allocator,
	)
	testing.expect(t, local_err == nil)
	free_all(context.temp_allocator)
}
