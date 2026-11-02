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

Rule :: struct {
	id:        string,
	behaviour: Sim_Behaviour,
	fluid:     Fluid,
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
	scheduled:  [][]u16, // by block: rule indices (nil for most blocks)
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

// build_sim_rules: the rules of the packs, compiled to tables by block.
@(private)
build_sim_rules :: proc(b: ^Reg_Build, reg: ^Registry) {
	rules := make([dynamic]Rule)
	n := reg.blocks.count
	reg.sim.scheduled = make([][]u16, n)
	reg.sim.wakes = make([]Wake_Set, n)
	reg.sim.delay = make([]u16, n)
	reg.sim.flow_rule = make([]u16, n)
	reg.sim.flow_level = make([]u8, n)
	owner := make([]int, n) // the rule that claimed a block for flow, +1
	for &m in b.defs[.Sim_Rule] {
		rule, ok := read_sim_rule(b, reg, &m)
		if !ok {continue}
		at := len(rules)
		append(&rules, rule)
		reg.ids[.Sim_Rule][m.id] = u32(at)
		blocks := make([dynamic]Block)
		append(&blocks, ..rule.fluid.levels)
		append(&blocks, rule.fluid.falling)
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
	reg.sim.rules = rules[:]
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
	for r in reg.sim.rules {fmt.sbprintf(sb, "sim_rule %s %v %v\n", r.id, r.behaviour, r.fluid)}
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
