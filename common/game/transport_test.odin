package game

import "core:os"
import "core:testing"
import "core:time"

@(private = "file")
free_all_packets :: proc(e: Endpoint, out: ^[dynamic]Packet) {
	for p in out {packet_free(e, p)}
	clear(out)
}

@(test)
test_pipe_latency_and_order :: proc(t: ^testing.T) {
	pipe: Pipe
	pipe_init(&pipe)
	defer pipe_destroy(&pipe)
	clock: time.Tick // (the pipe's own time: the test moves it)
	pipe.clock = &clock
	pipe_seed(&pipe, 1)
	client, server := Endpoint{&pipe, .Client}, Endpoint{&pipe, .Server}
	got := make([dynamic]Packet)
	defer delete(got)
	defer free_all_packets(server, &got)

	pipe_set_conditions(&pipe, {latency_ms = 40, jitter_ms = 30})
	for i in 0 ..< 20 {send(client, []u8{u8(i)})}
	testing.expect_value(t, receive(server, &got), 0) // nothing is due yet
	clock = time.tick_add(clock, 90 * time.Millisecond)
	testing.expect_value(t, receive(server, &got), 20)
	for p, i in got {testing.expectf(t, p[0] == u8(i), "out of order at %d", i)} 	// jitter keeps order

	traffic := pipe_traffic(&pipe)
	testing.expect_value(t, traffic[.Client].messages[0] + traffic[.Client].messages[19], 2)
	testing.expect_value(t, traffic[.Server].bytes[0], 0)
}

@(test)
test_pipe_bandwidth :: proc(t: ^testing.T) {
	pipe: Pipe
	pipe_init(&pipe)
	defer pipe_destroy(&pipe)
	clock: time.Tick
	pipe.clock = &clock
	client, server := Endpoint{&pipe, .Client}, Endpoint{&pipe, .Server}
	got := make([dynamic]Packet)
	defer delete(got)
	defer free_all_packets(server, &got)

	// 5 x 1000 bytes at 50 KB/s: one every 20 ms.
	pipe_set_conditions(&pipe, {bandwidth_kbps = 50})
	big: [1000]u8
	for _ in 0 ..< 5 {send(client, big[:])}
	clock = time.tick_add(clock, 30 * time.Millisecond)
	// One every 20 ms: at 30 ms, the first only.
	testing.expect_value(t, receive(server, &got), 1)
	clock = time.tick_add(clock, 100 * time.Millisecond)
	receive(server, &got)
	testing.expect_value(t, len(got), 5)
}

@(test)
test_trace_round_trip :: proc(t: ^testing.T) {
	path := "build/test/trace_test.trace"
	os.make_directory_all("build/test")
	defer os.remove(path)
	header := Trace_Header{PROTOCOL_VERSION, -1234567890123, 12, 6, true}

	pipe: Pipe
	pipe_init(&pipe)
	client, server := Endpoint{&pipe, .Client}, Endpoint{&pipe, .Server}
	testing.expect(t, pipe_trace_start(&pipe, path, header))
	send(client, []u8{1, 2, 3})
	send(server, []u8{4})
	send(client, []u8{5, 6})
	pipe_destroy(&pipe) // closes the trace

	data, err := os.read_entire_file_from_path(path, context.allocator)
	testing.expect(t, err == nil)
	defer delete(data)
	h, records, ok := trace_read(data)
	defer delete(records)
	testing.expect(t, ok && h == header && len(records) == 3)
	if len(records) == 3 {
		testing.expect(
			t,
			records[0].sender == .Client && string(records[0].data) == "\x01\x02\x03",
		)
		testing.expect(t, records[1].sender == .Server && string(records[1].data) == "\x04")
		testing.expect(t, records[1].time >= records[0].time && records[2].time >= records[1].time)
	}

	// Cut short (a crash mid-write): the complete records survive.
	cut_header, cut, cut_ok := trace_read(data[:len(data) - 1])
	defer delete(cut)
	testing.expect(t, !cut_ok && cut_header == header && len(cut) == 2)
	// Not a trace at all.
	_, none, none_ok := trace_read(transmute([]u8)string("hello world, not a trace"))
	defer delete(none)
	testing.expect(t, !none_ok && len(none) == 0)
}
