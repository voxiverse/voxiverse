package game

import "core:fmt"
import "core:strings"

// Channels and simulation rules in the registry (M49).
//
// data/channels/<file>.json: {"wetness": {"bits": 4, "default": 0, "saved": true, "replicated": true}}
// data/sim/<file>.json:      {"water": {"behaviour": "flow", "levels": [...], "falling": "...", ...}}
//
// Channel 0 is the built-in voxiverse:light (computed, never stored), so a world has
// MAX_CHANNELS - 1 stored channels at most; ids follow in load order.

Computed :: enum u8 {
	None,
	Light, // light_above: a pure function of the blocks (server/core/sim.odin)
}

Channel_Info :: struct {
	name:       string,
	bits:       u8, // 1..16
	default:    u16,
	saved:      bool,
	replicated: bool,
	keep:       bool, // the value survives a change of the cell's block
	computed:   Computed,
}

channel_max :: proc(c: Channel_Info) -> u16 {
	return u16(0xffff) if c.bits >= 16 else u16(1 << c.bits) - 1
}

LIGHT_CHANNEL :: 0

// registry_channel: the id of the channel named text (`voxiverse:light`, or a bare name).
registry_channel :: proc(reg: ^Registry, text: string) -> (int, bool) {
	id, ok := id_parse(text)
	if !ok {return 0, false}
	buf: [96]u8
	n, found := reg.ids[.Channel][fmt.bprintf(buf[:], "%s:%s", id.namespace, id.name)]
	return int(n), found
}

// registry_replicated_channels: how many channels a client keeps (replicated, not computed).
registry_replicated_channels :: proc(reg: ^Registry) -> int {
	n := 0
	for c in reg.channels {if c.replicated && c.computed == .None {n += 1}}
	return n
}

// channels_stored: how many channels have storage (are not computed).
registry_stored_channels :: proc(reg: ^Registry) -> int {
	n := 0
	for c in reg.channels {if c.computed == .None {n += 1}}
	return n
}

// Fluid: the flow behaviour's data (server/core/flow.odin). levels[0] is the source, then
// the flowing levels 1..n; falling is the block of a column falling.
Fluid :: struct {
	levels:       []Block,
	falling:      Block,
	delay:        u16, // ticks between a cell's updates
	reach:        i32, // how far a cell looks for a way down
	sources_form: bool,
}

Sim_Behaviour :: enum u8 {
	Flow,
}
SIM_BEHAVIOUR_LIST := [?]string{"flow"}
#assert(len(SIM_BEHAVIOUR_LIST) == len(Sim_Behaviour))

Rule_Trigger :: enum u8 {
	Scheduled,
	Random,
}
RULE_TRIGGER_LIST := [?]string{"scheduled", "random"}
#assert(len(RULE_TRIGGER_LIST) == len(Rule_Trigger))

// Rule: a flow rule (behaviour Flow, fluid) or a statement rule (is_program, program: the
// rule language of sim_rules.odin, with its trigger, delay and wakes).
Rule :: struct {
	id:         string,
	behaviour:  Sim_Behaviour,
	fluid:      Fluid,
	is_program: bool,
	trigger:    Rule_Trigger,
	delay:      u16,
	wake:       Wake_Set,
	program:    Rule_Program,
}

// Rule_List: an ordered list of block values a rule can name as `$id` (a flow rule is also
// one: its levels, then its falling block).
Rule_List :: struct {
	id:     string,
	blocks: []Block,
}

Wake :: enum u8 {
	Placed,
	Neighbour,
	Load,
}
Wake_Set :: bit_set[Wake;u8]

// Sim_Rules: the compiled rules of a registry, by block value: which rules run when a cell
// of the block is due (scheduled, in rule order), when it wakes, after how long.
Sim_Rules :: struct {
	rules:      []Rule,
	lists:      []Rule_List,
	scheduled:  [][]u16, // by block: rule indices (nil for most blocks)
	random:     [][]u16, // by block: statement rules that run on a random tick (M49e runs them)
	wakes:      []Wake_Set,
	delay:      []u16, // by block: the smallest delay of its rules
	flow_rule:  []u16, // by block: the flow rule it belongs to, plus one (0: none)
	flow_level: []u8, // by block: its level in that rule plus one (the falling block: levels + 1, plus one)
	any:        bool, // some block has a rule
}

sim_rules_of :: proc(reg: ^Registry, b: Block) -> []u16 {
	if int(b) >= len(reg.sim.scheduled) {return nil}
	return reg.sim.scheduled[b]
}

@(private)
CHANNEL_FIELDS := []string{"bits", "default", "saved", "replicated", "keep", "override"}
@(private)
SIM_FIELDS := []string {
	"behaviour",
	"levels",
	"falling",
	"delay",
	"reach",
	"sources_form",
	"list",
	"blocks",
	"trigger",
	"wake",
	"do",
	"override",
}

@(private)
read_channel :: proc(b: ^Reg_Build, m: ^Merged_Def) -> Channel_Info {
	c := Channel_Info {
		name       = m.id,
		bits       = u8(rd_int(b, m, "bits", 1, 1, 16)),
		saved      = rd_bool(b, m, "saved", false),
		replicated = rd_bool(b, m, "replicated", false),
		keep       = rd_bool(b, m, "keep", false),
	}
	if field_of(m, "bits") == nil {
		fail(b, m.pack, m.file, m.line, m.column, "a channel needs \"bits\": 1..16")
	}
	c.default = u16(rd_int(b, m, "default", 0, 0, int(channel_max(c))))
	return c
}

@(private)
read_channels :: proc(b: ^Reg_Build, reg: ^Registry) {
	n := len(b.defs[.Channel]) + 1
	if n > MAX_CHANNELS {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf(
				"%d channels; the limit is %d, voxiverse:light included",
				len(b.defs[.Channel]),
				MAX_CHANNELS - 1,
			),
		)
		return
	}
	reg.channels = make([]Channel_Info, n)
	reg.channels[LIGHT_CHANNEL] = {
		name     = BASE_NAMESPACE + ":light",
		bits     = 4,
		computed = .Light,
	}
	reg.ids[.Channel][reg.channels[LIGHT_CHANNEL].name] = LIGHT_CHANNEL
	for &m, i in b.defs[.Channel] {
		if m.id == reg.channels[LIGHT_CHANNEL].name {
			fail(
				b,
				m.pack,
				m.file,
				m.line,
				m.column,
				"voxiverse:light is built in; name the channel something else",
			)
			continue
		}
		reg.channels[i + 1] = read_channel(b, &m)
		reg.ids[.Channel][m.id] = u32(i + 1)
	}
}

// resolve_block_text: a block value named by id or by state text.
@(private)
resolve_block_text :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
	v: Json_Value,
	what: string,
) -> (
	Block,
	bool,
) {
	if v.kind != .String {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf("%s is a block id or state such as \"ns:oil[level=1]\"", what),
		)
		return .Air, false
	}
	blk, ok := registry_block(reg, v.s)
	if !ok {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf(
				"%s: \"%s\" is not a block%s",
				what,
				v.s,
				suggestion(v.s, index_keys(b.index[.Block]), false),
			),
		)
	}
	return blk, ok
}

@(private)
read_sim_rule :: proc(b: ^Reg_Build, reg: ^Registry, m: ^Merged_Def) -> (rule: Rule, ok: bool) {
	rule.id = m.id
	bf := field_of(m, "behaviour")
	if bf == nil && field_of(m, "do") != nil {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"a statement rule needs \"trigger\": \"scheduled\" or \"random\"",
		)
		return
	}
	if bf == nil {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			fmt.aprintf(
				"a rule needs \"behaviour\": one of %s",
				join_quoted(SIM_BEHAVIOUR_LIST[:]),
			),
		)
		return
	}
	rule.behaviour = Sim_Behaviour(
		choice_of(b, bf, bf.value, "behaviour", SIM_BEHAVIOUR_LIST[:], 0),
	)
	ok = true
	lf := field_of(m, "levels")
	if lf == nil || lf.value.kind != .Array {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"a flow rule needs \"levels\": the source block, then the flowing levels 1..n",
		)
		return {}, false
	}
	if len(lf.value.items) < 1 || len(lf.value.items) > 16 {
		fail_field(
			b,
			lf,
			lf.value,
			fmt.aprintf(
				"levels holds the source and 1 to 15 flowing levels, not %d blocks",
				len(lf.value.items),
			),
		)
		return {}, false
	}
	levels := make([dynamic]Block)
	for it in lf.value.items {
		blk, found := resolve_block_text(b, reg, lf, it, "a level")
		if !found {ok = false; continue}
		for x in levels {
			if x == blk {
				fail_field(
					b,
					lf,
					it,
					fmt.aprintf("\"%s\" is named twice; each block is one level", it.s),
				)
				ok = false
			}
		}
		append(&levels, blk)
	}
	rule.fluid.levels = levels[:]
	ff := field_of(m, "falling")
	if ff == nil {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"a flow rule needs \"falling\": the block of a falling column",
		)
		return {}, false
	}
	if blk, found := resolve_block_text(b, reg, ff, ff.value, "falling"); found {
		for x in levels {
			if x == blk {
				fail_field(
					b,
					ff,
					ff.value,
					"falling is named twice; it is its own block, not a level",
				)
				ok = false
			}
		}
		rule.fluid.falling = blk
	} else {
		ok = false
	}
	rule.fluid.delay = u16(rd_int(b, m, "delay", 5, 1, 1200))
	rule.fluid.reach = i32(rd_int(b, m, "reach", 4, 0, 6))
	rule.fluid.sources_form = rd_bool(b, m, "sources_form", false)
	return rule, ok
}

// build_sim_rules: the rules of the packs, compiled to tables by block. Flow rules and
// lists first (they are lists a statement rule can name), then the statement rules.
@(private)
build_sim_rules :: proc(b: ^Reg_Build, reg: ^Registry) {
	rules := make([dynamic]Rule)
	lists := make([dynamic]Rule_List)
	n := reg.blocks.count
	reg.sim.scheduled = make([][]u16, n)
	reg.sim.random = make([][]u16, n)
	reg.sim.wakes = make([]Wake_Set, n)
	reg.sim.delay = make([]u16, n)
	reg.sim.flow_rule = make([]u16, n)
	reg.sim.flow_level = make([]u8, n)
	owner := make([]int, n) // the rule that claimed a block for flow, +1
	kinds := make([]u8, len(b.defs[.Sim_Rule])) // 0 flow, 1 list, 2 statements
	for &m, mi in b.defs[.Sim_Rule] {
		lf, tf := field_of(&m, "list"), field_of(&m, "trigger")
		bf := field_of(&m, "behaviour")
		switch {
		case lf != nil:
			kinds[mi] = 1
			if bf != nil || tf != nil || field_of(&m, "do") != nil {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					"a list has only \"list\": remove \"behaviour\", \"trigger\" and \"do\"",
				)
				continue
			}
			l, ok := read_rule_list(b, reg, &m, lf)
			if !ok {continue}
			append(&lists, l)
			continue
		case tf != nil:
			kinds[mi] = 2
			if bf != nil {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					"a rule has \"behaviour\" or \"trigger\", not both: remove one",
				)
			}
			continue
		}
		rule, ok := read_sim_rule(b, reg, &m)
		if !ok {continue}
		at := len(rules)
		append(&rules, rule)
		reg.ids[.Sim_Rule][m.id] = u32(at)
		blocks := make([dynamic]Block)
		append(&blocks, ..rule.fluid.levels)
		append(&blocks, rule.fluid.falling)
		append(&lists, Rule_List{m.id, blocks[:]})
		for blk, bi in blocks {
			if owner[blk] != 0 {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					fmt.aprintf(
						"\"%s\" already flows by rule %s; one flow rule a block",
						block_id(reg, blk),
						rules[owner[blk] - 1].id,
					),
				)
				continue
			}
			owner[blk] = at + 1
			reg.sim.flow_rule[blk] = u16(at + 1)
			reg.sim.flow_level[blk] = u8(bi) + 1 // (levels in order, then falling: levels + 1)
			reg.sim.scheduled[blk] = append_u16(reg.sim.scheduled[blk], u16(at))
			reg.sim.wakes[blk] = {.Placed, .Neighbour, .Load}
			reg.sim.delay[blk] = rule.fluid.delay
			reg.sim.any = true
		}
	}
	reg.sim.lists = lists[:]
	for &m, mi in b.defs[.Sim_Rule] {
		if kinds[mi] != 2 {continue}
		build_statement_rule(b, reg, &m, &rules, owner)
	}
	reg.sim.rules = rules[:]
}

// build_statement_rule: a rule with a trigger: its envelope, its program, and the blocks it
// runs on get it in their tables.
@(private)
build_statement_rule :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	m: ^Merged_Def,
	rules: ^[dynamic]Rule,
	flow_owner: []int,
) {
	rule := Rule {
		id         = m.id,
		is_program = true,
	}
	ok := true
	tf := field_of(m, "trigger")
	rule.trigger = Rule_Trigger(choice_of(b, tf, tf.value, "trigger", RULE_TRIGGER_LIST[:], 0))
	rule.delay = u16(rd_int(b, m, "delay", 1, 1, 1200))
	rule.wake = {.Placed}
	if wf := field_of(m, "wake"); wf != nil {
		rule.wake = {}
		if wf.value.kind != .Array {
			fail_field(b, wf, wf.value, "wake is an array of \"placed\", \"neighbour\", \"load\"")
			ok = false
		} else {
			for it in wf.value.items {
				names := [?]string{"placed", "neighbour", "load"}
				w := choice_of(b, wf, it, "wake", names[:], -1)
				if w >= 0 {rule.wake += {Wake(w)}} else {ok = false}
			}
		}
	}
	bf, df := field_of(m, "blocks"), field_of(m, "do")
	if bf == nil || df == nil {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"a statement rule needs \"blocks\" (the cells it runs on) and \"do\" (its statements)",
		)
		return
	}
	for f in ([]string{"levels", "falling", "reach", "sources_form"}) {
		if ff := field_of(m, f); ff != nil {
			fail_field(b, ff, ff.value, fmt.aprintf("\"%s\" belongs to a flow rule: remove it", f))
			ok = false
		}
	}
	prog, refusal := rule_compile(b, reg, m, bf, df)
	if refusal != .None || !ok {return}
	rule.program = prog
	at := len(rules)
	append(rules, rule)
	reg.ids[.Sim_Rule][m.id] = u32(at)
	for blk in 0 ..< reg.blocks.count {
		if !rule_matcher_has(&prog.blocks, Block(blk)) {continue}
		switch rule.trigger {
		case .Scheduled:
			if flow_owner[blk] != 0 {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					fmt.aprintf(
						"\"%s\" already flows by rule %s; a block has a flow rule or statement rules, not both",
						block_id(reg, Block(blk)),
						rules[flow_owner[blk] - 1].id,
					),
				)
				return
			}
			reg.sim.scheduled[blk] = append_u16(reg.sim.scheduled[blk], u16(at))
			reg.sim.wakes[blk] += rule.wake
			if reg.sim.delay[blk] == 0 || rule.delay < reg.sim.delay[blk] {
				reg.sim.delay[blk] = rule.delay
			}
			reg.sim.any = true
		case .Random:
			reg.sim.random[blk] = append_u16(reg.sim.random[blk], u16(at))
		}
	}
}

@(private)
append_u16 :: proc(s: []u16, v: u16) -> []u16 {
	out := make([]u16, len(s) + 1)
	copy(out, s)
	out[len(s)] = v
	return out
}

registry_sim_text :: proc(reg: ^Registry, sb: ^strings.Builder) {
	for c in reg.channels {fmt.sbprintf(sb, "channel %v\n", c)}
	for r in reg.sim.rules {
		if r.is_program {
			fmt.sbprintf(
				sb,
				"sim_rule %s %v %v %v %v %v %v %v\n",
				r.id,
				r.trigger,
				r.delay,
				r.wake,
				r.program.stmts,
				r.program.code,
				r.program.names,
				r.program.cost,
			)
			for m in r.program.matchers {fmt.sbprintf(sb, "  matcher %v\n", m.bits)}
			continue
		}
		fmt.sbprintf(sb, "sim_rule %s %v %v\n", r.id, r.behaviour, r.fluid)
	}
	for l in reg.sim.lists {
		if l.id not_in reg.ids[.Sim_Rule] {fmt.sbprintf(sb, "sim_list %s %v\n", l.id, l.blocks)}
	}
}

// fluid_level: the index of b in f.levels (0 the source), or len(levels) for the falling
// block (the rules' "falling level"); false if b is not a block of the fluid.
fluid_level :: proc(f: ^Fluid, b: Block) -> (level: i32, ok: bool) {
	for l, i in f.levels {
		if l == b {return i32(i), true}
	}
	if f.falling == b {return i32(len(f.levels)), true}
	return 0, false
}

// fluid_block: the inverse of fluid_level.
fluid_block :: proc(f: ^Fluid, level: i32) -> Block {
	if int(level) >= len(f.levels) {return f.falling}
	return f.levels[level]
}
