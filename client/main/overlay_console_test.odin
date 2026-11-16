package main

import "core:strings"
import "core:testing"

import "client:console"
import "client:engine"
import "client:platform"
import "client:testkit"
import "common:game"

@(private = "file")
last_line :: proc(c: ^engine.Console) -> string {
	if c.count == 0 {return ""}
	return c.lines[(c.first + c.count - 1) % engine.CONSOLE_MAX_LINES].text
}

sent :: proc(f: ^Overlay_Fixture) -> (commands: [dynamic]string) {
	commands = make([dynamic]string, context.temp_allocator)
	packets := make([dynamic]game.Packet, context.temp_allocator)
	server := game.Endpoint{&f.pipe, .Server}
	game.receive(server, &packets)
	for p in packets {
		defer game.packet_free(server, p)
		if m, ok := game.decode_client(p, testkit.test_reg()); ok {
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
	console.console_init(&f.app.console)
	defer console.console_destroy(&f.app.console)
	console.register_builtin_commands(&f.app.console)
	append(&f.s.commands, strings.clone("give"))
	defer {for c in f.s.commands {delete(c)}; delete(f.s.commands)}
	sent(&f)

	console.console_execute(f.app, "/give a stone 5")
	console.console_execute(f.app, "  /tp ~ ~5 ~ ")
	got := sent(&f)
	testing.expect_value(t, len(got), 2)
	if len(got) == 2 {
		testing.expect_value(t, got[0], "give a stone 5")
		testing.expect_value(t, got[1], "tp ~ ~5 ~")
	}
	// Plain words: no command goes to the server.
	console.console_execute(f.app, "give a stone")
	testing.expect_value(t, len(sent(&f)), 0)
	testing.expect(
		t,
		strings.contains(last_line(&f.app.console), "server command"),
		last_line(&f.app.console),
	)
	console.console_execute(f.app, "nonsense")
	testing.expect(t, strings.contains(last_line(&f.app.console), "unknown command"))
	// The old escape hatch and the client-side tp are gone.
	for name in ([]string{"server", "tp", "wear"}) {
		for cmd in f.app.console.commands {testing.expectf(t, cmd.name != name, "the client still has %s", name)}
	}
	// Without a world, a slash command is explained.
	f.s.state = .Connecting
	console.console_execute(f.app, "/seed")
	testing.expect(t, strings.contains(last_line(&f.app.console), "need a world"))
	f.s.state = .Playing
	free_all(context.temp_allocator)
}

// `key <key> down|up` (development builds, as `pad`) puts the key's press or release
// among the frame's events, as the keyboard would (a script holds P for the player list
// with it); a key there is none of, or a word that is neither, says so and adds nothing.
@(test)
test_console_key_holds_a_key :: proc(t: ^testing.T) {
	app := new(engine.App)
	defer free(app)
	defer delete(app.injected)
	_, ok := console.key_inject(app, {"p", "down"})
	testing.expect(t, ok)
	_, ok = console.key_inject(app, {"F3", "up"})
	testing.expect(t, ok)
	testing.expect_value(t, len(app.injected), 2)
	if len(app.injected) == 2 {
		first, _ := app.injected[0].(platform.Key_Event)
		second, _ := app.injected[1].(platform.Key_Event)
		testing.expect_value(t, first, platform.Key_Event{key = .P, symbol = .P, pressed = true})
		testing.expect_value(t, second, platform.Key_Event{key = .F3, symbol = .F3})
	}
	message: string
	message, ok = console.key_inject(app, {"nonesuch", "down"})
	testing.expect(t, !ok && strings.contains(message, "no such key"))
	message, ok = console.key_inject(app, {"p", "sideways"})
	testing.expect(t, !ok && strings.contains(message, "down or up"))
	testing.expect_value(t, len(app.injected), 2)
}
