package client

import "core:strings"
import "core:testing"

import "../common/game"

@(private = "file")
last_line :: proc(c: ^Console) -> string {
	if c.count == 0 {return ""}
	return c.lines[(c.first + c.count - 1) % CONSOLE_MAX_LINES].text
}

@(private = "file")
sent :: proc(f: ^Overlay_Fixture) -> (commands: [dynamic]string) {
	commands = make([dynamic]string, context.temp_allocator)
	packets := make([dynamic]game.Packet, context.temp_allocator)
	server := game.Endpoint{&f.pipe, .Server}
	game.receive(server, &packets)
	for p in packets {
		defer game.packet_free(server, p)
		if m, ok := game.decode_client(p); ok {
			if c, is_command := m.(game.Command);
			   is_command {append(&commands, strings.clone(c.command, context.temp_allocator))}
		}
	}
	return
}

// A slash in the console is a server command (sent as the chat sends it);
// plain words are the client's own, and a plain word that is a server
// command says to use the slash.
@(test)
test_console_slash_is_the_servers :: proc(t: ^testing.T) {
	f: Overlay_Fixture
	overlay_fixture(t, &f, false)
	defer overlay_fixture_destroy(&f)
	console_init(&f.app.console)
	defer console_destroy(&f.app.console)
	register_builtin_commands(&f.app.console)
	append(&f.s.commands, strings.clone("give"))
	defer {for c in f.s.commands {delete(c)}; delete(f.s.commands)}
	sent(&f)

	console_execute(f.app, "/give a stone 5")
	console_execute(f.app, "  /tp ~ ~5 ~ ")
	got := sent(&f)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], "give a stone 5")
		testing.expect_value(t, got[1], "tp ~ ~5 ~")
	}
	// Plain words: no command goes to the server.
	console_execute(f.app, "give a stone")
	testing.expect_value(t, len(sent(&f)), 0)
	testing.expect(
		t,
		strings.contains(last_line(&f.app.console), "server command"),
		last_line(&f.app.console),
	)
	console_execute(f.app, "nonsense")
	testing.expect(t, strings.contains(last_line(&f.app.console), "unknown command"))
	// The old escape hatch and the client-side tp are gone.
	for name in ([]string{"server", "tp", "wear"}) {
		for cmd in f.app.console.commands {testing.expectf(t, cmd.name != name, "the client still has %s", name)}
	}
	// Without a world, a slash command is explained.
	f.s.state = .Connecting
	console_execute(f.app, "/seed")
	testing.expect(t, strings.contains(last_line(&f.app.console), "need a world"))
	f.s.state = .Playing
	free_all(context.temp_allocator)
}
