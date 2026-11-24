package game

import "core:math"

// Progression (the HUD's experience bar, the Character section's skills): what a
// character grows by where its game's pack has a level curve (data/levels) and a skill
// sheet (data/skills), read by registry_skills.odin. Experience comes from what the
// server sees a survivor do (Xp_Source: a creature killed, by its threat; a place found
// or a creature met for the first time; a thing made for the first time; an encounter
// won; and a quest done, by the quest's own `xp`). The curve says the experience each
// level takes, and each level gives skill points. A skill is a plain number over one rule
// the engine already has (Skill_Effect), a rank at a time at a cost in points.
//
// Every rule a skill changes reads it through one pure function, skill_value: the rule's
// value as it would be, and the character's ranks, to the value that holds. The server
// calls it where it reads the rule; where the client predicts the rule (how long a break
// takes, a reload, a shot's cone) the client calls it too, with the ranks the server sent
// (the `progress` record), so both count the same.

MAX_SKILLS :: 32 // skills a registry holds (Skill_Ranks has a place for each)
MAX_SKILL_RANKS :: 5
MAX_SKILL_COST :: 5 // points a rank may cost
MAX_LEVEL :: 100 // the highest level a curve may have
MAX_BRANCHES :: 4
SKILL_TITLE_MAX :: 32
SKILL_TEXT_MAX :: 160
BRANCH_NAME_MAX :: 24
SKILL_FACTOR_MIN :: 0.1 // a factor a skill makes is never less (a cone, a reload never vanish)

// Skill_Effect: the rule a skill changes, and how its amount adds (SKILL_EFFECTS).
Skill_Effect :: enum u8 {
	Break_Speed, // a factor on how fast a block breaks (+0.1: a tenth faster)
	Yield_Chance, // the chance a block of tier 1 or above leaves one more of its drop
	Drop_Chance, // added to the chance of each of a creature's drops
	Max_Health, // health points added to the most
	Defence, // a fraction of every harm taken off, added to what is worn (at most MAX_DEFENCE)
	Fall_Guard, // a fraction of a fall's harm taken off, added to what is worn
	Regen, // a factor on health coming back by itself
	Consume_Strength, // a factor on what a consumable heals, at once and over time
	Melee_Damage, // a factor on a swung weapon's damage
	Reload_Time, // a factor on a reload's time (-0.1: a tenth quicker)
	Spread, // a factor on a shot's cone
	Craft_Time, // a factor on a recipe's time (a game's crafting)
	Craft_Yield, // the chance a recipe made gives one more of what it makes (a game's crafting)
}

// Skill_Compose: how a skill's amount meets its rule: added to it, or a factor of one plus
// the amount (never under SKILL_FACTOR_MIN).
Skill_Compose :: enum u8 {
	Add,
	Scale,
}

Skill_Effect_Info :: struct {
	name:    string, // as data names it (a skill's `effect`)
	compose: Skill_Compose,
}

@(rodata)
SKILL_EFFECTS := [Skill_Effect]Skill_Effect_Info {
	.Break_Speed      = {"break_speed", .Scale},
	.Yield_Chance     = {"yield_chance", .Add},
	.Drop_Chance      = {"drop_chance", .Add},
	.Max_Health       = {"max_health", .Add},
	.Defence          = {"defence", .Add},
	.Fall_Guard       = {"fall_guard", .Add},
	.Regen            = {"regen", .Scale},
	.Consume_Strength = {"consume_strength", .Scale},
	.Melee_Damage     = {"melee_damage", .Scale},
	.Reload_Time      = {"reload_time", .Scale},
	.Spread           = {"spread", .Scale},
	.Craft_Time       = {"craft_time", .Scale},
	.Craft_Yield      = {"craft_yield", .Add},
}

// Skill_Def: a skill of the registry's sheet: its rule, the amount each rank adds, how
// many ranks it has and what each costs, and the points its branch must have had spent
// in it before it opens (`needs`: the deeper skills of a branch).
Skill_Def :: struct {
	id:     string,
	title:  string,
	text:   string, // a line of what it does, in the world's voice
	branch: int, // an index into Progression.branches
	effect: Skill_Effect,
	amount: f32, // what a rank adds (negative: takes away, a quicker reload)
	ranks:  int, // 1 ..= MAX_SKILL_RANKS
	cost:   int, // points a rank costs, 1 ..= MAX_SKILL_COST
	needs:  int, // points spent in its branch before it opens
}

// Xp_Source: what earns experience beside a quest done (its own `xp`) and a game's
// statistic (core.Game_Stat's `xp`).
Xp_Source :: enum u8 {
	Kill, // a creature killed: this much for each point of its threat (kind_threat)
	Meet, // a creature met for the first time (into the logbook)
	Make, // an item made for the first time (a game's crafting: core.quest_note)
	Win, // an encounter won (core.quest_note)
}

// Progression: the registry's level curve and what earns experience (data/levels); a
// registry with no curve (`levels` empty) has no experience and no skills.
Progression :: struct {
	id:           string,
	levels:       []u32, // the total experience each level from 2 takes, rising
	points:       int, // skill points each level gives
	xp:           [Xp_Source]u32,
	find:         [Logbook_Place_Kind]u32, // a place of the kind found (into the logbook)
	respec:       Block_Type, // the block a player stands near to unlearn its skills for nothing (0: anywhere)
	respec_name:  string, // ... its id, as data names it
	respec_reach: int, // ... within this many blocks
	branches:     []string, // the skill sheet's branches, in the order its skills name them
}

// Skill_Ranks: a character's rank in each skill of the registry, by its index there.
Skill_Ranks :: struct {
	ranks: [MAX_SKILLS]u8,
}

// progression_on: the registry has a level curve (experience is earned and skills learnt).
progression_on :: proc(reg: ^Registry) -> bool {
	return len(reg.progression.levels) > 0
}

// level_max: the highest level of the registry's curve (1: none).
level_max :: proc(reg: ^Registry) -> int {
	return len(reg.progression.levels) + 1
}

// level_of: the level a total of xp experience makes (1 ..= level_max).
level_of :: proc(reg: ^Registry, xp: u64) -> int {
	level := 1
	for need in reg.progression.levels {
		if xp < u64(need) {break}
		level += 1
	}
	return level
}

// level_floor: the total experience a level takes (level 1 and below: none; past the
// curve: its last).
level_floor :: proc(reg: ^Registry, level: int) -> u64 {
	levels := reg.progression.levels
	if level <= 1 || len(levels) == 0 {return 0}
	return u64(levels[min(level, len(levels) + 1) - 2])
}

// level_progress: how far xp is from its level's floor to the next's, 0 ..= 1 (1 at the
// highest level).
level_progress :: proc(reg: ^Registry, xp: u64) -> f32 {
	level := level_of(reg, xp)
	if level >= level_max(reg) {return 1}
	lo, hi := level_floor(reg, level), level_floor(reg, level + 1)
	return f32(f64(xp - lo) / f64(max(hi - lo, 1)))
}

// skill_points: the points a total of xp has given and how many of them the ranks spend.
skill_points :: proc(reg: ^Registry, xp: u64, r: ^Skill_Ranks) -> (given, spent: int) {
	given = (level_of(reg, xp) - 1) * reg.progression.points
	for &def, i in reg.skills[:min(len(reg.skills), MAX_SKILLS)] {
		spent += int(r.ranks[i]) * def.cost
	}
	return
}

// skill_spent_in: the points the ranks spend in a branch.
skill_spent_in :: proc(reg: ^Registry, r: ^Skill_Ranks, branch: int) -> (spent: int) {
	for &def, i in reg.skills[:min(len(reg.skills), MAX_SKILLS)] {
		if def.branch == branch {spent += int(r.ranks[i]) * def.cost}
	}
	return
}

// Skill_Refusal: why a rank of a skill cannot be learnt (None: it can).
Skill_Refusal :: enum u8 {
	None,
	Unknown, // no such skill
	Full, // every rank of it is learnt
	Shut, // its branch has had fewer points spent in it than it needs
	Points, // too few points left
}

// skill_can_learn: whether one more rank of skill (an index) can be learnt with xp
// experience and the ranks r has.
skill_can_learn :: proc(reg: ^Registry, r: ^Skill_Ranks, xp: u64, skill: int) -> Skill_Refusal {
	if skill < 0 || skill >= min(len(reg.skills), MAX_SKILLS) {return .Unknown}
	def := &reg.skills[skill]
	if int(r.ranks[skill]) >= def.ranks {return .Full}
	if skill_spent_in(reg, r, def.branch) < def.needs {return .Shut}
	given, spent := skill_points(reg, xp, r)
	if given - spent < def.cost {return .Points}
	return .None
}

// skill_learn: one more rank of skill, if it can be learnt (skill_can_learn).
skill_learn :: proc(reg: ^Registry, r: ^Skill_Ranks, xp: u64, skill: int) -> Skill_Refusal {
	why := skill_can_learn(reg, r, xp, skill)
	if why == .None {r.ranks[skill] += 1}
	return why
}

// skill_by_id: a skill's index in the registry by its id.
skill_by_id :: proc(reg: ^Registry, id: string) -> (int, bool) {
	at, found := reg.ids[.Skill][id]
	if !found {at, found = reg.ids[.Skill][renamed_id(reg, id)]}
	return int(at), found && int(at) < len(reg.skills)
}

// skill_amount: what the ranks add to an effect, every skill of it together.
skill_amount :: proc(reg: ^Registry, r: ^Skill_Ranks, effect: Skill_Effect) -> (total: f32) {
	if r == nil {return}
	for &def, i in reg.skills[:min(len(reg.skills), MAX_SKILLS)] {
		if def.effect == effect {total += def.amount * f32(r.ranks[i])}
	}
	return
}

// skill_value: a rule's value base as the ranks make it: the effect's amounts added to
// it, or base times one plus them (never under SKILL_FACTOR_MIN of it). The one place a
// skill changes anything; with no ranks (nil, or none learnt) it is base.
skill_value :: proc(reg: ^Registry, r: ^Skill_Ranks, effect: Skill_Effect, base: f32) -> f32 {
	amount := skill_amount(reg, r, effect)
	if amount == 0 {return base}
	switch SKILL_EFFECTS[effect].compose {
	case .Add:
		return base + amount
	case .Scale:
		return base * max(1 + amount, SKILL_FACTOR_MIN)
	}
	return base
}

// skill_weapon: a weapon as the ranks make it: its reload's time and its cone.
skill_weapon :: proc(reg: ^Registry, r: ^Skill_Ranks, w: Weapon_Info) -> Weapon_Info {
	w := w
	w.reload_time = skill_value(reg, r, .Reload_Time, w.reload_time)
	w.spread = skill_value(reg, r, .Spread, w.spread)
	return w
}

// skill_ranks_valid: every rank is within its skill's (and none for a skill the registry
// has not): what a received record must hold.
skill_ranks_valid :: proc(reg: ^Registry, r: ^Skill_Ranks) -> bool {
	for rank, i in r.ranks {
		most := reg.skills[i].ranks if i < len(reg.skills) else 0
		if int(rank) > most {return false}
	}
	return true
}

// respec_near: whether a player at p may unlearn its skills there: the registry's respec
// block within its reach of p, as query holds the blocks (anywhere when it names none).
respec_near :: proc(reg: ^Registry, query: Block_Query, p: [3]f64) -> bool {
	prog := &reg.progression
	if prog.respec == 0 {return true}
	reach := i32(prog.respec_reach)
	at := Block_Pos{i32(math.floor(p.x)), i32(math.floor(p.y)), i32(math.floor(p.z))}
	for dy in -reach ..= reach {
		for dz in -reach ..= reach {
			for dx in -reach ..= reach {
				b, loaded := query.get(query.data, at + {dx, dy, dz})
				if loaded && block_type_of(query.table, b) == prog.respec {return true}
			}
		}
	}
	return false
}

// kind_threat: how dangerous a creature of a kind is, the number its kill's experience is
// counted by and the target frame shows: its kind's `threat`, or where it names none one
// from its health and its blow (a tenth of its health and four of each point of its blow's
// damage, rounded up), 1 at least.
kind_threat :: proc(info: ^Kind_Info) -> int {
	if info == nil {return 0}
	if info.threat > 0 {return info.threat}
	damage := f64(0)
	if a, fights := info.attack.?; fights {damage = f64(a.damage)}
	return clamp(int(math.ceil((f64(info.health) + 4 * damage) / 10)), 1, MAX_THREAT)
}

MAX_THREAT :: 99
