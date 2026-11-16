package build

import "core:strings"
import "core:testing"

// A declaration is read whole however odinfmt laid it out: a signature split over lines
// comes back on one, its comments and a brace in a default string not taken for code; a
// private one, and a #+private file, are not a game's to see.
@(test)
test_parse_declarations_reads_what_odinfmt_writes :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	p: Parsed_Package
	parse_declarations(
		&p,
		"server/core/x.odin",
		`package core

import "common:game"
import gm "common:geometry"

// teleport: moves c. It lands where it fits.
teleport :: proc(
	s: ^Server, // the session
	c: ^Client,
	sep := "{(",
) -> (
	ok: bool,
) {
	return true
}

@(private)
// hidden: not a game's.
hidden :: proc() {}

// Box: lo..hi inclusive.
Box :: struct {
	lo, hi: game.Block_Pos,
}

// Tone: what a flash says.
Tone :: enum u8 {
	Plain, // nothing
	Good,
}

MAX_TEAMS :: 8 // the sides
UNDOCUMENTED :: 3

// fight :: another package's, under this name.
fight :: squad.fight

// either: one of two.
either :: proc{teleport, fight}
`,
	)
	tp := p.decls["teleport"]
	testing.expect_value(t, tp.kind, Decl_Kind.Proc)
	testing.expect_value(t, tp.head, `proc(s: ^Server, c: ^Client, sep := "{(") -> (ok: bool)`)
	testing.expect_value(t, first_sentence(tp.doc, "teleport"), "moves c.")
	testing.expect_value(t, tp.file, "server/core/x.odin")
	testing.expect(t, "hidden" not_in p.decls, "a private procedure is listed")
	testing.expect_value(t, p.decls["Box"].kind, Decl_Kind.Type)
	testing.expect_value(t, decl_signature("Box", p.decls["Box"]), "Box :: struct {...}")
	testing.expect_value(
		t,
		decl_signature("Tone", p.decls["Tone"]),
		"Tone :: enum u8 {Plain, Good}",
	)
	testing.expect_value(t, p.decls["MAX_TEAMS"].kind, Decl_Kind.Constant)
	testing.expect_value(t, p.decls["MAX_TEAMS"].doc, "the sides")
	testing.expect_value(t, p.decls["UNDOCUMENTED"].doc, "")
	testing.expect_value(t, p.decls["fight"].kind, Decl_Kind.Proc)
	testing.expect_value(
		t,
		decl_signature("either", p.decls["either"]),
		"either :: proc{teleport, fight}",
	)
	testing.expect_value(t, p.imports["game"], "common/game")
	testing.expect_value(t, p.imports["gm"], "common/geometry")

	private_file: Parsed_Package
	parse_declarations(
		&private_file,
		"x.odin",
		"#+private\npackage core\n\n// a: one.\na :: proc() {}\n",
	)
	testing.expect_value(t, len(private_file.decls), 0)
}

// A hook's comment is the one after it, on the line the field ends on (a long signature
// ends lines below its name), or else the lines above it.
@(test)
test_struct_fields_take_their_own_comments :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	fields := struct_fields(
		`
	using info: game.Game_Info, // its id
	start:      proc(s: ^Server) -> bool, // the session is set up
	think:      proc(
		s: ^Server, // (not the field's)
		w: ^World,
	), // each tick
	// what it keeps
	world_files: []World_File,
	a, b:        int,
`,
	)
	testing.expect_value(t, len(fields), 6)
	if len(fields) < 6 {return}
	testing.expect_value(t, fields[0], Map_Field{"info", "game.Game_Info", "its id"})
	testing.expect_value(
		t,
		fields[1],
		Map_Field{"start", "proc(s: ^Server) -> bool", "the session is set up"},
	)
	testing.expect_value(
		t,
		fields[2],
		Map_Field{"think", "proc(s: ^Server, w: ^World)", "each tick"},
	)
	testing.expect_value(t, fields[3], Map_Field{"world_files", "[]World_File", "what it keeps"})
	testing.expect_value(t, fields[4].name, "a")
	testing.expect_value(t, fields[5].type, "int")
}

@(test)
test_first_sentence_stops_at_the_first_full_stop :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		first_sentence("Box: lo..hi inclusive. The rest."),
		"Box: lo..hi inclusive.",
	)
	testing.expect_value(
		t,
		first_sentence("Box: lo..hi inclusive. The rest.", "Box"),
		"lo..hi inclusive.",
	)
	testing.expect_value(
		t,
		first_sentence("a tool (e.g. a pick) works. More."),
		"a tool (e.g. a pick) works.",
	)
	testing.expect_value(t, first_sentence("no stop at all"), "no stop at all")
	testing.expect_value(t, first_sentence("teleport moves c.", "teleport"), "teleport moves c.")
}

// The map names what the lists name, from the source, and says what keeps it from being
// whole: a listed name nothing declares, a listed name with no doc comment.
@(test)
test_engine_map_lists_and_finds_what_is_missing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	packages := make(Map_Packages)
	core_p, engine_p: Parsed_Package
	parse_declarations(
		&core_p,
		"server/core/a.odin",
		"package core\n\n// Game: a game.\nGame :: struct {\n\tstart: proc(s: ^Server) -> bool, // it starts\n}\n\n" +
		"// Server: a session.\nServer :: struct {}\n\n// notice tells c.\nnotice :: proc(s: ^Server, c: ^Client, text: string) {}\n\n" +
		"bare :: proc() {}\n\n// Client: a player.\nClient :: struct {}\n",
	)
	parse_declarations(
		&engine_p,
		"client/engine/a.odin",
		"package engine\n\n// Game: a client part.\nGame :: struct {\n\thud: proc(s: ^Session), // draw it\n}\n",
	)
	packages["server/core"] = core_p
	packages["client/engine"] = engine_p
	packages["server/play"] = {}
	packages["client/overview"] = {}
	games := "# Games\n\n## What a game may call\n\n| Name | For |\n|---|---|\n| `notice(s, c, text)`, `bare`, `gone` | x |\n\n## Next\n"
	text, problems := engine_map(games, &packages)
	testing.expect(
		t,
		strings.contains(text, "| `start` | `proc(s: ^Server) -> bool` | it starts |"),
		text,
	)
	testing.expect(t, strings.contains(text, "| `hud` | `proc(s: ^Session)` | draw it |"), text)
	testing.expect(
		t,
		strings.contains(
			text,
			"- `notice :: proc(s: ^Server, c: ^Client, text: string)`: notice tells c.\n",
		),
		text,
	)
	testing.expect(
		t,
		strings.contains(text, "- `Server :: struct`: a session."),
		"a type a signature names",
	)
	testing.expect(
		t,
		strings.contains(text, "- `Client :: struct`: a player."),
		"a type a signature names",
	)
	testing.expect_value(t, len(problems), 2)
	if len(problems) < 2 {return}
	testing.expect(t, strings.contains(problems[0], "bare has no doc comment"), problems[0])
	testing.expect(t, strings.contains(problems[0], "server/core/a.odin"), problems[0])
	testing.expect(
		t,
		strings.contains(problems[1], "lists gone, which server/core does not declare"),
		problems[1],
	)
}
