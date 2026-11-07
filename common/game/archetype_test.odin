package game

import "core:strings"
import "core:testing"

import "common:base"

// The archetype store against a plain model, its deferral, release, flat
// memory and hash.

@(private = "file")
Pos :: struct {
	x, y: f32,
}

@(private = "file")
Vel :: struct {
	dx: f32,
}

@(private = "file")
Tag :: struct {
	n: u32,
}

@(private = "file")
Wide :: struct {
	a, b, c: u64,
}

@(private = "file")
C_POS :: Component(0)
@(private = "file")
C_VEL :: Component(1)
@(private = "file")
C_TAG :: Component(2)
@(private = "file")
C_WIDE :: Component(3)

@(private = "file")
Released :: struct {
	count: [dynamic]int, // by Tag.n
}

@(private = "file")
release_tag :: proc(owner: rawptr, value: rawptr) {
	r := (^Released)(owner)
	n := int((^Tag)(value).n)
	for len(r.count) <= n {append(&r.count, 0)}
	r.count[n] += 1
}

@(private = "file")
infos :: proc() -> []Component_Info {
	@(static) table := [4]Component_Info{}
	table = {
		{name = "Pos", type = Pos, size = size_of(Pos), align = align_of(Pos)},
		{name = "Vel", type = Vel, size = size_of(Vel), align = align_of(Vel)},
		{
			name = "Tag",
			type = Tag,
			size = size_of(Tag),
			align = align_of(Tag),
			release = release_tag,
		},
		{name = "Wide", type = Wide, size = size_of(Wide), align = align_of(Wide)},
	}
	return table[:]
}

@(private = "file")
Model :: struct {
	set:   Component_Set,
	pos:   Pos,
	vel:   Vel,
	tag:   Tag,
	wide:  Wide,
	alive: bool,
}

@(test)
test_store_model :: proc(t: ^testing.T) {
	rel: Released
	defer delete(rel.count)
	st: Entity_Store
	testing.expect(t, store_init(&st, infos(), &rel, 1024) == nil)
	defer store_destroy(&st)
	rng := base.rng_make(50)
	model: map[Entity_Id]Model
	defer delete(model)
	order: [dynamic]Entity_Id // live ids, to pick from
	defer delete(order)
	hs: map[Entity_Id]Entity_Handle
	defer delete(hs)
	seen_max := Entity_Id(0)

	random_set :: proc(rng: ^base.Rng) -> Component_Set {
		return transmute(Component_Set)(base.rng_u32(rng) & 0b1111)
	}
	value_for :: proc(m: ^Model, c: Component, id: Entity_Id, rng: ^base.Rng) {
		n := base.rng_u32(rng)
		switch c {
		case C_POS:
			m.pos = {f32(n), f32(id)}
		case C_VEL:
			m.vel = {f32(n)}
		case C_TAG:
			m.tag = {n % 7}
		case C_WIDE:
			m.wide = {u64(n), u64(id), 3}
		}
	}

	check :: proc(t: ^testing.T, st: ^Entity_Store, model: map[Entity_Id]Model) {
		// every entity equals the model's
		live := 0
		for id, m in model {
			h, ok := store_find(st, id)
			testing.expect(t, ok)
			for c in Component(0) ..= Component(3) {
				has := int(c) in m.set
				switch c {
				case C_POS:
					p := store_get(st, h, c, Pos)
					testing.expect(t, (p != nil) == has)
					if has {testing.expect(t, p^ == m.pos)}
				case C_VEL:
					p := store_get(st, h, c, Vel)
					testing.expect(t, (p != nil) == has)
					if has {testing.expect(t, p^ == m.vel)}
				case C_TAG:
					p := store_get(st, h, c, Tag)
					testing.expect(t, (p != nil) == has)
					if has {testing.expect(t, p^ == m.tag)}
				case C_WIDE:
					p := store_get(st, h, c, Wide)
					testing.expect(t, (p != nil) == has)
					if has {testing.expect(t, p^ == m.wide)}
				}
			}
			live += 1
		}
		testing.expect_value(t, store_count(st), live)
		// queries: exactly the model's entities, archetypes in creation
		// order, rows in row order
		for all in ([]Component_Set{{}, {0}, {1, 2}, {3}}) {
			none := Component_Set{2} if all == {0} else {}
			it := store_query(st, all, none)
			n := 0
			last_arch := -1
			for a, rows in query_next(&it) {
				ai := (int(uintptr(a)) - int(uintptr(&st.archetypes[0]))) / size_of(Archetype)
				testing.expect(t, ai > last_arch)
				last_arch = ai
				ids := archetype_ids(a)
				testing.expect_value(t, len(ids), rows)
				for id in ids {
					m, ok := model[id]
					testing.expect(t, ok && all <= m.set && none & m.set == {})
					n += 1
				}
			}
			expect := 0
			for _, m in model {
				if all <= m.set && none & m.set == {} {expect += 1}
			}
			testing.expect_value(t, n, expect)
		}
	}

	for op in 0 ..< 100_000 {
		switch base.rng_int_max(&rng, 6) {
		case 0, 1:
			if len(order) >= 900 {continue}
			set := random_set(&rng)
			id, h, err := store_spawn(&st, set)
			if err != .None {continue}
			testing.expect(t, id > seen_max) // never reused
			seen_max = id
			m := Model {
				set   = set,
				alive = true,
			}
			model[id] = m
			hs[id] = h
			append(&order, id)
		case 2:
			if len(order) == 0 {continue}
			i := base.rng_int_max(&rng, len(order))
			id := order[i]
			testing.expect(t, store_despawn(&st, hs[id]) == .None)
			delete_key(&model, id)
			delete_key(&hs, id)
			order[i] = order[len(order) - 1]
			pop(&order)
		case 3:
			if len(order) == 0 {continue}
			id := order[base.rng_int_max(&rng, len(order))]
			c := Component(base.rng_int_max(&rng, 4))
			m := model[id]
			value_for(&m, c, id, &rng)
			m.set += {int(c)}
			model[id] = m
			switch c {
			case C_POS:
				store_add(&st, hs[id], c, &m.pos)
			case C_VEL:
				store_add(&st, hs[id], c, &m.vel)
			case C_TAG:
				store_add(&st, hs[id], c, &m.tag)
			case C_WIDE:
				store_add(&st, hs[id], c, &m.wide)
			}
		case 4:
			if len(order) == 0 {continue}
			id := order[base.rng_int_max(&rng, len(order))]
			c := Component(base.rng_int_max(&rng, 4))
			m := model[id]
			m.set -= {int(c)}
			model[id] = m
			store_remove(&st, hs[id], c)
		case 5:
			if base.rng_int_max(&rng, 20) == 0 {
				store_apply(&st)
				if op % 40 == 0 {check(t, &st, model)}
			}
		}
	}
	store_apply(&st)
	check(t, &st, model)
	testing.expect_value(t, st.refused, 0)
}

@(test)
test_store_deferred :: proc(t: ^testing.T) {
	st: Entity_Store
	testing.expect(t, store_init(&st, infos(), nil, 8) == nil)
	defer store_destroy(&st)

	id, h, err := store_spawn(&st, {int(C_POS)})
	testing.expect(t, err == .None)
	testing.expect(t, store_get(&st, h, C_POS, Pos) == nil) // not applied
	p := Pos{1, 2}
	testing.expect(t, store_add(&st, h, C_POS, &p) == .None)
	v := Vel{3}
	testing.expect(t, store_add(&st, h, C_VEL, &v) == .None)
	store_apply(&st)
	testing.expect(t, store_get(&st, h, C_POS, Pos)^ == p)
	testing.expect(t, store_get(&st, h, C_VEL, Vel)^ == v)
	_, found := store_find(&st, id)
	testing.expect(t, found)

	// a despawn then an add in one batch: the add is refused, not applied
	testing.expect(t, store_despawn(&st, h) == .None)
	testing.expect(t, store_add(&st, h, C_VEL, &v) == .Stale)
	testing.expect(t, store_despawn(&st, h) == .Stale)
	store_apply(&st)
	testing.expect(t, store_get(&st, h, C_POS, Pos) == nil)
	_, found = store_find(&st, id)
	testing.expect(t, !found)
	testing.expect(t, store_add(&st, h, C_VEL, &v) == .Stale) // the handle is stale

	// the ring is 2 * max: full is an error
	filled := 0
	for _ in 0 ..< 100 {
		_, _, e := store_spawn(&st, {})
		if e == .Command_Ring_Full {break}
		testing.expect(t, e == .None || e == .Pool_Full)
		if e == .Pool_Full {break}
		filled += 1
	}
	testing.expect(t, filled == 8) // the pool's capacity or the ring, whichever is first
	store_apply(&st)
	testing.expect_value(t, store_count(&st), 8)

	// a full ring is an error, never silent
	st2: Entity_Store
	testing.expect(t, store_init(&st2, infos(), nil, 2) == nil)
	defer store_destroy(&st2)
	_, h2, _ := store_spawn(&st2, {int(C_POS)})
	n := 0
	for store_add(&st2, h2, C_POS, &p) == .None {n += 1}
	testing.expect_value(t, n, 3) // 4 slots, one taken by the spawn
	testing.expect(t, store_add(&st2, h2, C_POS, &p) == .Command_Ring_Full)
}

@(test)
test_store_release :: proc(t: ^testing.T) {
	rel: Released
	defer delete(rel.count)
	st: Entity_Store
	testing.expect(t, store_init(&st, infos(), &rel, 16) == nil)

	_, a, _ := store_spawn(&st, {})
	_, b, _ := store_spawn(&st, {})
	_, c, _ := store_spawn(&st, {int(C_POS)})
	for h, i in ([]Entity_Handle{a, b, c}) {
		tag := Tag{u32(i + 1)}
		store_add(&st, h, C_TAG, &tag)
	}
	store_apply(&st)
	store_remove(&st, a, C_TAG) // tag 1 leaves
	store_apply(&st)
	testing.expect_value(t, rel.count[1], 1)
	store_despawn(&st, b) // tag 2 leaves
	store_apply(&st)
	testing.expect_value(t, rel.count[2], 1)
	store_remove(&st, a, C_TAG) // not there: no release
	store_apply(&st)
	testing.expect_value(t, rel.count[1], 1)
	store_destroy(&st) // tag 3 leaves
	testing.expect_value(t, rel.count[3], 1)
	for n in rel.count {testing.expect(t, n <= 1, "released twice")}
}

@(test)
test_store_flat_over_churn :: proc(t: ^testing.T) {
	rel: Released
	defer delete(rel.count)
	st: Entity_Store
	testing.expect(t, store_init(&st, infos(), &rel, 4096) == nil)
	defer store_destroy(&st)
	after_2 := 0
	for round in 1 ..= 20 {
		hs: [dynamic]Entity_Handle
		defer delete(hs)
		for i in 0 ..< 2000 {
			// the same sets each round, so the high-water mark is the same
			set := transmute(Component_Set)(u32(i % 8) | 1)
			_, h, err := store_spawn(&st, set)
			testing.expect(t, err == .None)
			append(&hs, h)
			if i % 500 == 499 {store_apply(&st)}
		}
		store_apply(&st)
		for h in hs {store_despawn(&st, h)}
		store_apply(&st)
		testing.expect_value(t, store_count(&st), 0)
		if round == 2 {after_2 = store_committed_bytes(&st)}
	}
	testing.expect(t, after_2 > 0)
	testing.expect_value(t, store_committed_bytes(&st), after_2)
}

@(private = "file")
build_store :: proc(st: ^Entity_Store, order: []int, perturb: bool) {
	store_init(st, infos(), nil, 64)
	for i in order {
		_, h, _ := store_spawn(st, {int(C_POS)})
		p := Pos{f32(i), 1}
		if perturb && i == 3 {p.y += 1}
		store_add(st, h, C_POS, &p)
	}
	store_apply(st)
}

@(private = "file")
hash_of :: proc(st: ^Entity_Store) -> u64 {
	h := hasher_make()
	store_hash(st, &h)
	return hasher_finish(h)
}

@(test)
test_store_hash_order :: proc(t: ^testing.T) {
	a, b, c, d: Entity_Store
	build_store(&a, {1, 2, 3, 4}, false)
	build_store(&b, {1, 2, 3, 4}, false)
	build_store(&c, {4, 3, 2, 1}, false)
	build_store(&d, {1, 2, 3, 4}, true)
	defer {store_destroy(&a); store_destroy(&b); store_destroy(&c); store_destroy(&d)}
	testing.expect_value(t, hash_of(&a), hash_of(&b))
	testing.expect(t, hash_of(&a) != hash_of(&c)) // same entities, other row order
	testing.expect(t, hash_of(&a) != hash_of(&d))

	// a perturbed value names its path
	dump :: proc(st: ^Entity_Store) -> string {
		b := strings.builder_make(context.temp_allocator)
		store_fold(st, &b, proc(k: rawptr, path: string, v: any) {
			dump_value((^strings.Builder)(k), path, v)
		})
		return strings.to_string(b)
	}
	da, dd :=
		strings.split_lines(dump(&a), context.temp_allocator),
		strings.split_lines(dump(&d), context.temp_allocator)
	testing.expect_value(t, len(da), len(dd))
	diffs := 0
	for line, i in da {
		if line != dd[i] {
			diffs += 1
			testing.expect(t, strings.contains(dd[i], "entities[archetype 0].Pos[2].y"), dd[i])
		}
	}
	testing.expect_value(t, diffs, 1)
}

// The store walks no map (docs/determinism.md): the only maps it could reach
// are the fixed tables, which are arrays here, so no `for ... in` may name a
// `map` value. The check is on the source: no map type appears at all.
@(test)
test_store_has_no_map :: proc(t: ^testing.T) {
	source := #load("archetype.odin", string)
	for line in strings.split_lines_iterator(&source) {
		code := line[:strings.index(line, "//")] if strings.contains(line, "//") else line
		testing.expect(t, !strings.contains(code, "map["), line)
	}
}

// An entity keeps the kind it was spawned with, through a structural change
// and until its despawn; no kind is 0.
@(test)
test_store_kind :: proc(t: ^testing.T) {
	st: Entity_Store
	testing.expect(t, store_init(&st, infos(), nil, 8) == nil)
	defer store_destroy(&st)

	_, a, _ := store_spawn(&st, {int(C_POS)}, Kind_Id(3))
	_, b, _ := store_spawn(&st, {int(C_POS)})
	testing.expect_value(t, store_kind(&st, a), Kind_Id(3)) // known before apply
	store_apply(&st)
	v := Vel{1}
	testing.expect(t, store_add(&st, a, C_VEL, &v) == .None)
	store_apply(&st) // the row moves to another table
	testing.expect_value(t, store_kind(&st, a), Kind_Id(3))
	testing.expect_value(t, store_kind(&st, b), Kind_Id(0))
	testing.expect(t, store_despawn(&st, a) == .None)
	store_apply(&st)
	testing.expect_value(t, store_kind(&st, a), Kind_Id(0)) // a stale handle
}

@(private = "file")
Big :: struct {
	bytes: [450]u8,
}

// A component over MAX_COMPONENT_SIZE is set at spawn, survives archetype
// moves caused by other components, and is refused by add and remove.
@(test)
test_store_large_component :: proc(t: ^testing.T) {
	testing.expect_value(t, size_of(Store_Command), 76) // the ring is unchanged
	table := [5]Component_Info{}
	copy(table[:], infos())
	table[4] = {
		name  = "Big",
		type  = Big,
		size  = size_of(Big),
		align = align_of(Big),
	}
	C_BIG :: Component(4)
	st: Entity_Store
	testing.expect(t, store_init(&st, table[:], nil, 8) == nil)
	defer store_destroy(&st)

	_, h, _ := store_spawn(&st, {int(C_POS), int(C_BIG)})
	store_apply(&st)
	big := store_get(&st, h, C_BIG, Big)
	testing.expect(t, big != nil)
	for b in big.bytes {testing.expect_value(t, b, 0)} 	// zeroed
	for i in 0 ..< len(big.bytes) {big.bytes[i] = u8(i * 7 + 1)}

	v := Vel{2}
	testing.expect(t, store_add(&st, h, C_VEL, &v) == .None)
	store_apply(&st)
	testing.expect(t, store_remove(&st, h, C_POS) == .None)
	store_apply(&st)
	testing.expect(t, store_remove(&st, h, C_VEL) == .None)
	store_apply(&st)
	big = store_get(&st, h, C_BIG, Big)
	testing.expect(t, big != nil)
	for i in 0 ..< len(big.bytes) {testing.expect_value(t, big.bytes[i], u8(i * 7 + 1))}

	other := Big{}
	testing.expect_value(t, store_add(&st, h, C_BIG, &other), Store_Error.Large_Component)
	testing.expect_value(t, store_remove(&st, h, C_BIG), Store_Error.Large_Component)
	testing.expect_value(t, st.cmd_count, 0)
}
