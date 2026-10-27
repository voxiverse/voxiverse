package game

import "core:testing"

@(test)
test_permissions :: proc(t: ^testing.T) {
	g :: proc(text: string, rank: int) -> Grant {
		r, _ := grant_parse(text, rank)
		return r
	}
	// A moderator: everything in chat, but not formatting; kicking.
	mod := []Grant {
		g("chat.*", 1),
		g("-chat.format", 1),
		g("moderation.kick", 1),
		g("chat.send", 2),
	}
	testing.expect(t, allowed(mod, "chat.delete"))
	testing.expect(t, allowed(mod, "chat"), "chat.* covers chat itself")
	testing.expect(t, !allowed(mod, "chat.format"), "a denial, more specific")
	testing.expect(
		t,
		allowed(mod, "chat.formatting"),
		"the denial of chat.format does not reach chat.formatting",
	)
	testing.expect(t, allowed(mod, "moderation.kick"))
	testing.expect(t, !allowed(mod, "moderation.ban"), "nothing grants it")
	testing.expect(t, !allowed(mod, "chatter"))
	// The player's own grant beats their role's at the same specificity;
	// a deeper one beats a shallower whatever the source.
	own := []Grant{g("chat.format", 0), g("-chat.format", 1), g("-chat.*", 0), g("chat.msg", 1)}
	testing.expect(t, allowed(own, "chat.format"))
	testing.expect(t, allowed(own, "chat.msg"), "exact (role) over wildcard (own)")
	testing.expect(t, !allowed(own, "chat.send"))
	// Everything, but one thing.
	admin := []Grant{g("*", 1), g("-server.stop", 2)}
	testing.expect(t, allowed(admin, "world.edit.bulk") && !allowed(admin, "server.stop"))
	// Same place, same specificity: a denial wins.
	tie := []Grant{g("world.edit", 1), g("-world.edit", 1)}
	testing.expect(t, !allowed(tie, "world.edit"))
	testing.expect(t, !allowed(nil, "chat.send"))
	// Bad patterns.
	for bad in ([]string{"", "Chat", "chat..send", "chat.*.send", "chat.*x", "a b"}) {
		_, ok := grant_parse(bad, 0)
		testing.expectf(t, !ok, "%q accepted", bad)
	}
	// Round trip through text.
	back := make([dynamic]Grant, context.temp_allocator)
	testing.expect(t, grants_parse(grants_text(mod), &back, context.temp_allocator))
	testing.expect_value(t, len(back), len(mod))
	for b, i in back {testing.expect(t, b == mod[i])}
}
