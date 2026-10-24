package client

import "core:fmt"
import "core:strings"

import "../game"
import "../worldgen"

// Console commands that change the world: selections, bulk edits,
// explosions, rockets, critters. They are cheats (the server's Admin
// commands, game.Admin): console_register checks that before they run.

@(private)
register_world_commands :: proc(c: ^Console) {
	cheat :: Command_Needs{.World, .Cheats}
	console_register(
		c,
		{"fly", "fly: start or stop flying (double-tap jump)", proc(app: ^App, args: []string) {
				app.session.toggle_fly = true
			}},
		args = {0, 0},
		needs = {.World},
	)
	console_register(
		c,
		{"fire", "fire: a rocket where you look (the launcher)", proc(app: ^App, args: []string) {
				session_fire(app.session)
			}},
		args = {0, 0},
		needs = cheat,
	)
	console_register(
		c,
		{
			"pos1",
			"pos1: the aimed block is the selection's first corner",
			proc(app: ^App, args: []string) {
				select_corner(app, 0)
			},
		},
		args = {0, 0},
		needs = {.World},
	)
	console_register(
		c,
		{
			"pos2",
			"pos2: the aimed block is the selection's second corner",
			proc(app: ^App, args: []string) {
				select_corner(app, 1)
			},
		},
		args = {0, 0},
		needs = {.World},
	)
	console_register(c, {"sel", "sel: forget the selection", proc(app: ^App, args: []string) {
				app.session.selection = {}
			}}, args = {0, 0}, needs = {.World})
	console_register(
		c,
		{"fill", "fill <block>: fill the selection", proc(app: ^App, args: []string) {
				selection_command(app, "fill", args[0])
			}},
		complete_block_or_air,
		args = {1, 1},
		needs = cheat,
	)
	console_register(
		c,
		{"replace", "replace <from> <to>: in the selection", proc(app: ^App, args: []string) {
				selection_command(app, "replace", strings.join(args, " ", context.temp_allocator))
			}},
		complete_block_or_air,
		args = {2, 2},
		needs = cheat,
	)
	// Not a cheat, without a selection: the console's own clear.
	console_register(
		c,
		{
			"clear",
			"clear: air in the whole selection (or clear the console with no selection)",
			proc(app: ^App, args: []string) {
				s := app.session
				if s != nil && s.selection[0] != nil && s.selection[1] != nil {
					if !session_can_cheat(s) {
						console_print(&app.console, "clear: not allowed on this server", .Warning)
						return
					}
					selection_command(app, "fill", "air")
				} else {
					console_clear(&app.console)
				}
			},
		},
		args = {0, 0},
	)
	console_register(
		c,
		{
			"sphere",
			"sphere <radius> [block]: a ball of block (air: a hole) at the aimed block",
			proc(app: ^App, args: []string) {
				p, aimed := aimed_block(app, "sphere")
				if !aimed {return}
				block := args[1] if len(args) > 1 else "air"
				send_message(
					app.session,
					game.Admin {
						fmt.tprintf("sphere %d %d %d %s %s", p.x, p.y, p.z, args[0], block),
					},
				)
			},
		},
		complete_sphere,
		args = {1, 2},
		needs = cheat,
	)
	console_register(
		c,
		{
			"explode",
			"explode [radius]: an explosion at the aimed block",
			proc(app: ^App, args: []string) {
				p, aimed := aimed_block(app, "explode")
				if !aimed {return}
				radius := args[0] if len(args) > 0 else "4"
				send_message(
					app.session,
					game.Admin{fmt.tprintf("explode %d %d %d %s", p.x, p.y, p.z, radius)},
				)
			},
		},
		args = {0, 1},
		needs = cheat,
	)
	console_register(
		c,
		{
			"locate",
			"locate <biome>: fly to the nearest place of a biome",
			proc(app: ^App, args: []string) {
				send_message(app.session, game.Admin{fmt.tprintf("locate %s", args[0])})
			},
		},
		proc(app: ^App, arg: int, args: []string) -> []string {
			names := make([dynamic]string, context.temp_allocator)
			if arg == 0 {for n in worldgen.BIOME_NAMES {append(&names, n)}}
			return names[:]
		},
		args = {1, 1},
		needs = cheat,
	)
	console_register(
		c,
		{"summon", "summon [kind]: an entity in front of you", proc(app: ^App, args: []string) {
				send_message(
					app.session,
					game.Admin{fmt.tprintf("summon %s", args[0] if len(args) > 0 else "critter")},
				)
			}},
		complete_summon,
		args = {0, 1},
		needs = cheat,
	)
}

// select_corner sets corner i of the selection to the aimed block.
@(private = "file")
select_corner :: proc(app: ^App, i: int) {
	s := app.session
	hit, ok := s.aim.?
	if !ok {
		console_print(&app.console, fmt.tprintf("pos%d: aim at a block first", i + 1), .Warning)
		return
	}
	s.selection[i] = hit.block
	console_print(&app.console, fmt.tprintf("pos%d: %v", i + 1, hit.block))
}

// selection_command sends a bulk edit over the selection.
@(private = "file")
selection_command :: proc(app: ^App, what: string, rest: string) {
	s := app.session
	a, ok_a := s.selection[0].?
	b, ok_b := s.selection[1].?
	if !ok_a || !ok_b {
		console_print(
			&app.console,
			fmt.tprintf("%s: select two corners first (pos1, pos2)", what),
			.Warning,
		)
		return
	}
	send_message(
		s,
		game.Admin {
			fmt.tprintf("%s %d %d %d %d %d %d %s", what, a.x, a.y, a.z, b.x, b.y, b.z, rest),
		},
	)
}

// aimed_block: the block aimed at (else says so).
@(private = "file")
aimed_block :: proc(app: ^App, what: string) -> (game.Block_Pos, bool) {
	hit, ok := app.session.aim.?
	if !ok {console_print(&app.console, fmt.tprintf("%s: aim at a block first", what), .Warning)}
	return hit.block, ok
}

@(private = "file")
complete_summon :: proc(app: ^App, arg: int, args: []string) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	for k in game.Entity_Kind {
		if arg == 0 && game.ENTITY_INFO[k].summonable {append(&names, game.ENTITY_INFO[k].name)}
	}
	return names[:]
}
