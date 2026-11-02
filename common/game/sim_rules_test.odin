package game

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:testing"

// M49b: the rule language's compiler. Rules are written into a pack file (data/sim/bad.json
// of the pack sim_test) and compiled with the base pack, so every refusal is checked as a
// player sees it: pack, file, line, column and message.

@(private = "file")
errors_if :: proc(reg: ^Registry, errs: []Pack_Error) -> string {
	return "" if reg != nil else errors_text(errs)
}

@(private = "file")
RULE_FILE :: "data/sim/bad.json"

@(private = "file")
build_with :: proc(file: string, creep := SIM_TEST_CREEP) -> (reg: ^Registry, errs: []Pack_Error) {
	extra := []Pack_File{{RULE_FILE, transmute([]u8)file}}
	src := sim_test_pack(extra, creep = creep)
	return registry_build(
		{base_pack_source(context.temp_allocator), src},
		.Server,
		context.temp_allocator,
	)
}

// rule_of: a statement rule over sim_test:creep with the given do items (each a JSON value).
@(private = "file")
rule_of :: proc(items: string) -> string {
	return fmt.tprintf(
		`{{"r": {{"blocks": ["sim_test:creep"], "trigger": "scheduled", "do": [%s]}}}}`,
		items,
	)
}

@(private = "file")
position_of :: proc(text, marker: string, nth := 1, off := 0) -> (line, col: i32) {
	at := -1
	from := 0
	for _ in 0 ..< nth {
		i := strings.index(text[from:], marker)
		if i < 0 {return -1, -1}
		at = from + i
		from = at + 1
	}
	at += off
	line, col = 1, 1
	for c in transmute([]u8)text[:at] {
		if c == '\n' {line += 1; col = 1} else {col += 1}
	}
	return
}

Refusal_Case :: struct {
	name:    string,
	json:    string,
	marker:  string, // the first byte of the token at fault
	nth:     int,
	off:     int, // marker's offset to the token (the end of a string: its length)
	message: string,
}

@(test)
test_rule_refusals :: proc(t: ^testing.T) {
	many63 := strings.repeat(`"stop", `, 63, context.temp_allocator)
	many_blocks := strings.repeat(`"sim_test:creep", `, 16, context.temp_allocator)
	many_list := strings.repeat(`"voxiverse:stone", `, 64, context.temp_allocator)
	nest5 := `{"repeat": 1, "do": [{"repeat": 1, "do": [{"repeat": 1, "do": [{"repeat": 1, "do": [{"repeat": 1, "do": ["stop"]}]}]}]}]}`
	cases := []Refusal_Case {
		{
			"unknown statement word",
			rule_of(`"frobnicate self"`),
			"frobnicate",
			1,
			0,
			`unknown statement word "frobnicate": use require, chance, pick, set, schedule or stop`,
		},
		{
			"require without a condition",
			rule_of(`"require"`),
			`require"`,
			1,
			7,
			`expected a number, a channel (cell.name), a property (cell[name]) or index(...): write one`,
		},
		{
			"unclosed parenthesis",
			rule_of(`"require (self is voxiverse:stone"`),
			`stone"`,
			1,
			5,
			`expected ")", found the end of the statement: write ")" here`,
		},
		{"chance 1", rule_of(`"chance 1"`), `1"`, 1, 0, `chance 1 is out of range: use 2..65536`},
		{
			"repeat 17",
			rule_of(`{"repeat": 17, "do": ["stop"]}`),
			`17`,
			1,
			0,
			`"repeat" is a whole number 1..16: use a number in range`,
		},
		{
			"delay 0",
			`{"r": {"blocks": ["sim_test:creep"], "trigger": "scheduled", "delay": 0, "do": ["stop"]}}`,
			`0,`,
			1,
			0,
			`delay is 1..1200, got 0`,
		},
		{
			"schedule 1201",
			rule_of(`"pick t 0..0 0..0 0..0", "schedule t 1201"`),
			`1201`,
			1,
			0,
			`schedule 1201 ticks is out of range: use 1..1200`,
		},
		{
			"no trigger",
			`{"r": {"blocks": ["sim_test:creep"], "do": ["stop"]}}`,
			`"r"`,
			1,
			0,
			`a statement rule needs "trigger": "scheduled" or "random"`,
		},
		{
			"behaviour and trigger",
			`{"r": {"behaviour": "flow", "trigger": "scheduled", "blocks": ["sim_test:creep"], "do": ["stop"]}}`,
			`"r"`,
			1,
			0,
			`a rule has "behaviour" or "trigger", not both: remove one`,
		},
		{
			"unknown block",
			rule_of(`"require self is voxiverse:stoon"`),
			`voxiverse:stoon`,
			1,
			0,
			`"voxiverse:stoon" is not a block: name a block some pack defines`,
		},
		{
			"unknown state value",
			rule_of(`"require self is voxiverse:planks_stairs[half=middle]"`),
			`middle`,
			1,
			0,
			`property "half" of "voxiverse:planks_stairs" has no value "middle": it has bottom, top`,
		},
		{
			"unknown state property",
			rule_of(`"require self is voxiverse:planks_stairs[wet=1]"`),
			`wet`,
			1,
			0,
			`"voxiverse:planks_stairs" has no property "wet": it has facing, half`,
		},
		{
			"unknown tag",
			rule_of(`"require self is #sim_test:nope"`),
			`sim_test:nope`,
			1,
			0,
			`"#sim_test:nope" is not a block tag: name a tag some pack defines`,
		},
		{
			"unknown flag",
			rule_of(`"require self is @wobbly"`),
			`wobbly`,
			1,
			0,
			`"@wobbly" is not a block flag: use one of collides, opaque, targetable, breakable, placeable, replaceable, shades, cull_same, liquid`,
		},
		{
			"unknown list",
			rule_of(`"require self is $sim_test:nope"`),
			`sim_test:nope`,
			1,
			0,
			`"$sim_test:nope" is not a list or a flow rule: name one a pack defines`,
		},
		{
			"unknown channel",
			rule_of(`"require self.nothing > 0"`),
			`nothing`,
			1,
			0,
			`"nothing" is not a channel of sim_test or voxiverse: name a channel a pack defines`,
		},
		{
			"unknown property",
			rule_of(`"require self[foo] > 0"`),
			`foo`,
			1,
			0,
			`no block has a property "foo": name a property some block type has`,
		},
		{
			"set a computed channel",
			rule_of(`"set self.light 3"`),
			`light`,
			1,
			0,
			`channel "light" is computed and cannot be set: set a stored channel`,
		},
		{
			"cost over",
			rule_of(
				`{"repeat": 16, "do": ["require count box(-4..4, -4..4, -4..4) is @opaque > 0"]}`,
			),
			`[{"repeat"`,
			1,
			0,
			`rule sim_test:r costs up to 11681 cell reads a run, over 4096: shrink the box or the repeat`,
		},
		{
			"65 statements",
			rule_of(
				strings.concatenate(
					{many63, `{"repeat": 1, "do": ["stop"]}`},
					context.temp_allocator,
				),
			),
			`"stop"`,
			64,
			0,
			`more than 64 statements in a rule: split the rule`,
		},
		{
			"nesting 5",
			rule_of(nest5),
			`{"repeat": 1, "do": ["stop"]}`,
			1,
			0,
			`nested deeper than 4: flatten the rule`,
		},
		{
			"five picks",
			rule_of(
				`"pick a 0..0 0..0 0..0", "pick b 0..0 0..0 0..0", "pick c 0..0 0..0 0..0", "pick d 0..0 0..0 0..0", "pick e 0..0 0..0 0..0"`,
			),
			`e 0..0`,
			1,
			0,
			`more than 4 picks in a rule: reuse a name's cell or drop one`,
		},
		{
			"pick bound twice",
			rule_of(`"pick a 0..0 0..0 0..0", "pick a 1..1 0..0 0..0"`),
			`a 1..1`,
			1,
			0,
			`pick "a" is bound twice: give the second another name`,
		},
		{
			"pick read before binding",
			rule_of(`"require t is voxiverse:stone"`),
			`t is`,
			1,
			0,
			`"t" is not a cell: use self, above, below, north, south, east, west or a name bound by an earlier pick`,
		},
		{
			"box 10 wide",
			rule_of(`"require any box(-4..5, 0..0, 0..0) is voxiverse:stone"`),
			`-4..5`,
			1,
			0,
			`a box 10 blocks wide is over 9: make it narrower`,
		},
		{
			"reach 9",
			rule_of(`"require self + (9, 0, 0) is voxiverse:stone"`),
			`self +`,
			1,
			0,
			`offset 9 is over the reach of 8 blocks from self: bring the cell closer`,
		},
		{
			"17 matchers",
			fmt.tprintf(
				`{{"r": {{"blocks": [%s"sim_test:creep"], "trigger": "scheduled", "do": ["stop"]}}}}`,
				many_blocks,
			),
			`[`,
			1,
			0,
			`"blocks" is an array of 1 to 16 block matchers: write the blocks the rule runs on`,
		},
		{
			"list of 65",
			fmt.tprintf(`{{"l": {{"list": [%s"voxiverse:stone"]}}}}`, many_list),
			`[`,
			1,
			0,
			`"list" is an array of 1 to 64 block values: write the blocks in order`,
		},
		{
			"list member with many states",
			`{"l": {"list": ["voxiverse:planks_stairs"]}}`,
			`"voxiverse:planks_stairs"`,
			1,
			1,
			`"voxiverse:planks_stairs" names 8 states, a list member is one block value: write a state such as "voxiverse:planks_stairs[...]"`,
		},
		{
			"set without a target",
			rule_of(`"set self"`),
			`self"`,
			1,
			4,
			`expected a block, $list[...], .channel or [property] after the cell`,
		},
		{
			"count too big",
			rule_of(`"require count box(0..1, 0..1, 0..1) is @opaque > 800"`),
			`800`,
			1,
			0,
			`a count is 0..729, not 800: use a number in range`,
		},
	}
	for c in cases {
		reg, errs := build_with(c.json)
		if !testing.expectf(t, reg == nil && len(errs) > 0, "%s: accepted", c.name) {continue}
		e := errs[0]
		line, col := position_of(c.json, c.marker, max(c.nth, 1), c.off)
		testing.expectf(
			t,
			e.pack == "sim_test" && e.file == RULE_FILE,
			"%s: where: %s/%s",
			c.name,
			e.pack,
			e.file,
		)
		testing.expectf(
			t,
			e.line == line && e.column == col,
			"%s: at %d:%d, want %d:%d (%s)",
			c.name,
			e.line,
			e.column,
			line,
			col,
			e.message,
		)
		if c.message != "" {
			testing.expectf(
				t,
				e.message == c.message,
				"%s: message %q, want %q",
				c.name,
				e.message,
				c.message,
			)
		} else {
			fmt.printfln("%s: %s", c.name, e.message)
		}
	}
}

@(test)
test_rule_errors_cap :: proc(t: ^testing.T) {
	items := strings.repeat(`"frobnicate", `, 49, context.temp_allocator)
	json := rule_of(strings.concatenate({items, `"frobnicate"`}, context.temp_allocator))
	_, errs := build_with(json)
	testing.expect_value(t, len(errs), 20)
}

@(test)
test_rule_costs :: proc(t: ^testing.T) {
	reg, errs := build_with(rule_of(`"stop"`))
	testing.expect(t, reg != nil, errors_if(reg, errs))
	if reg == nil {return}
	cost :: proc(reg: ^Registry, id: string) -> i32 {
		at, found := reg.ids[.Sim_Rule][id]
		assert(found, id)
		return reg.sim.rules[at].program.cost
	}
	// creep: `require self.potency > 0` 1 + 1; the repeat 1 + 2 rounds of 7: pick 1,
	// `require t is` 1 + 1, set 1, `set t.potency ...` 1 + its read 1, schedule 1.
	testing.expect_value(t, cost(reg, "sim_test:creep"), i32(17))
	// fire: the `if` 1 + its box 27 + `set` 1 + `stop` 1 = 30; schedule 1; the repeat 1 + 3
	// rounds of 5 (pick 1, require 1 + 1, chance 1, set 1) = 16; chance 1; set 1.
	testing.expect_value(t, cost(reg, "sim_test:fire"), i32(49))
	// A rule with nested repeats, if / else if / else, boxes and `.light`.
	nested := rule_of(
		`{"repeat": 2, "do": [{"repeat": 2, "do": ["pick t -1..1 -1..1 -1..1",` +
		`{"if": "t.light >= 9", "then": ["set t voxiverse:air"],` +
		` "else": [{"if": "any box(-1..1, 0..0, 0..0) is @opaque", "then": ["stop"], "else": ["chance 2"]}]}]}]}`,
	)
	reg2, errs2 := build_with(nested)
	testing.expect(t, reg2 != nil, errors_if(reg2, errs2))
	if reg2 == nil {return}
	// outer repeat 1 + 2 x (inner repeat 1 + 2 x (pick 1 + if (1 + light 377 + set 1 + else
	// if (1 + box 3 + stop 1 + chance 1)))) = 1 + 2 x (1 + 2 x 386) = 1 547
	testing.expect_value(t, cost(reg2, "sim_test:r"), i32(1547))
}

@(test)
test_rules_compile :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator // (rule_list_of formats an id)
	reg, errs := build_with(rule_of(`"stop"`))
	if !testing.expect(t, reg != nil, errors_if(reg, errs)) {return}
	at, _ := reg.ids[.Sim_Rule]["sim_test:creep"]
	rule := &reg.sim.rules[at]
	testing.expect(t, rule.is_program)
	testing.expect_value(t, rule.trigger, Rule_Trigger.Scheduled)
	testing.expect_value(t, rule.delay, u16(10))
	testing.expect_value(t, rule.wake, Wake_Set{.Placed})
	p := &rule.program
	// require, repeat; the repeat's body: pick, require, set, set channel, schedule.
	testing.expect_value(t, len(p.stmts), 7)
	testing.expect_value(t, p.stmts[p.first].kind, Rule_Stmt_Kind.Require)
	rep := p.stmts[p.stmts[p.first].next]
	testing.expect_value(t, rep.kind, Rule_Stmt_Kind.Repeat)
	testing.expect_value(t, rep.value, i32(2))
	kinds: [dynamic]Rule_Stmt_Kind
	defer delete(kinds)
	for i := rep.child; i >= 0; i = p.stmts[i].next {append(&kinds, p.stmts[i].kind)}
	testing.expect_value(t, len(kinds), 5)
	want := [?]Rule_Stmt_Kind{.Pick, .Require, .Set_Block, .Set_Channel, .Schedule}
	for k, i in want {if i < len(kinds) {testing.expect_value(t, kinds[i], k)}}
	// Matchers: stone is one block; the rule's own blocks are creep alone.
	creep, _ := registry_block(reg, "sim_test:creep")
	stone, _ := registry_block(reg, "voxiverse:stone")
	testing.expect(t, rule_matcher_has(&p.blocks, creep) && !rule_matcher_has(&p.blocks, stone))
	// Flags, tags and lists compile to the sets the registry says.
	reg2, errs2 := build_with(
		rule_of(
			`"require self is @opaque", "require self is #sim_test:flammable", "require self is $voxiverse:water", "require self is voxiverse:planks_stairs[half=top]"`,
		),
	)
	if !testing.expect(t, reg2 != nil, errors_if(reg2, errs2)) {return}
	at2, _ := reg2.ids[.Sim_Rule]["sim_test:r"]
	p2 := &reg2.sim.rules[at2].program
	testing.expect_value(t, len(p2.matchers), 4)
	tag, _ := registry_block_tag(reg2, "sim_test:flammable")
	for b in 0 ..< reg2.blocks.count {
		blk := Block(b)
		testing.expect_value(
			t,
			rule_matcher_has(&p2.matchers[0], blk),
			block_has(&reg2.blocks, blk, .Opaque),
		)
		testing.expect_value(
			t,
			rule_matcher_has(&p2.matchers[1], blk),
			block_in_tag(&reg2.blocks, blk, tag),
		)
	}
	water, _ := rule_list_of(reg2, "voxiverse:water")
	members := 0
	for b in reg2.sim.lists[water].blocks {
		members += 1
		testing.expect(t, rule_matcher_has(&p2.matchers[2], b))
	}
	count := 0
	for b in 0 ..< reg2.blocks.count {if rule_matcher_has(&p2.matchers[2], Block(b)) {count += 1}}
	testing.expect_value(t, count, members)
	// One state of water: exactly one block has "level=2" and not "falling".
	one := 0
	for b in 0 ..< reg2.blocks.count {if rule_matcher_has(&p2.matchers[3], Block(b)) {one += 1}}
	testing.expect(t, one >= 1)
}

@(test)
test_rule_compile_frees :: proc(t: ^testing.T) {
	track: mem.Tracking_Allocator
	mem.tracking_allocator_init(&track, context.allocator)
	defer mem.tracking_allocator_destroy(&track)
	context.allocator = mem.tracking_allocator(&track)
	base_src := base_pack_source(context.temp_allocator)
	src := sim_test_pack()
	for _ in 0 ..< 100 {
		reg, errs := registry_build({base_src, src}, .Server)
		if reg == nil {
			testing.expect(t, false, errors_if(reg, errs))
			return
		}
		registry_destroy(reg)
	}
	testing.expect_value(t, len(track.allocation_map), 0)
}
