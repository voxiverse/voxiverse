package screen

import "core:math"
import "core:strings"

import "client:engine"
import "client:ui"

// The title screen's holiday themes (docs/polish.md, #300): on a holiday's
// dates the splash is picked from that holiday's texts, its greeting first on
// the holiday itself; the backdrop gets a small touch (snow, bats,
// fireworks), respecting reduce motion. Both are dev-fakable with the
// console's `title_date`.

Splashes :: struct {
	all:  []string, // every text in file order (everyday first, then sections)
	sets: [engine.Holiday][]string, // .None: the everyday set; the rest their sections
}

@(private = "file")
section_eq :: proc(s, lower: string) -> bool {
	if len(s) != len(lower) {return false}
	for i in 0 ..< len(s) {
		c := s[i]
		if c >= 'A' && c <= 'Z' {c += 32}
		if c != lower[i] {return false}
	}
	return true
}

holiday_from_section :: proc(s: string) -> (holiday: engine.Holiday, ok: bool) {
	switch {
	case section_eq(s, "new_year"):
		return .New_Year, true
	case section_eq(s, "valentines"):
		return .Valentines, true
	case section_eq(s, "st_patricks"):
		return .St_Patricks, true
	case section_eq(s, "easter"):
		return .Easter, true
	case section_eq(s, "halloween"):
		return .Halloween, true
	case section_eq(s, "christmas"):
		return .Christmas, true
	}
	return .None, false
}

// splashes_parse_file: the splashes file as a struct (everyday texts, then
// one set per holiday). An unknown section name is an authoring mistake:
// its texts are skipped, not filed with the everyday set.
splashes_parse_file :: proc(text: string, allocator := context.temp_allocator) -> Splashes {
	all := make([dynamic]string, allocator)
	sets: [engine.Holiday][dynamic]string
	for h in engine.HOLIDAY_SECTIONS {
		sets[h] = make([dynamic]string, allocator)
	}
	sets[.None] = make([dynamic]string, allocator)
	current := engine.Holiday.None
	skipping := false
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		l := strings.trim_space(line)
		if l == "" || strings.has_prefix(l, "#") {continue}
		if strings.has_prefix(l, "[") && strings.has_suffix(l, "]") {
			if h, ok := holiday_from_section(l[1:len(l) - 1]); ok {
				current = h
				skipping = false
				continue
			}
			current = engine.Holiday.None
			skipping = true
			continue
		}
		if skipping {continue}
		append(&all, l)
		append(&sets[current], l)
	}
	out: Splashes
	out.all = all[:]
	out.sets[.None] = sets[.None][:]
	for h in engine.HOLIDAY_SECTIONS {
		out.sets[h] = sets[h][:]
	}
	return out
}

// splash_for: the splash for a date. On a holiday's dates the splash comes
// from its set; on the greeting day itself it is the greeting; otherwise the
// everyday set. second picks within the set (the clock the title uses).
splash_for :: proc(parsed: Splashes, year, month, day: int, second: i64) -> string {
	greeting_texts := engine.HOLIDAY_GREETING
	holiday, greeting := engine.holiday_for(year, month, day)
	if greeting {return greeting_texts[holiday]}
	set := parsed.sets[holiday] if holiday != .None else parsed.sets[.None]
	if len(set) == 0 {set = parsed.sets[.None]}
	if len(set) == 0 {return ""}
	return set[int(second % i64(len(set)))]
}

// today_holiday: which holiday it is right now (the dev override wins).
today_holiday :: proc(app: ^engine.App) -> engine.Holiday {
	y, m, d := 1970, 1, 1
	if o, ok := app.title_date_override.?;
	   ok {y, m, d = o[0], o[1], o[2]} else if ly, lm, ld, ok2 := engine.local_date_of(engine.app_wall(app)); ok2 {y, m, d = ly, lm, ld}
	holiday, _ := engine.holiday_for(y, m, d)
	return holiday
}

// ---- the backdrop fx ----

@(private = "file")
fx_random :: proc(f: ^engine.Holiday_Fx) -> f32 {
	f.random = f.random * 1664525 + 1013904223
	return f32(f.random >> 8) / f32(1 << 24)
}

@(private = "file")
holiday_fx_begin :: proc(app: ^engine.App, h: engine.Holiday) {
	f := &app.holiday_fx
	if f.random == 0 {f.random = 0x5eed}
	f.running = h
	f.next_burst = 0.4
	for i in 0 ..< engine.MAX_FLAKES {
		f.flakes[i] = {
			x      = fx_random(f),
			y      = fx_random(f),
			size   = 2 + fx_random(f) * 3,
			speed  = 26 + fx_random(f) * 38,
			amount = 10 + fx_random(f) * 22,
			phase  = fx_random(f) * 6.28,
		}
	}
	for i in 0 ..< engine.MAX_BATS {
		f.bats[i] = {
			x      = -60 - fx_random(f) * 400,
			y      = 0.08 + fx_random(f) * 0.35,
			speed  = 110 + fx_random(f) * 80,
			flap   = fx_random(f) * 6.28,
			offset = fx_random(f) * 30,
		}
	}
	for i in 0 ..< engine.MAX_BURSTS {f.bursts[i].active = false}
	// One burst is already mid-flight when the screen opens (the logo
	// reveals over something happening behind it).
	if h == .New_Year {
		burst := &f.bursts[0]
		palette := engine.FIREWORK_PALETTE
		burst.color = palette[1]
		burst.x = 0.70
		burst.y = 0.16
		burst.age = 0.30
		for j in 0 ..< engine.SPARKS_PER_BURST {
			theta := f32(j) * (2 * math.PI) / f32(engine.SPARKS_PER_BURST)
			burst.spark[j] = {math.cos(theta), math.sin(theta)}
		}
		burst.active = true
	}
}

// holiday_back: what is drawn behind the title's logo and buttons (fireworks,
// bats). The caller gates on reduce motion.
holiday_back :: proc(app: ^engine.App, ctx: ^ui.Context, h: engine.Holiday, dt: f32) {
	f := &app.holiday_fx
	if f.running != h {holiday_fx_begin(app, h)}
	if h == .None {return}
	screen := ctx.screen
	#partial switch h {
	case .New_Year:
		// A few bursts behind the logo, now and then.
		f.next_burst -= dt
		if f.next_burst <= 0 {
			palette := engine.FIREWORK_PALETTE
			for i in 0 ..< engine.MAX_BURSTS {
				burst := &f.bursts[i]
				if burst.active {continue}
				burst.color = palette[int(fx_random(f) * len(palette)) % len(palette)]
				burst.x = 0.18 + fx_random(f) * 0.64
				burst.y = 0.10 + fx_random(f) * 0.30
				burst.age = 0
				for j in 0 ..< engine.SPARKS_PER_BURST {
					theta := f32(j) * (2 * math.PI) / f32(engine.SPARKS_PER_BURST)
					burst.spark[j] = {math.cos(theta), math.sin(theta)}
				}
				burst.active = true
				break
			}
			f.next_burst = 0.9 + fx_random(f) * 0.9
		}
		for i in 0 ..< engine.MAX_BURSTS {
			burst := &f.bursts[i]
			if !burst.active {continue}
			burst.age += dt
			if burst.age > 1.6 {
				burst.active = false
				continue
			}
			fade := 1 - burst.age / 1.6
			c := burst.color
			c.a = u8(f32(c.a) * fade)
			base_x := screen.x + burst.x * screen.w
			base_y := screen.y + burst.y * screen.h
			d := 12 + burst.age * 95
			for j in 0 ..< engine.SPARKS_PER_BURST {
				sx := base_x + burst.spark[j].x * d
				sy := base_y + burst.spark[j].y * d
				ui.fill_rect(ctx, ui.Rect{sx - 1.5, sy - 1.5, 3, 3}, c)
			}
		}
	case .Halloween:
		// A harvest moon and a few bats crossing it.
		moon_x := screen.x + 0.78 * screen.w
		moon_y := screen.y + 0.17 * screen.h
		moon_r := screen.h * 0.10
		for dy in -int(moon_r) ..= int(moon_r) {
			if dy % 4 != 0 {continue}
			half := math.sqrt(moon_r * moon_r - f32(dy * dy))
			ui.fill_rect(
				ctx,
				ui.Rect{moon_x - half, moon_y + f32(dy), 2 * half, 4},
				engine.MOON_COLOR,
			)
		}
		ui.fill_rect(
			ctx,
			ui.Rect{moon_x - moon_r * 0.25, moon_y - moon_r * 0.2, moon_r * 0.22, moon_r * 0.16},
			engine.MOON_CRATER,
		)
		ui.fill_rect(
			ctx,
			ui.Rect{moon_x + moon_r * 0.15, moon_y + moon_r * 0.15, moon_r * 0.16, moon_r * 0.12},
			engine.MOON_CRATER,
		)
		for i in 0 ..< engine.MAX_BATS {
			bat := &f.bats[i]
			bat.x += bat.speed * dt / 100
			bat.flap += dt * 9
			if bat.x > 1.05 {
				bat.x = -0.08
				bat.y = 0.08 + fx_random(f) * 0.35
			}
			wing := math.sin(bat.flap) * 5
			top := screen.y + bat.y * screen.h + bat.offset
			color := engine.BAT_COLOR
			base_x := screen.x + bat.x * screen.w
			ui.fill_rect(ctx, ui.Rect{base_x - 11, top + wing, 8, 3}, color)
			ui.fill_rect(ctx, ui.Rect{base_x + 3, top + wing, 8, 3}, color)
			ui.fill_rect(ctx, ui.Rect{base_x - 4, top, 8, 5}, color)
		}
	case:
		// tint-only holidays: the splash's color carries the theme
		return
	}
}

// holiday_front: what is drawn over the title's buttons (snow on Christmas).
// The caller gates on reduce motion.
holiday_front :: proc(app: ^engine.App, ctx: ^ui.Context, h: engine.Holiday, dt: f32) {
	if h != .Christmas {return}
	f := &app.holiday_fx
	if f.running != h {holiday_fx_begin(app, h)}
	screen := ctx.screen
	clock := app.seconds
	for i in 0 ..< engine.MAX_FLAKES {
		flake := &f.flakes[i]
		flake.y += flake.speed * dt / screen.h
		if flake.y > 1 {flake.y = 0; flake.x = fx_random(f)}
		sway := math.sin(clock * 1.5 + flake.phase) * flake.amount * dt / screen.w
		flake.x += sway
		if flake.x > 1 {flake.x -= 1}
		if flake.x < 0 {flake.x += 1}
		s := engine.SNOW_COLOR
		size := flake.size
		ui.fill_rect(
			ctx,
			ui.Rect{screen.x + flake.x * screen.w, screen.y + flake.y * screen.h, size, size},
			s,
		)
	}
}
