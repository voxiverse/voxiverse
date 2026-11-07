package game

import "core:fmt"
import "core:slice"
import "core:strings"

// Entity kinds in the registry: data/entities/<name>.json,
//
//	{"sheep": {"box": [0.8, 0.9], "health": 4, "saved": true, "summonable": true,
//	           "hittable": true, "physics": "walker",
//	           "walker": {"walk_speed": 1.4, "run_speed": 4.2, "jump": 1.2, "step": 0},
//	           "brain": "grazer", "with": ["wool", "genes", "breeding"],
//	           "looks": ["shorn", "lamb"], "model": "sheep", "spawn": {...}}}
//
// A kind is a Kind_Id (its index in the registry's kinds, plus one: 0 is "none"). The server's
// entities and the client's others hold one; `reg.engine` names the ones the engine's code
// acts on.

// Kind_Id: an entity kind, the registry index + 1; 0 is none (and "any" in a filter).
Kind_Id :: distinct u16

MAX_KIND_LOOKS :: 16
MAX_KIND_FIELDS :: 8

Entity_Physics :: enum u8 {
	None,
	Walker, // body_step: wish, jump, collide_move with the kind's step
	Item, // no wish; horizontal velocity zeroed on the ground
	Projectile, // cast_box against blocks, spatial_cast against hittable entities
}
ENTITY_PHYSICS_LIST := [?]string{"none", "walker", "item", "projectile"}
#assert(len(ENTITY_PHYSICS_LIST) == len(Entity_Physics))

Entity_Brain :: enum u8 {
	None,
	Grazer, // today's sheep: think, steer, graze, flee, mate
}
ENTITY_BRAIN_LIST := [?]string{"none", "grazer"}
#assert(len(ENTITY_BRAIN_LIST) == len(Entity_Brain))

// Entity_Part: an optional component a kind asks for with "with".
Entity_Part :: enum u8 {
	Wool,
	Genes,
	Breeding,
}
Entity_Parts :: bit_set[Entity_Part;u8]
ENTITY_PART_LIST := [?]string{"wool", "genes", "breeding"}
#assert(len(ENTITY_PART_LIST) == len(Entity_Part))

// Entity_Look: something the client draws by, computed by the engine from components.
Entity_Look :: enum u8 {
	Shorn, // Wool
	Lamb, // Breeding
	Black, // Genes
	Spotted, // Genes
	In_Love, // Breeding
}
ENTITY_LOOK_LIST := [?]string{"shorn", "lamb", "black", "spotted", "in_love"}
#assert(len(ENTITY_LOOK_LIST) == len(Entity_Look))

// entity_look_part: the component a look is computed from.
entity_look_part :: proc(l: Entity_Look) -> Entity_Part {
	switch l {
	case .Shorn:
		return .Wool
	case .Lamb, .In_Love:
		return .Breeding
	case .Black, .Spotted:
		return .Genes
	}
	return .Wool
}

Entity_Model :: enum u8 {
	Sheep,
	Rocket,
	Item,
	Player,
	Box, // a box the kind's size in Kind_Info.color
}
ENTITY_MODEL_LIST := [?]string{"sheep", "rocket", "item", "player"}

Kind_Field_Type :: enum u8 {
	U8,
	U16,
}

// Kind_Field: one of a kind's saved, unreplicated numbers (the Fields component).
Kind_Field :: struct {
	name:     string,
	type:     Kind_Field_Type,
	min, max: u16,
}

Kind_Walker_Info :: struct {
	walk_speed: f32, // blocks/s
	run_speed:  f32, // fleeing
	jump:       f32, // blocks it can jump up
	step:       f32, // blocks it climbs without jumping
}

Kind_Projectile_Info :: struct {
	speed:   f32, // blocks/s
	gravity: f32, // blocks/s²
	life:    f32, // seconds: then it goes off where it is
	explode: int, // blocks carved
}

Kind_Item_Info :: struct {
	pickup_delay: f32, // seconds before a stack can be picked up
	owner_delay:  f32, // seconds before its dropper can
	range:        f32, // blocks from a player's feet
	merge:        f32, // blocks: stacks of one item this near become one
	life:         f32, // seconds
	throw:        f32, // blocks/s: a stack a player drops flies ahead
}

// Kind_Spawn_Rule: natural spawning, today's rule (server/core/spawn.odin) as data.
Kind_Spawn_Rule :: struct {
	on:       Matcher, // the block the spawn stands on
	on_text:  string,
	day:      [2]f32, // the fractions of the day it spawns between
	every:    int, // ticks
	chance:   f32, // a draw above it skips
	cap:      int, // entities near the player before it stops
	within:   int, // blocks, horizontally, the cap counts over
	distance: [2]f32, // from the player
	group:    [2]int, // size, inclusive
}

Kind_Info :: struct {
	id:         string,
	box:        [2]f32, // width (x and z), height
	health:     int,
	saved:      bool, // kept with the world
	summonable: bool, // `/summon` makes one
	hittable:   bool, // players, rockets and explosions hit it
	physics:    Entity_Physics,
	walker:     Kind_Walker_Info,
	projectile: Kind_Projectile_Info,
	item:       Kind_Item_Info,
	brain:      Entity_Brain,
	with:       Entity_Parts,
	looks:      []Entity_Look, // look i is bit i of a replicated entity's looks
	fields:     []Kind_Field,
	model:      Entity_Model,
	color:      [3]u8, // model Box
	spawn:      Maybe(Kind_Spawn_Rule),
}

// Engine_Kinds: the base pack's kinds the engine's code acts on by name (the sheep's
// brain, the rocket launcher, dropped stacks); 0 where a registry has no such kind.
Engine_Kinds :: struct {
	sheep, rocket, item, player: Kind_Id,
}

registry_kind :: proc(reg: ^Registry, text: string) -> (Kind_Id, bool) {
	id, ok := id_parse(text)
	if !ok {return 0, false}
	full := strings.concatenate({id.namespace, ":", id.name}, context.temp_allocator)
	at, found := reg.ids[.Entity][full]
	return Kind_Id(at + 1), found
}

// kind_name: the kind's name without its namespace ("sheep"): what a command or a
// statistic calls it.
kind_name :: proc(info: ^Kind_Info) -> string {
	if at := strings.index_byte(info.id, ':'); at >= 0 {return info.id[at + 1:]}
	return info.id
}

@(private)
kind_by_full_id :: proc(reg: ^Registry, full: string) -> Kind_Id {
	at, found := reg.ids[.Entity][full]
	return Kind_Id(at + 1) if found else 0
}

// kind_info: the kind's definition; nil for 0 or an id the registry does not have.
kind_info :: proc(reg: ^Registry, k: Kind_Id) -> ^Kind_Info {
	if k == 0 || int(k) > len(reg.kinds) {return nil}
	return &reg.kinds[int(k) - 1]
}

@(private)
ENTITY_FIELDS := []string {
	"box",
	"health",
	"saved",
	"summonable",
	"hittable",
	"physics",
	"walker",
	"projectile",
	"item",
	"brain",
	"with",
	"looks",
	"fields",
	"model",
	"spawn",
	"override",
}
@(private)
WALKER_KEYS := []string{"walk_speed", "run_speed", "jump", "step"}
@(private)
PROJECTILE_KEYS := []string{"speed", "gravity", "life", "explode"}
@(private)
ITEM_KEYS := []string{"pickup_delay", "owner_delay", "range", "merge", "life", "throw"}
@(private)
SPAWN_KEYS := []string{"on", "day", "every", "chance", "cap", "within", "distance", "group"}

@(private)
json_number :: proc(v: Json_Value) -> (f64, bool) {
	#partial switch v.kind {
	case .Int:
		return f64(v.i), true
	case .Float:
		return v.f, true
	}
	return 0, false
}

// read_numbers: the object v as numbers, one per key, each within lo..hi (the same
// bounds for every key). Keys that are not names are refused, so are missing ones.
@(private)
read_numbers :: proc(
	b: ^Reg_Build,
	f: ^Def_Field,
	v: Json_Value,
	what: string,
	names: []string,
	lo, hi: [$N]f64,
	out: ^[N]f64,
) {
	if v.kind != .Object {
		fail_field(b, f, v, fmt.aprintf("%s is an object with %s", what, join_quoted(names)))
		return
	}
	seen: [N]bool
	for m in v.members {
		at := -1
		for n, i in names {if n == m.key {at = i}}
		if at < 0 {
			fail(
				b,
				f.pack,
				f.file,
				m.key_line,
				m.key_column,
				fmt.aprintf("%s has no \"%s\"%s", what, m.key, suggestion(m.key, names)),
			)
			continue
		}
		seen[at] = true
		x, ok := json_number(m.value)
		if !ok || x < lo[at] || x > hi[at] {
			fail_field(
				b,
				f,
				m.value,
				fmt.aprintf("%s %s is a number %v..%v", what, m.key, lo[at], hi[at]),
			)
			continue
		}
		out[at] = x
	}
	for n, i in names {
		if !seen[i] {
			fail_field(b, f, v, fmt.aprintf("%s needs \"%s\"; add it", what, n))
		}
	}
}

// read_pair: [a, b] numbers within lo..hi, a <= b (a < b with strict).
@(private)
read_pair :: proc(
	b: ^Reg_Build,
	f: ^Def_Field,
	v: Json_Value,
	what: string,
	lo, hi: f64,
	whole: bool,
) -> (
	pair: [2]f64,
	ok: bool,
) {
	if v.kind == .Array && len(v.items) == 2 {
		ok = true
		for e, i in v.items {
			x, isnum := json_number(e)
			if !isnum || x < lo || x > hi || (whole && e.kind != .Int) {ok = false}
			pair[i] = x
		}
		ok &&= pair[0] <= pair[1]
	}
	if !ok {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf(
				"%s is [low, high], %s %v..%v, low not above high",
				what,
				"whole numbers" if whole else "numbers",
				lo,
				hi,
			),
		)
	}
	return
}

@(private)
read_entity_kind :: proc(b: ^Reg_Build, reg: ^Registry, m: ^Merged_Def) -> Kind_Info {
	info := Kind_Info {
		id     = m.id,
		health = 1,
	}
	need :: proc(b: ^Reg_Build, m: ^Merged_Def, what: string) {
		fail(b, m.pack, m.file, m.line, m.column, fmt.aprintf("a kind needs %s", what))
	}
	if f := field_of(m, "box"); f != nil {
		if p, ok := read_pair_exact(b, f, "box"); ok {info.box = {f32(p[0]), f32(p[1])}}
	} else {
		need(b, m, "\"box\": [width, height]")
	}
	info.health = rd_int(b, m, "health", 1, 1, 10000)
	info.saved = rd_bool(b, m, "saved", false)
	info.summonable = rd_bool(b, m, "summonable", false)
	info.hittable = rd_bool(b, m, "hittable", false)

	physics := Entity_Physics(rd_choice(b, m, "physics", ENTITY_PHYSICS_LIST[:], 0))
	info.physics = physics
	blocks := [Entity_Physics]string {
		.None       = "",
		.Walker     = "walker",
		.Item       = "item",
		.Projectile = "projectile",
	}
	for p in Entity_Physics {
		if p == .None {continue}
		f := field_of(m, blocks[p])
		switch {
		case f == nil && physics == p:
			fail(
				b,
				m.pack,
				m.file,
				m.line,
				m.column,
				fmt.aprintf(
					"physics \"%s\" needs its numbers: add \"%s\": {{%s}}",
					blocks[p],
					blocks[p],
					join_quoted(entity_physics_keys(p)),
				),
			)
		case f != nil && physics != p:
			fail(
				b,
				m.pack,
				f.file,
				f.value.line,
				f.value.column,
				fmt.aprintf(
					"\"%s\" holds the numbers of physics \"%s\", but this kind's physics is \"%s\"; set that physics or remove \"%s\"",
					blocks[p],
					blocks[p],
					ENTITY_PHYSICS_LIST[physics],
					blocks[p],
				),
			)
		case f != nil:
			switch p {
			case .None:
			case .Walker:
				o: [4]f64
				read_numbers(
					b,
					f,
					f.value,
					"walker",
					WALKER_KEYS,
					{0, 0, 0, 0},
					{32, 64, 8, 2},
					&o,
				)
				info.walker = {f32(o[0]), f32(o[1]), f32(o[2]), f32(o[3])}
			case .Projectile:
				o: [4]f64
				read_numbers(
					b,
					f,
					f.value,
					"projectile",
					PROJECTILE_KEYS,
					{0.1, 0, 0.1, 0},
					{200, 50, 600, 16},
					&o,
				)
				info.projectile = {f32(o[0]), f32(o[1]), f32(o[2]), int(o[3])}
			case .Item:
				o: [6]f64
				read_numbers(
					b,
					f,
					f.value,
					"item",
					ITEM_KEYS,
					{0, 0, 0.1, 0, 1, 0},
					{60, 60, 8, 8, 3600, 64},
					&o,
				)
				info.item = {f32(o[0]), f32(o[1]), f32(o[2]), f32(o[3]), f32(o[4]), f32(o[5])}
			}
		}
	}

	if f := field_of(m, "brain"); f != nil {
		info.brain = Entity_Brain(choice_of(b, f, f.value, "brain", ENTITY_BRAIN_LIST[:], 0))
		if info.brain == .Grazer && info.physics != .Walker {
			fail_field(b, f, f.value, "brain \"grazer\" needs physics \"walker\"")
		}
	}
	if f := field_of(m, "with"); f != nil {
		if f.value.kind != .Array {
			fail_field(b, f, f.value, "with is a list of components: wool, genes, breeding")
		} else {
			for e in f.value.items {
				if e.kind != .String {
					fail_field(b, f, e, "a component is a name such as \"wool\"")
					continue
				}
				at := slice.linear_search(ENTITY_PART_LIST[:], e.s) or_else -1
				if at < 0 {
					fail_field(
						b,
						f,
						e,
						fmt.aprintf(
							"\"%s\" is not a component a kind can have%s",
							e.s,
							suggestion(e.s, ENTITY_PART_LIST[:]),
						),
					)
					continue
				}
				info.with += {Entity_Part(at)}
			}
		}
	}
	if f := field_of(m, "looks"); f != nil {
		if f.value.kind != .Array {
			fail_field(b, f, f.value, "looks is a list of names such as \"shorn\"")
		} else if len(f.value.items) > MAX_KIND_LOOKS {
			fail_field(
				b,
				f,
				f.value,
				fmt.aprintf("%d looks; the limit is %d", len(f.value.items), MAX_KIND_LOOKS),
			)
		} else {
			looks := make([dynamic]Entity_Look)
			for e in f.value.items {
				if e.kind != .String {
					fail_field(b, f, e, "a look is a name such as \"shorn\"")
					continue
				}
				at := slice.linear_search(ENTITY_LOOK_LIST[:], e.s) or_else -1
				if at < 0 {
					fail_field(
						b,
						f,
						e,
						fmt.aprintf(
							"\"%s\" is not a look%s",
							e.s,
							suggestion(e.s, ENTITY_LOOK_LIST[:]),
						),
					)
					continue
				}
				look := Entity_Look(at)
				if entity_look_part(look) not_in info.with {
					fail_field(
						b,
						f,
						e,
						fmt.aprintf(
							"look \"%s\" is computed from \"%s\"; add it to \"with\"",
							e.s,
							ENTITY_PART_LIST[entity_look_part(look)],
						),
					)
					continue
				}
				append(&looks, look)
			}
			info.looks = looks[:]
		}
	}
	if f := field_of(m, "fields"); f != nil {
		info.fields = read_kind_fields(b, f)
	}
	if f := field_of(m, "model"); f != nil {
		read_entity_model(b, f, &info)
	} else {
		need(
			b,
			m,
			"a \"model\": one of " + `"sheep", "rocket", "item", "player" or {"box": [r, g, b]}`,
		)
	}
	if f := field_of(m, "spawn"); f != nil {
		if rule, ok := read_spawn_rule(b, reg, f); ok {info.spawn = rule}
	}
	return info
}

@(private)
entity_physics_keys :: proc(p: Entity_Physics) -> []string {
	#partial switch p {
	case .Walker:
		return WALKER_KEYS
	case .Projectile:
		return PROJECTILE_KEYS
	case .Item:
		return ITEM_KEYS
	}
	return nil
}

@(private)
read_pair_exact :: proc(b: ^Reg_Build, f: ^Def_Field, what: string) -> (pair: [2]f64, ok: bool) {
	v := f.value
	if v.kind == .Array && len(v.items) == 2 {
		ok = true
		for e, i in v.items {
			x, isnum := json_number(e)
			if !isnum || x < 0.1 || x > 4 {ok = false}
			pair[i] = x
		}
	}
	if !ok {fail_field(b, f, v, "box is [width, height], each a number 0.1..4")}
	return
}

@(private)
read_kind_fields :: proc(b: ^Reg_Build, f: ^Def_Field) -> []Kind_Field {
	v := f.value
	if v.kind != .Object {
		fail_field(b, f, v, `fields is {"name": {"type": "u8", "min": 0, "max": 10}}`)
		return nil
	}
	if len(v.members) > MAX_KIND_FIELDS {
		fail_field(
			b,
			f,
			v,
			fmt.aprintf("%d fields; the limit is %d", len(v.members), MAX_KIND_FIELDS),
		)
		return nil
	}
	out := make([dynamic]Kind_Field)
	for m in v.members {
		if !id_part_valid(m.key, 32) {
			fail(
				b,
				f.pack,
				f.file,
				m.key_line,
				m.key_column,
				fmt.aprintf("\"%s\" is not a field name; use 1 to 32 of a-z, 0-9 and _", m.key),
			)
			continue
		}
		fld := Kind_Field {
			name = m.key,
		}
		have_type, have_min, have_max := false, false, false
		lo_v, hi_v := m.value, m.value
		if m.value.kind != .Object {
			fail_field(b, f, m.value, `a field is {"type": "u8", "min": 0, "max": 10}`)
			continue
		}
		for fm in m.value.members {
			switch fm.key {
			case "type":
				if fm.value.kind == .String && (fm.value.s == "u8" || fm.value.s == "u16") {
					fld.type = .U8 if fm.value.s == "u8" else .U16
					have_type = true
				} else {
					fail_field(b, f, fm.value, "type is \"u8\" or \"u16\"")
				}
			case "min", "max":
				if fm.value.kind != .Int || fm.value.i < 0 || fm.value.i > 65535 {
					fail_field(
						b,
						f,
						fm.value,
						fmt.aprintf("%s is a whole number 0..65535", fm.key),
					)
					continue
				}
				if fm.key == "min" {
					fld.min, have_min, lo_v = u16(fm.value.i), true, fm.value
				} else {
					fld.max, have_max, hi_v = u16(fm.value.i), true, fm.value
				}
			case:
				fail(
					b,
					f.pack,
					f.file,
					fm.key_line,
					fm.key_column,
					fmt.aprintf("a field has type, min and max, not \"%s\"", fm.key),
				)
			}
		}
		if !have_type || !have_min || !have_max {
			fail_field(b, f, m.value, fmt.aprintf("field \"%s\" needs type, min and max", m.key))
			continue
		}
		if fld.type == .U8 && fld.max > 255 {
			fail_field(b, f, hi_v, "a u8 field's max is at most 255")
			continue
		}
		if fld.min > fld.max {
			fail_field(
				b,
				f,
				lo_v,
				fmt.aprintf("min %d is above max %d; swap them", fld.min, fld.max),
			)
			continue
		}
		append(&out, fld)
	}
	return out[:]
}

@(private)
read_entity_model :: proc(b: ^Reg_Build, f: ^Def_Field, info: ^Kind_Info) {
	v := f.value
	if v.kind == .String {
		at := slice.linear_search(ENTITY_MODEL_LIST[:], v.s) or_else -1
		if at < 0 {
			fail_field(
				b,
				f,
				v,
				fmt.aprintf(
					"model is one of %s or {{\"box\": [r, g, b]}}; got \"%s\"%s",
					join_quoted(ENTITY_MODEL_LIST[:]),
					v.s,
					suggestion(v.s, ENTITY_MODEL_LIST[:], false),
				),
			)
			return
		}
		info.model = Entity_Model(at)
		return
	}
	ok := v.kind == .Object && len(v.members) == 1 && v.members[0].key == "box"
	if ok {
		c := v.members[0].value
		ok = c.kind == .Array && len(c.items) == 3
		if ok {
			for e, i in c.items {
				if e.kind != .Int || e.i < 0 || e.i > 255 {ok = false; break}
				info.color[i] = u8(e.i)
			}
		}
	}
	if !ok {
		fail_field(
			b,
			f,
			v,
			`model is a name or {"box": [r, g, b]}, each colour a whole number 0..255`,
		)
		return
	}
	info.model = .Box
}

@(private)
read_spawn_rule :: proc(
	b: ^Reg_Build,
	reg: ^Registry,
	f: ^Def_Field,
) -> (
	rule: Kind_Spawn_Rule,
	ok: bool,
) {
	v := f.value
	if v.kind != .Object {
		fail_field(b, f, v, fmt.aprintf("spawn is an object with %s", join_quoted(SPAWN_KEYS)))
		return
	}
	ok = true
	seen: [8]bool
	for m in v.members {
		at := -1
		for n, i in SPAWN_KEYS {if n == m.key {at = i}}
		if at < 0 {
			fail(
				b,
				f.pack,
				f.file,
				m.key_line,
				m.key_column,
				fmt.aprintf("spawn has no \"%s\"%s", m.key, suggestion(m.key, SPAWN_KEYS)),
			)
			ok = false
			continue
		}
		seen[at] = true
		good := true
		switch m.key {
		case "on":
			if m.value.kind != .String {
				fail_field(b, f, m.value, "on is a block matcher such as \"voxiverse:grass\"")
				good = false
			} else if mt, mok := matcher_compile(reg, m.value.s); !mok {
				fail_field(
					b,
					f,
					m.value,
					fmt.aprintf(
						"\"%s\" is not a block matcher: name a block, #tag, @flag or $list that exists",
						m.value.s,
					),
				)
				good = false
			} else {
				rule.on, rule.on_text = mt, m.value.s
			}
		case "day":
			if p, pok := read_pair(b, f, m.value, "day", 0, 1, false); pok {
				rule.day = {f32(p[0]), f32(p[1])}
			} else {good = false}
		case "distance":
			if p, pok := read_pair(b, f, m.value, "distance", 1, 256, false); pok {
				rule.distance = {f32(p[0]), f32(p[1])}
			} else {good = false}
		case "group":
			if p, pok := read_pair(b, f, m.value, "group", 1, 16, true); pok {
				rule.group = {int(p[0]), int(p[1])}
			} else {good = false}
		case "chance":
			x, isnum := json_number(m.value)
			if !isnum || x < 0 || x > 1 {
				fail_field(b, f, m.value, "chance is a number 0..1")
				good = false
			} else {rule.chance = f32(x)}
		case "every", "cap", "within":
			lo, hi := 1, 256
			switch m.key {
			case "every":
				hi = 72000
			case "cap":
				hi = 64
			}
			if m.value.kind != .Int || m.value.i < i64(lo) || m.value.i > i64(hi) {
				fail_field(
					b,
					f,
					m.value,
					fmt.aprintf("%s is a whole number %d..%d", m.key, lo, hi),
				)
				good = false
			} else {
				switch m.key {
				case "every":
					rule.every = int(m.value.i)
				case "cap":
					rule.cap = int(m.value.i)
				case "within":
					rule.within = int(m.value.i)
				}
			}
		}
		ok &&= good
	}
	for n, i in SPAWN_KEYS {
		if !seen[i] {
			fail_field(b, f, v, fmt.aprintf("spawn needs \"%s\"; add it", n))
			ok = false
		}
	}
	return
}

// build_entity_kinds: the registry's kinds, in load order.
@(private)
build_entity_kinds :: proc(b: ^Reg_Build, reg: ^Registry) {
	if len(b.defs[.Entity]) > 4095 {
		fail(
			b,
			-1,
			"",
			0,
			0,
			fmt.aprintf("%d entity kinds; the limit is 4095", len(b.defs[.Entity])),
		)
		return
	}
	reg.kinds = make([]Kind_Info, len(b.defs[.Entity]))
	for &m, i in b.defs[.Entity] {
		reg.kinds[i] = read_entity_kind(b, reg, &m)
		reg.ids[.Entity][m.id] = u32(i)
	}
	reg.engine = {
		sheep  = kind_by_full_id(reg, "voxiverse:sheep"),
		rocket = kind_by_full_id(reg, "voxiverse:rocket"),
		item   = kind_by_full_id(reg, "voxiverse:item"),
		player = kind_by_full_id(reg, "voxiverse:player"),
	}
}

@(private)
entity_kinds_text :: proc(reg: ^Registry, sb: ^strings.Builder) {
	for k in reg.kinds {
		fmt.sbprintf(
			sb,
			"entity %s box=%v health=%d saved=%v summonable=%v hittable=%v physics=%v walker=%v projectile=%v item=%v brain=%v with=%v looks=%v fields=%v model=%v color=%v",
			k.id,
			k.box,
			k.health,
			k.saved,
			k.summonable,
			k.hittable,
			k.physics,
			k.walker,
			k.projectile,
			k.item,
			k.brain,
			k.with,
			k.looks,
			k.fields,
			k.model,
			k.color,
		)
		if s, has := k.spawn.?; has {
			fmt.sbprintf(
				sb,
				" spawn=%s %v %d %v %d %d %v %v",
				s.on_text,
				s.day,
				s.every,
				s.chance,
				s.cap,
				s.within,
				s.distance,
				s.group,
			)
		}
		strings.write_byte(sb, '\n')
	}
}
