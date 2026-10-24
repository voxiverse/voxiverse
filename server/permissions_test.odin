package server

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "../game"

// Roles resolve nearest first: a player's own grants, then their roles and
// default, then what those inherit; metadata likewise.
@(test)
test_permissions_resolve :: proc(t: ^testing.T) {
	p: Permissions
	defer permissions_destroy(&p)
	permissions_parse(&p, DEFAULT_PERMISSIONS)
	append(&player_perms(&p, "mo").roles, strings.clone("mod"))
	append(&player_perms(&p, "grump").grants, strings.clone("-world.edit"))
	meta_set(&player_perms(&p, "grump").meta, "prefix", "&7Grump")
	grants :: proc(p: ^Permissions, name: string, owner := false) -> []game.Grant {
		out := make([dynamic]game.Grant, context.temp_allocator)
		resolve(p, name, owner, &out, context.temp_allocator)
		return out[:]
	}
	anyone := grants(&p, "anyone")
	testing.expect(t, game.allowed(anyone, "world.edit") && game.allowed(anyone, "chat.send"))
	testing.expect(t, !game.allowed(anyone, "moderation.kick"))
	testing.expect(t, !game.allowed(anyone, "world.edit.bulk"))
	mo := grants(&p, "mo")
	testing.expect(t, game.allowed(mo, "moderation.kick") && game.allowed(mo, "chat.delete"))
	testing.expect(t, game.allowed(mo, "world.edit"), "inherited from default")
	testing.expect(t, !game.allowed(mo, "server.stop"), "a moderator may stop the server")
	testing.expect(t, !game.allowed(grants(&p, "grump"), "world.edit"), "their own denial")
	testing.expect(t, game.allowed(grants(&p, "grump", owner = true), "server.stop"))
	testing.expect_value(t, meta_of(&p, "mo", "prefix"), "&e&lMod")
	testing.expect_value(t, meta_of(&p, "grump", "prefix"), "&7Grump")
	testing.expect_value(t, meta_of(&p, "anyone", "prefix"), "")
	// An inheritance loop ends.
	append(&role_get(&p, "default").inherits, strings.clone("admin"))
	testing.expect(t, game.allowed(grants(&p, "anyone"), "server.stop"))
	// Round trip through text.
	again: Permissions
	defer permissions_destroy(&again)
	permissions_parse(&again, permissions_text(&p))
	testing.expect_value(t, permissions_text(&again), permissions_text(&p))
}

// The owner edits roles and players with commands; the changes are saved
// with the world.
@(test)
test_permissions_commands :: proc(t: ^testing.T) {
	dir := filepath.join({"build", "test", "permissions"}, context.temp_allocator) or_else ""
	os.remove_all(dir)
	defer os.remove_all(dir)
	config := Config {
		seed         = 3,
		view_radius  = 2,
		view_height  = 1,
		workers      = 1,
		allow_cheats = true,
		save_dir     = dir,
	}
	{
		pipe: game.Pipe
		game.pipe_init(&pipe)
		defer game.pipe_destroy(&pipe)
		srv: Server
		if !testing.expect(t, start(&srv, config, {&pipe, .Server})) {return}
		c := Fake_Client {
			endpoint = {&pipe, .Client},
			scratch  = new(game.Block_Array),
		}
		defer free(c.scratch)
		defer delete(c.has)
		defer delete(c.columns)
		fake_send(&c, game.Hello{game.PROTOCOL_VERSION, "owner"})
		for command in ([]string{"role grant builder world.edit.bulk", "role inherit builder default", "role meta builder prefix &a Builder", "user role add bea builder", "user grant bea -world.explode", "role grant bad Not-A-Node"}) {
			fake_send(&c, game.Command{command})
		}
		testing.expect(
			t,
			wait_until(t, &c, proc(c: ^Fake_Client) -> bool {return len(c.notices) >= 6}),
		)
		if len(c.notices) >= 6 {
			testing.expect_value(t, c.notices[0], "role builder: done")
			testing.expect_value(t, c.notices[2], "role builder: done")
			testing.expect_value(t, c.notices[3], "user: done")
			testing.expect(t, strings.has_prefix(c.notices[5], "Usage: role"), c.notices[5])
		}
		testing.expect(t, stop(&srv))
	}
	// Saved, and read back.
	s: Server
	s.store.dir = dir
	permissions_open(&s)
	defer permissions_destroy(&s.perms)
	bea := make([dynamic]game.Grant, context.temp_allocator)
	resolve(&s.perms, "bea", false, &bea, context.temp_allocator)
	testing.expect(t, game.allowed(bea[:], "world.edit.bulk") && game.allowed(bea[:], "chat.send"))
	testing.expect(t, !game.allowed(bea[:], "world.explode"))
	testing.expect_value(t, meta_of(&s.perms, "bea", "prefix"), "&a Builder")
	testing.expect(t, "bad" not_in s.perms.roles, "a bad grant made a role")
}
