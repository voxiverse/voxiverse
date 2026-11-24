package game

import "core:strings"
import "core:testing"

// The level curve and the skill sheet: read from data/levels and data/skills with every
// name checked, and the pure procs every rule reads them through.

LEVELS_PACK :: `{"curve": {"levels": [100, 250, 450], "points": 2,
	"xp": {"kill": 3, "make": 10, "win": 150},
	"find": {"ruin": 100},
	"respec": "voxiverse:chest", "respec_reach": 3}}`

SKILLS_PACK :: `{
	"quick": {"title": "Quick", "text": "Faster.", "branch": "Gather", "effect": "break_speed", "amount": 0.25, "ranks": 2},
	"tough": {"title": "Tough", "text": "Hardier.", "branch": "Fight", "effect": "max_health", "amount": 2, "ranks": 3},
	"deep": {"title": "Deep", "text": "Deeper.", "branch": "Gather", "effect": "break_speed", "amount": 0.5, "cost": 2, "needs": 2},
	"reload": {"title": "Reload", "text": "Quicker.", "branch": "Fight", "effect": "reload_time", "amount": -0.5, "ranks": 5}
}`

progression_registry :: proc(levels, skills: string) -> (^Registry, string) {
	files := make([dynamic]File, context.temp_allocator)
	if levels != "" {append(&files, File{"data/levels/l.json", levels})}
	if skills != "" {append(&files, File{"data/skills/s.json", skills})}
	reg, errs := build_with(pack_of("testpack", files[:]))
	return reg, errors_text(errs)
}

skill_at :: proc(reg: ^Registry, id: string) -> int {
	at, _ := skill_by_id(reg, id)
	return at
}

@(test)
test_progression_read :: proc(t: ^testing.T) {
	reg, errs := progression_registry(LEVELS_PACK, SKILLS_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	p := &reg.progression
	testing.expect(t, progression_on(reg))
	testing.expect_value(t, len(p.levels), 3)
	testing.expect_value(t, p.points, 2)
	testing.expect_value(t, p.xp[.Kill], 3)
	testing.expect_value(t, p.xp[.Meet], 0)
	testing.expect_value(t, p.xp[.Win], 150)
	testing.expect_value(t, p.find[.Ruin], 100)
	testing.expect_value(t, p.find[.Gate], 0)
	chest, _ := registry_block(reg, "voxiverse:chest")
	testing.expect_value(t, p.respec, block_type_of(&reg.blocks, chest))
	testing.expect_value(t, p.respec_reach, 3)
	testing.expect_value(t, len(reg.skills), 4)
	testing.expect_value(t, len(p.branches), 2)
	deep := &reg.skills[skill_at(reg, "testpack:deep")]
	testing.expect_value(t, p.branches[deep.branch], "Gather")
	testing.expect_value(t, deep.effect, Skill_Effect.Break_Speed)
	testing.expect_value(t, deep.cost, 2)
	testing.expect_value(t, deep.needs, 2)
	testing.expect_value(t, deep.ranks, 1)
	testing.expect_value(t, reg.skills[skill_at(reg, "testpack:reload")].amount, -0.5)
	// The registry's hash knows them.
	base, _ := build_with()
	defer registry_destroy(base)
	testing.expect(t, base.hash != reg.hash)
	testing.expect(t, !progression_on(base))
	testing.expect_value(t, level_of(base, 1_000_000), 1)
}

// Every mistake is refused with where and why.
@(test)
test_progression_refused :: proc(t: ^testing.T) {
	Case :: struct {
		levels, skills: string,
		error:          string,
	}
	cases := []Case {
		{"", SKILLS_PACK, "skills need a level curve"},
		{`{"a": {"levels": [100, 100]}}`, "", "each more than the last"},
		{`{"a": {"levels": []}}`, "", "a level curve has \"levels\""},
		{`{"a": {"levels": [10]}, "b": {"levels": [10]}}`, "", "a registry has one level curve"},
		{`{"a": {"levels": [10], "xp": {"dance": 4}}}`, "", "an xp source is one of"},
		{`{"a": {"levels": [10], "find": {"moon": 4}}}`, "", "a place is one of"},
		{`{"a": {"levels": [10], "xp": {"kill": -1}}}`, "", "experience is a whole number"},
		{
			`{"a": {"levels": [10], "respec": "voxiverse:nothing"}}`,
			"",
			"\"voxiverse:nothing\" is not a block",
		},
		{`{"a": {"levels": [10], "colour": 1}}`, "", "colour"},
		{
			LEVELS_PACK,
			`{"a": {"title": "A", "text": "x", "branch": "B", "effect": "flying", "amount": 1}}`,
			"effect is one of",
		},
		{
			LEVELS_PACK,
			`{"a": {"title": "A", "text": "x", "branch": "B", "effect": "regen", "amount": 0}}`,
			"amount is what a rank adds",
		},
		{
			LEVELS_PACK,
			`{"a": {"title": "A", "text": "x", "branch": "B", "effect": "regen"}}`,
			"a skill has an \"amount\"",
		},
		{
			LEVELS_PACK,
			`{"a": {"title": "A", "branch": "B", "effect": "regen", "amount": 1}}`,
			"a skill has a \"text\"",
		},
		{
			LEVELS_PACK,
			`{"a": {"title": "A", "text": "x", "branch": "B", "effect": "regen", "amount": 1, "ranks": 9}}`,
			"ranks is 1..5",
		},
	}
	for c in cases {
		reg, errs := progression_registry(c.levels, c.skills)
		testing.expectf(
			t,
			reg == nil && strings.contains(errs, c.error),
			"%s %s: %q",
			c.levels,
			c.skills,
			errs,
		)
		registry_destroy(reg)
	}
}

// The curve: a level for every total past its floor, the bar's fraction between two floors,
// and the highest level stays.
@(test)
test_level_curve :: proc(t: ^testing.T) {
	reg, errs := progression_registry(LEVELS_PACK, "")
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	testing.expect_value(t, level_max(reg), 4)
	testing.expect_value(t, level_of(reg, 0), 1)
	testing.expect_value(t, level_of(reg, 99), 1)
	testing.expect_value(t, level_of(reg, 100), 2)
	testing.expect_value(t, level_of(reg, 449), 3)
	testing.expect_value(t, level_of(reg, 450), 4)
	testing.expect_value(t, level_of(reg, 99_999), 4)
	testing.expect_value(t, level_floor(reg, 1), 0)
	testing.expect_value(t, level_floor(reg, 3), 250)
	testing.expect_value(t, level_floor(reg, 9), 450)
	testing.expect_value(t, level_progress(reg, 175), 0.5)
	testing.expect_value(t, level_progress(reg, 0), 0)
	testing.expect_value(t, level_progress(reg, 5000), 1)
}

// Points come with levels; a rank costs its points, opens when its branch has had its
// `needs` spent, and stops at its last; each refusal says why.
@(test)
test_skill_learning :: proc(t: ^testing.T) {
	reg, errs := progression_registry(LEVELS_PACK, SKILLS_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	quick, deep, tough :=
		skill_at(reg, "testpack:quick"),
		skill_at(reg, "testpack:deep"),
		skill_at(reg, "testpack:tough")
	r: Skill_Ranks
	testing.expect_value(t, skill_learn(reg, &r, 0, quick), Skill_Refusal.Points)
	xp := u64(250) // level 3: four points
	given, spent := skill_points(reg, xp, &r)
	testing.expect_value(t, given, 4)
	testing.expect_value(t, spent, 0)
	testing.expect_value(t, skill_learn(reg, &r, xp, deep), Skill_Refusal.Shut)
	testing.expect_value(t, skill_learn(reg, &r, xp, quick), Skill_Refusal.None)
	testing.expect_value(t, skill_learn(reg, &r, xp, quick), Skill_Refusal.None)
	testing.expect_value(t, skill_learn(reg, &r, xp, quick), Skill_Refusal.Full)
	testing.expect_value(t, skill_learn(reg, &r, xp, deep), Skill_Refusal.None) // (two spent in Gather)
	testing.expect_value(t, skill_learn(reg, &r, xp, tough), Skill_Refusal.Points)
	testing.expect_value(t, skill_learn(reg, &r, xp, 99), Skill_Refusal.Unknown)
	given, spent = skill_points(reg, xp, &r)
	testing.expect_value(t, spent, 4)
	testing.expect_value(t, skill_spent_in(reg, &r, reg.skills[quick].branch), 4)
	testing.expect(t, skill_ranks_valid(reg, &r))
	r.ranks[quick] = 3
	testing.expect(t, !skill_ranks_valid(reg, &r))
	r = {}
	r.ranks[20] = 1 // (a skill the registry has not)
	testing.expect(t, !skill_ranks_valid(reg, &r))
}

// One function from a rule's value and the ranks to the value that holds: amounts added,
// or a factor of one plus them; every skill of an effect together; none: the rule.
@(test)
test_skill_value :: proc(t: ^testing.T) {
	reg, errs := progression_registry(LEVELS_PACK, SKILLS_PACK)
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	r: Skill_Ranks
	testing.expect_value(t, skill_value(reg, nil, .Break_Speed, 2), 2)
	testing.expect_value(t, skill_value(reg, &r, .Max_Health, 20), 20)
	r.ranks[skill_at(reg, "testpack:quick")] = 2
	r.ranks[skill_at(reg, "testpack:deep")] = 1
	testing.expect_value(t, skill_value(reg, &r, .Break_Speed, 2), 4) // 2 x (1 + 0.5 + 0.5)
	r.ranks[skill_at(reg, "testpack:tough")] = 3
	testing.expect_value(t, skill_value(reg, &r, .Max_Health, 20), 26)
	testing.expect_value(t, skill_value(reg, &r, .Defence, 0.1), 0.1)
	r.ranks[skill_at(reg, "testpack:reload")] = 1
	w := Weapon_Info {
		reload_time = 2,
		spread      = 0.1,
	}
	testing.expect_value(t, skill_weapon(reg, &r, w).reload_time, 1)
	testing.expect_value(t, skill_weapon(reg, &r, w).spread, 0.1)
	r.ranks[skill_at(reg, "testpack:reload")] = 5 // (a factor never falls under its floor)
	testing.expect_value(t, skill_weapon(reg, &r, w).reload_time, 2 * SKILL_FACTOR_MIN)
}

// A kind's threat: its own, or one from its health and its blow.
@(test)
test_kind_threat :: proc(t: ^testing.T) {
	info := Kind_Info {
		health = 40,
	}
	testing.expect_value(t, kind_threat(&info), 4)
	info.attack = Kind_Attack_Info {
		damage = 7,
	}
	testing.expect_value(t, kind_threat(&info), 7) // (40 + 28) / 10, up
	info.threat = 12
	testing.expect_value(t, kind_threat(&info), 12)
	info = {
		health = 1,
	}
	testing.expect_value(t, kind_threat(&info), 1)
	testing.expect_value(t, kind_threat(nil), 0)
}

// Respec: only within reach of the curve's block.
@(test)
test_respec_near :: proc(t: ^testing.T) {
	reg, errs := progression_registry(LEVELS_PACK, "")
	testing.expect_value(t, errs, "")
	if reg == nil {return}
	defer registry_destroy(reg)
	chest, _ := registry_block(reg, "voxiverse:chest")
	One_Block :: struct {
		at:    Block_Pos,
		block: Block,
	}
	one := One_Block{{10, 5, 10}, chest}
	query := Block_Query {
		data = &one,
		get = proc(data: rawptr, p: Block_Pos) -> (Block, bool) {
			o := (^One_Block)(data)
			return o.block if p == o.at else .Air, true
		},
		table = &reg.blocks,
	}
	testing.expect(t, respec_near(reg, query, {12.5, 5, 10.5}))
	testing.expect(t, respec_near(reg, query, {7.2, 7.9, 13.9}))
	testing.expect(t, !respec_near(reg, query, {14.5, 5, 10.5}))
}
