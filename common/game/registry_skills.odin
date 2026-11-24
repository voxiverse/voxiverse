package game

import "core:fmt"

// The level curve and the skill sheet in the registry (skill.odin).
//
// data/levels/<name>.json, one object, the curve and what earns experience (a registry
// has one at most):
//
//	{"survivor": {"levels": [100, 250, 450], "points": 1,
//	              "xp": {"kill": 3, "meet": 5, "make": 10, "win": 150},
//	              "find": {"ruin": 100, "remains": 30},
//	              "respec": "sandbox:outpost_beacon", "respec_reach": 6}}
//
// `levels` is the total experience each level from 2 takes, rising (so the highest level
// is one more than its count); `points` the skill points a level gives (1 when none);
// `xp` what each Xp_Source earns (kill: for each point of the creature's threat), `find`
// what a logbook place of each kind found earns; `respec` the block a player stands within
// `respec_reach` blocks of to unlearn its skills (none: anywhere).
//
// data/skills/<name>.json, one object a skill:
//
//	{"quick_hands": {"title": "Quick Hands", "text": "...", "branch": "Survival",
//	                 "effect": "break_speed", "amount": 0.1, "ranks": 3, "cost": 1, "needs": 0}}
//
// `effect` names the rule (SKILL_EFFECTS), `amount` what a rank adds to it, `ranks` how many
// (1 when none), `cost` the points a rank costs (1 when none), `needs` the points its
// branch must have had spent in it first (0 when none). The branches are the skills'
// `branch` names, in the order they first come. Skills need a level curve.

@(private)
SKILL_FIELDS := []string {
	"title",
	"text",
	"branch",
	"effect",
	"amount",
	"ranks",
	"cost",
	"needs",
	"override",
}
@(private)
LEVEL_FIELDS := []string{"levels", "points", "xp", "find", "respec", "respec_reach", "override"}
@(private)
XP_NAMES := []string{"kill", "meet", "make", "win"} // (by Xp_Source)

MAX_XP :: 100_000 // the most one deed earns

// read_progression: the level curve (after the blocks its respec names), then the skills.
@(private)
read_progression :: proc(b: ^Reg_Build, reg: ^Registry) {
	levels := b.defs[.Level][:]
	if len(levels) > 1 {
		m := &levels[1]
		fail(b, m.pack, m.file, m.line, m.column, "a registry has one level curve (data/levels)")
		return
	}
	if len(levels) == 1 {reg.progression = read_levels(b, reg, &levels[0])}
	skills := b.defs[.Skill][:]
	if len(skills) == 0 {return}
	if len(levels) == 0 {
		m := &skills[0]
		fail(b, m.pack, m.file, m.line, m.column, "skills need a level curve (data/levels)")
		return
	}
	if len(skills) > MAX_SKILLS {
		fail(b, -1, "", 0, 0, fmt.aprintf("%d skills; the limit is %d", len(skills), MAX_SKILLS))
		return
	}
	for text, at in b.index[.Skill] {reg.ids[.Skill][text] = u32(at)}
	branches := make([dynamic]string)
	reg.skills = make([]Skill_Def, len(skills))
	for &m, i in skills {reg.skills[i] = read_skill(b, &m, &branches)}
	reg.progression.branches = branches[:]
}

@(private = "file")
read_levels :: proc(b: ^Reg_Build, reg: ^Registry, m: ^Merged_Def) -> (p: Progression) {
	p.id = m.id
	f := field_of(m, "levels")
	if f == nil ||
	   f.value.kind != .Array ||
	   len(f.value.items) < 1 ||
	   len(f.value.items) >= MAX_LEVEL {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			fmt.aprintf(
				"a level curve has \"levels\", 1 to %d totals of experience, rising",
				MAX_LEVEL - 1,
			),
		)
		return
	}
	levels := make([dynamic]u32)
	for e in f.value.items {
		last := levels[len(levels) - 1] if len(levels) > 0 else 0
		if e.kind != .Int || e.i <= i64(last) || e.i > 1_000_000_000 {
			fail_field(b, f, e, "levels are whole totals of experience, each more than the last")
			continue
		}
		append(&levels, u32(e.i))
	}
	p.levels = levels[:]
	p.points = rd_int(b, m, "points", 1, 0, 10)
	if xf := field_of(m, "xp"); xf != nil {
		if xf.value.kind != .Object {
			fail_field(
				b,
				xf,
				xf.value,
				"xp is {\"kill\": ..., \"meet\": ..., \"make\": ..., \"win\": ...}",
			)
		}
		for e in xf.value.members {
			at := choice_of(
				b,
				xf,
				{kind = .String, s = e.key, line = e.key_line, column = e.key_column},
				"an xp source",
				XP_NAMES,
				-1,
			)
			if at < 0 {continue}
			p.xp[Xp_Source(at)] = xp_amount(b, xf, e.value)
		}
	}
	if ff := field_of(m, "find"); ff != nil {
		if ff.value.kind != .Object {
			fail_field(
				b,
				ff,
				ff.value,
				"find is {\"<a logbook place's kind>\": <experience>, ...}",
			)
		}
		for e in ff.value.members {
			at := choice_of(
				b,
				ff,
				{kind = .String, s = e.key, line = e.key_line, column = e.key_column},
				"a place",
				PLACE_NAMES,
				-1,
			)
			if at < 0 {continue}
			p.find[Logbook_Place_Kind(at)] = xp_amount(b, ff, e.value)
		}
	}
	if rf := field_of(m, "respec"); rf != nil {
		if rf.value.kind != .String {
			fail_field(b, rf, rf.value, "respec is a block id")
		} else if at, known := registry_block(reg, rf.value.s); known {
			p.respec = block_type_of(&reg.blocks, at)
		} else {
			fail_field(b, rf, rf.value, fmt.aprintf("\"%s\" is not a block", rf.value.s))
		}
	}
	p.respec_reach = rd_int(b, m, "respec_reach", 5, 1, 16)
	return
}

@(private = "file")
xp_amount :: proc(b: ^Reg_Build, f: ^Def_Field, v: Json_Value) -> u32 {
	if v.kind != .Int || v.i < 0 || v.i > MAX_XP {
		fail_field(b, f, v, fmt.aprintf("experience is a whole number 0..%d", MAX_XP))
		return 0
	}
	return u32(v.i)
}

@(private = "file")
read_skill :: proc(b: ^Reg_Build, m: ^Merged_Def, branches: ^[dynamic]string) -> (s: Skill_Def) {
	s.id = m.id
	s.title = skill_text(b, m, "title", SKILL_TITLE_MAX, true)
	s.text = skill_text(b, m, "text", SKILL_TEXT_MAX, true)
	if branch := skill_text(b, m, "branch", BRANCH_NAME_MAX, true); branch != "" {
		s.branch = -1
		for name, i in branches {if name == branch {s.branch = i}}
		if s.branch < 0 {
			if len(branches) == MAX_BRANCHES {
				fail(
					b,
					m.pack,
					m.file,
					m.line,
					m.column,
					fmt.aprintf("a skill sheet has at most %d branches", MAX_BRANCHES),
				)
				s.branch = 0
			} else {
				s.branch = len(branches)
				append(branches, branch)
			}
		}
	}
	names: [len(Skill_Effect)]string
	for info, e in SKILL_EFFECTS {names[int(e)] = info.name}
	if f := field_of(m, "effect"); f != nil {
		s.effect = Skill_Effect(choice_of(b, f, f.value, "effect", names[:], 0))
	} else {
		fail(
			b,
			m.pack,
			m.file,
			m.line,
			m.column,
			"a skill names its \"effect\", the rule it changes",
		)
	}
	if f := field_of(m, "amount"); f != nil {
		x, ok := json_number(f.value)
		if !ok || x == 0 || x < -10 || x > 100 {
			fail_field(b, f, f.value, "amount is what a rank adds, a number -10..100, not 0")
		} else {
			s.amount = f32(x)
		}
	} else {
		fail(b, m.pack, m.file, m.line, m.column, "a skill has an \"amount\", what a rank adds")
	}
	s.ranks = rd_int(b, m, "ranks", 1, 1, MAX_SKILL_RANKS)
	s.cost = rd_int(b, m, "cost", 1, 1, MAX_SKILL_COST)
	s.needs = rd_int(b, m, "needs", 0, 0, MAX_SKILLS * MAX_SKILL_RANKS * MAX_SKILL_COST)
	return
}

@(private = "file")
skill_text :: proc(
	b: ^Reg_Build,
	m: ^Merged_Def,
	name: string,
	most: int,
	needed: bool,
) -> string {
	f := field_of(m, name)
	if f == nil {
		if needed {fail(b, m.pack, m.file, m.line, m.column, fmt.aprintf("a skill has a \"%s\"", name))}
		return ""
	}
	if f.value.kind != .String || f.value.s == "" || len(f.value.s) > most {
		fail_field(b, f, f.value, fmt.aprintf("%s is 1 to %d bytes", name, most))
		return ""
	}
	return f.value.s
}
