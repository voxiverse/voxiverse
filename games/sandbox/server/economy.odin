package sandbox_server

import "base:runtime"
import "core:encoding/endian"
import "core:hash"
import "core:log"
import "core:slice"
import "core:sync"
import "core:thread"

import "common:base"
import "common:game"
import "common:planet"
import "common:starmap"
import "common:worldgen"
import "games:sandbox"
import "server:core"

// The economy of a world (docs/world.md, the economy): the sandbox holds the markets of the
// settlements near the players and steps them on the world clock, a market month being
// MONTH_DAYS world days. The towns are those the world's history implies
// (`sandbox.settlements_at`, placed on arrival and cached); towns within ECONOMY_RADIUS_KM
// of a player are in detail (`sandbox.Market`, with news and caravans:
// `sandbox.convoy_step`), all others are lazy (`sandbox.lazy_price`). A town that leaves
// every player's reach is handed back to the lazy model (`market_leave`), and priced again
// from the history function when perceived again (`market_enter`), so nothing jumps.
// Only worlds built on the planet have an economy. What the history does not give back is
// kept with the world (its file, ECONOMY_FILE).

MONTH_DAYS :: 30 // world days in a market month
ECONOMY_RADIUS_KM :: 600.0 // a town this near a player is in detail
ECONOMY_CATCH_UP :: 120 // months a resident market is stepped to catch up; more and it is entered again
ECONOMY_PRESENT :: i64(6000 * planet.DAYS_PER_YEAR) // the history's day at world day 0
ECONOMY_FILE :: "economy.vxe" // the world's file (core.World_File): sandbox.economy.vxe

@(private = "file")
ECONOMY_MAGIC :: "VXEC"
@(private = "file")
ECONOMY_VERSION :: 1
@(private = "file")
GOODS :: len(sandbox.Good)

// Sandbox_World: what the sandbox keeps of each world (core.world_state): its economy, its
// interventions log and (the home world's) its remains.
Sandbox_World :: struct {
	economy:             ^World_Economy, // the markets near the players (heap; nil until needed)
	interventions:       Intervention_Log, // what players did that the world's history carries forward (heap)
	interventions_dirty: bool, // changed since its file was staged
	remains:             Remains, // (remains.odin)
	outposts:            Outposts, // its beacons (outposts.odin)
}

world_of :: proc(w: ^core.World) -> ^Sandbox_World {return core.world_state(w, Sandbox_World)}

// Saved_Market is a town's detailed state as the file holds it.
@(private = "file")
Saved_Market :: struct {
	cell:    u32,
	stock:   [sandbox.Good]f32,
	inbound: [sandbox.Good]f32,
}

@(private = "file")
Saved_Lazy :: struct {
	cell: u32,
	dev:  [sandbox.Good]f32,
	left: f64,
}

// Saved_Economy is what a file holds, kept until the economy is built to take it.
Saved_Economy :: struct {
	key:    u64, // the placement it was made for
	month:  f64,
	market: [dynamic]Saved_Market,
	lazy:   [dynamic]Saved_Lazy,
}

saved_destroy :: proc(s: ^Saved_Economy) {
	delete(s.market)
	delete(s.lazy)
	s^ = {}
}

World_Economy :: struct {
	cache:     planet.Settlement_Cache,
	key:       u64, // the placement the economy was built for
	built:     bool,
	economy:   sandbox.Economy,
	kernel:    sandbox.Kernel,
	mem:       []sandbox.Lazy_State,
	market:    sandbox.Market,
	resident:  bool, // `market` holds towns
	news:      sandbox.News,
	convoy:    sandbox.Convoy,
	droughts:  [dynamic]sandbox.Drought, // none yet: no system causes one
	pending:   Saved_Economy, // read from the file, not yet applied
	has_saved: bool,
	dirty:     bool,
	// Building it takes seconds (the history to today, its settlements and roads,
	// the economy and its kernel): a thread of its own does it, the tick goes on.
	job:       ^thread.Thread,
	job_done:  bool, // (atomic) the job's results are in `next`
	next:      Economy_Job,
	alloc:     runtime.Allocator, // what the builds allocate with (their history, settlements, economy): what frees them
	decade:    i64, // the history's decade the economy was built for
	ivn:       int, // and its number of interventions
}

// Economy_Job: what an economy build is given and what it makes.
Economy_Job :: struct {
	address, seed: u64,
	day, decade:   i64,
	interventions: []planet.Intervention, // (the job's own copy)
	allocator:     runtime.Allocator, // the world's: what frees the economy later
	economy:       sandbox.Economy,
	kernel:        sandbox.Kernel,
}

// economy_job builds the economy for we.next (on its own thread, or inline on a
// stepped server).
@(private = "file")
economy_job :: proc(data: rawptr) {
	we := (^World_Economy)(data)
	j := &we.next
	context.allocator = we.alloc // (the cache's history and the economy: freed with it)
	p := worldgen.planet_model()
	list := planet.settlements_at(&we.cache, p, j.address, j.seed, j.day, j.interventions)
	roads := planet.roads_at(&we.cache, p, j.address, j.seed, j.day, j.interventions)
	j.economy = sandbox.economy_build(p, list, roads, j.allocator)
	j.kernel = sandbox.kernel_measure(j.economy)
	sync.atomic_store(&we.job_done, true)
}

@(private = "file")
economy_job_thread :: proc(t: ^thread.Thread) {
	base.thread_register("economy")
	defer base.thread_unregister()
	economy_job(t.data)
	runtime.default_temp_allocator_destroy(&runtime.global_default_temp_allocator_data)
}

// economy_install takes a finished build in place of the economy before it.
@(private = "file")
economy_install :: proc(we: ^World_Economy) {
	if we.job != nil {
		thread.join(we.job)
		thread.destroy(we.job)
		we.job = nil
	}
	if we.built {
		economy_drop(we)
		we.dirty = true
	}
	we.economy, we.kernel = we.next.economy, we.next.kernel
	we.mem = make([]sandbox.Lazy_State, len(we.economy.towns), we.alloc)
	we.key, we.decade, we.ivn, we.built =
		we.cache.key, we.next.decade, len(we.next.interventions), true
	delete(we.next.interventions, we.next.allocator)
	we.next = {}
	sync.atomic_store(&we.job_done, false)
}

// economy_free frees a world's economy (its build under way waited for first).
economy_free :: proc(sw: ^Sandbox_World) {
	we := sw.economy
	if we == nil {return}
	if we.job != nil {economy_install(we)} 	// (a build under way: wait for it, then free it with the rest)
	economy_drop(we)
	{
		context.allocator = we.alloc if we.alloc != {} else context.allocator
		planet.settlement_cache_destroy(&we.cache)
	}
	saved_destroy(&we.pending)
	delete(we.droughts)
	free(we)
	sw.economy = nil
}

// economy_drop frees the built economy and everything held on it.
@(private = "file")
economy_drop :: proc(we: ^World_Economy) {
	if we.resident {
		sandbox.market_destroy(&we.market)
		sandbox.news_destroy(&we.news)
		sandbox.convoy_destroy(&we.convoy)
		we.resident = false
	}
	if we.built {
		context.allocator = we.alloc if we.alloc != {} else context.allocator
		sandbox.economy_destroy(&we.economy)
		delete(we.mem)
		we.mem = nil
		we.built = false
	}
}

// economy_month is the market month at a world clock (whole months).
economy_month :: proc(clock: f64) -> f64 {
	return f64(i64(clock / MONTH_DAYS))
}

// economy_observer is where a player stands on the planet, degrees.
economy_observer :: proc(c: ^core.Client) -> [2]f64 {
	lat, lon := worldgen.planet_lat_lon(i32(c.player.position.x), i32(c.player.position.z))
	return {lat, lon}
}

// economy_tick runs once a second: the economy of every planet world a player is in, and
// what each player there sees of its market.
economy_tick :: proc(s: ^core.Server) {
	if s.tick % game.TICK_RATE != 0 {return}
	for w in s.worlds {
		if w.params.planet == 0 {continue}
		observers := make([dynamic][2]f64, context.temp_allocator)
		for &c in s.clients {
			if c.state == .Playing && c.world == w {append(&observers, economy_observer(&c))}
		}
		if len(observers) == 0 && world_of(w).economy == nil {continue}
		economy_sync(s, w, observers[:])
		for &c in s.clients {
			if c.state == .Playing && c.world == w {
				trader_visit(s, w, &c)
				market_update(s, &c)
			}
		}
	}
}

// economy_interventions turns the world's log into what the history takes: a settlement
// founded at a place.
@(private = "file")
economy_interventions :: proc(sw: ^Sandbox_World) -> []planet.Intervention {
	out := make([dynamic]planet.Intervention, context.temp_allocator)
	for iv in sw.interventions.list {
		if iv.kind != .Founded_Settlement {continue}
		lat, lon := worldgen.planet_lat_lon(iv.place.x, iv.place.z)
		append(
			&out,
			planet.Intervention {
				day = ECONOMY_PRESENT + i64(iv.day),
				lat = lat,
				lon = lon,
				kind = planet.INTERVENTION_SETTLEMENT,
			},
		)
	}
	return out[:]
}

// economy_sync brings the world's economy up to date: the towns near the observers are in
// detail, stepped to the world clock's month; the rest are lazy.
economy_sync :: proc(s: ^core.Server, w: ^core.World, observers: [][2]f64) {
	if w.params.planet == 0 {return}
	sw := world_of(w)
	if sw.economy == nil {sw.economy = new(World_Economy)}
	we := sw.economy
	if we.job != nil && sync.atomic_load(&we.job_done) {economy_install(we)}
	day := ECONOMY_PRESENT + i64(w.clock)
	decade := day / (10 * planet.DAYS_PER_YEAR)
	ivs := economy_interventions(sw)
	if we.job == nil && (!we.built || decade != we.decade || len(ivs) != we.ivn) {
		// The history changed (a new decade, an intervention) or there is none yet:
		// build again. Until the new one is in, the old one (if any) serves.
		// A build on a thread allocates from the heap (the main thread's allocator
		// may be a tracking one, for this thread alone); in the tick, the world's.
		// Everything a build makes is allocated and freed with we.alloc.
		if we.alloc == {} {
			we.alloc = context.allocator if s.config.stepped else runtime.heap_allocator()
		}
		we.next = Economy_Job {
			address       = starmap.address_hash(w.address),
			seed          = u64(w.seed),
			day           = day,
			decade        = decade,
			interventions = slice.clone(ivs, we.alloc),
			allocator     = we.alloc,
		}
		if s.config.stepped {
			economy_job(we) // (a stepped server stays deterministic: built in the tick)
			economy_install(we)
		} else {
			we.job = thread.create(economy_job_thread)
			we.job.data = we
			we.job.init_context = base.thread_context()
			thread.start(we.job)
		}
	}
	if !we.built {return} 	// (the first build is under way: no market yet)
	if len(observers) == 0 && !we.resident {return}
	month := economy_month(w.clock)
	if we.has_saved {
		economy_apply_saved(we)
		we.has_saved = false
	}
	if we.resident && month - we.market.month > ECONOMY_CATCH_UP {
		economy_leave(we)
	}

	// The towns to hold in detail.
	want := make([dynamic]int, context.temp_allocator)
	for t, i in we.economy.towns {
		for o in observers {
			if sandbox.km_between(t.lat, t.lon, f32(o.x), f32(o.y)) < ECONOMY_RADIUS_KM {
				append(&want, i)
				break
			}
		}
	}
	if !we.resident || !slice.equal(want[:], we.market.town) {
		economy_hold(we, want[:], month)
	}
	for we.resident && we.market.month < month {
		sandbox.convoy_step(we.economy, &we.market, we.news, &we.convoy, we.droughts[:])
		we.dirty = true
	}
}

// economy_leave hands the detailed towns back to the lazy model.
@(private = "file")
economy_leave :: proc(we: ^World_Economy) {
	if !we.resident {return}
	sandbox.market_leave(we.economy, we.kernel, we.market, we.mem, we.droughts[:])
	sandbox.market_destroy(&we.market)
	sandbox.news_destroy(&we.news)
	sandbox.convoy_destroy(&we.convoy)
	we.resident = false
	we.dirty = true
}

// economy_hold makes `towns` the detailed ones at a month: the towns that stay keep their
// stocks, those that leave go to the lazy model, those that come are priced from it.
@(private = "file")
economy_hold :: proc(we: ^World_Economy, towns: []int, month: f64) {
	old := we.market
	was := we.resident
	if was {
		sandbox.market_leave(we.economy, we.kernel, old, we.mem, we.droughts[:])
		sandbox.news_destroy(&we.news)
		sandbox.convoy_destroy(&we.convoy)
		we.resident = false
	}
	if len(towns) == 0 {
		if was {sandbox.market_destroy(&old)}
		we.dirty = true
		return
	}
	at := old.month if was else month
	m := sandbox.market_make(we.economy, towns, at)
	sandbox.market_enter(we.economy, we.kernel, &m, we.mem, we.droughts[:])
	if was {
		for ti, i in m.town {
			if j := old.local[ti]; j >= 0 {
				m.stock[i], m.inbound[i] = old.stock[j], old.inbound[j]
			}
		}
		sandbox.market_destroy(&old)
	}
	we.market = m
	we.news = sandbox.news_make(we.economy, we.market)
	we.resident = true
	we.dirty = true
}

// economy_apply_saved restores the market and the memories a file held, when it was made for
// this placement; otherwise they are recomputed from the history.
@(private = "file")
economy_apply_saved :: proc(we: ^World_Economy) {
	s := &we.pending
	defer saved_destroy(s)
	if s.key != we.key {return}
	by_cell := make(map[u32]int, len(we.economy.towns), context.temp_allocator)
	for t, i in we.economy.towns {by_cell[u32(t.cell)] = i}
	for l in s.lazy {
		if i, ok := by_cell[l.cell]; ok {
			we.mem[i] = sandbox.Lazy_State {
				dev  = l.dev,
				left = l.left,
			}
		}
	}
	towns := make([dynamic]int, context.temp_allocator)
	for m in s.market {
		if i, ok := by_cell[m.cell]; ok {append(&towns, i)}
	}
	if len(towns) == 0 {return}
	slice.sort(towns[:])
	m := sandbox.market_make(we.economy, towns[:], s.month)
	sandbox.market_enter(we.economy, we.kernel, &m, we.mem, we.droughts[:])
	for sm in s.market {
		i, ok := by_cell[sm.cell]
		if !ok {continue}
		j := m.local[i]
		m.stock[j], m.inbound[j] = sm.stock, sm.inbound
	}
	we.market = m
	we.news = sandbox.news_make(we.economy, we.market)
	we.resident = true
}

// economy_price is a town's price now, by its index in the economy: the detailed one where it
// is in detail, else the lazy one (0 where it has no market).
economy_price :: proc(w: ^core.World, town: int, g: sandbox.Good) -> f32 {
	we := world_of(w).economy
	if we == nil || !we.built {return 0}
	if we.resident {
		if i := we.market.local[town]; i >= 0 {
			return sandbox.market_price(we.economy, we.market, i, g)
		}
	}
	month := economy_month(w.clock)
	return sandbox.lazy_price(we.economy, we.kernel, we.mem[town], town, g, month, we.droughts[:])
}

// ---- the file ----

@(private = "file")
ENTRY_MARKET :: 4 + 2 * 4 * GOODS
@(private = "file")
ENTRY_LAZY :: 4 + 4 * GOODS + 8
@(private = "file")
ECONOMY_HEADER :: 4 + 4 + 8 + 8 + 4 + 4

// economy_encode: "VXEC", u32 version, u64 placement key, f64 month, u32 market count, u32
// lazy count, the market towns (cell u32, stock and inbound per good as f32), the lazy
// memories (cell u32, dev per good as f32, left f64), the CRC-32 of all before it.
economy_encode :: proc(we: ^World_Economy, allocator := context.allocator) -> []u8 {
	nm := len(we.market.town) if we.resident else 0
	lazy := make([dynamic]int, context.temp_allocator)
	for m, i in we.mem {
		if m.left != 0 || m.dev != {} {append(&lazy, i)}
	}
	size := ECONOMY_HEADER + nm * ENTRY_MARKET + len(lazy) * ENTRY_LAZY + 4
	out := make([]u8, size, allocator)
	copy(out, ECONOMY_MAGIC)
	endian.put_u32(out[4:], .Little, ECONOMY_VERSION)
	endian.put_u64(out[8:], .Little, we.key)
	endian.put_f64(out[16:], .Little, we.market.month if we.resident else 0)
	endian.put_u32(out[24:], .Little, u32(nm))
	endian.put_u32(out[28:], .Little, u32(len(lazy)))
	at := ECONOMY_HEADER
	if we.resident {
		for ti, i in we.market.town {
			endian.put_u32(out[at:], .Little, u32(we.economy.towns[ti].cell))
			at += 4
			for g in sandbox.Good {
				endian.put_f32(out[at:], .Little, we.market.stock[i][g])
				endian.put_f32(out[at + 4 * GOODS:], .Little, we.market.inbound[i][g])
				at += 4
			}
			at += 4 * GOODS
		}
	}
	for i in lazy {
		endian.put_u32(out[at:], .Little, u32(we.economy.towns[i].cell))
		at += 4
		for g in sandbox.Good {
			endian.put_f32(out[at:], .Little, we.mem[i].dev[g])
			at += 4
		}
		endian.put_f64(out[at:], .Little, we.mem[i].left)
		at += 8
	}
	endian.put_u32(out[at:], .Little, hash.crc32(out[:at]))
	return out
}

// economy_decode reads a file; ok is false for anything damaged (magic, version, CRC, a
// length that does not match the counts, a non-finite or negative number).
economy_decode :: proc(data: []u8) -> (s: Saved_Economy, ok: bool) {
	if len(data) < ECONOMY_HEADER + 4 || string(data[:4]) != ECONOMY_MAGIC {return}
	version, _ := endian.get_u32(data[4:], .Little)
	if version != ECONOMY_VERSION {return}
	end := len(data) - 4
	crc, _ := endian.get_u32(data[end:], .Little)
	if crc != hash.crc32(data[:end]) {return}
	s.key, _ = endian.get_u64(data[8:], .Little)
	s.month, _ = endian.get_f64(data[16:], .Little)
	nm, _ := endian.get_u32(data[24:], .Little)
	nl, _ := endian.get_u32(data[28:], .Little)
	defer if !ok {saved_destroy(&s)}
	if !(s.month >= 0 && s.month <= game.MAX_WORLD_TIME) {return}
	if u64(nm) * ENTRY_MARKET + u64(nl) * ENTRY_LAZY + ECONOMY_HEADER != u64(end) {return}
	sane :: proc(v: f32) -> bool {return v >= 0 && v < 1e6}
	at := ECONOMY_HEADER
	for _ in 0 ..< nm {
		e: Saved_Market
		e.cell, _ = endian.get_u32(data[at:], .Little)
		at += 4
		for g in sandbox.Good {
			e.stock[g], _ = endian.get_f32(data[at:], .Little)
			e.inbound[g], _ = endian.get_f32(data[at + 4 * GOODS:], .Little)
			if !sane(e.stock[g]) || !sane(e.inbound[g]) {return}
			at += 4
		}
		at += 4 * GOODS
		append(&s.market, e)
	}
	for _ in 0 ..< nl {
		e: Saved_Lazy
		e.cell, _ = endian.get_u32(data[at:], .Little)
		at += 4
		for g in sandbox.Good {
			d, _ := endian.get_f32(data[at:], .Little)
			if !(d > -1 && d < 1e6) {return}
			e.dev[g] = d
			at += 4
		}
		e.left, _ = endian.get_f64(data[at:], .Little)
		at += 8
		if !(e.left >= 0 && e.left <= game.MAX_WORLD_TIME) {return}
		append(&s.lazy, e)
	}
	return s, true
}

// economy_write stages the world's file (its save hook calls it when the economy changed).
economy_write :: proc(w: ^core.World) {
	we := world_of(w).economy
	if we == nil || !we.built || !we.dirty {return}
	we.dirty = !core.world_file_write(w, ECONOMY_FILE, economy_encode(we, context.temp_allocator))
}

// economy_load reads the world's file as it opens; it is applied when the economy is first
// built. A damaged file is moved aside and the economy starts from the history.
economy_load :: proc(w: ^core.World) {
	if w.params.planet == 0 {return}
	data, found := core.world_file_read(w, ECONOMY_FILE)
	if !found {return}
	s, ok := economy_decode(data)
	if !ok {
		core.world_file_aside(w, ECONOMY_FILE)
		return
	}
	sw := world_of(w)
	sw.economy = new(World_Economy)
	sw.economy.pending, sw.economy.has_saved = s, true
	log.infof("sandbox economy file read towns=%d memories=%d", len(s.market), len(s.lazy))
}

// economy_check: is the file whole? (--check: core.World_File.check)
economy_check :: proc(data: []u8) -> bool {
	s, ok := economy_decode(data)
	if ok {saved_destroy(&s)}
	return ok
}
