package analytics

import "core:fmt"
import "core:slice"
import "core:strings"

// `build analytics --session <file>`: one server session's file (server/session_log.odin:
// the events of one LAN party, nothing uploaded) read as a report: what the weapons
// did, how each player's machine and network did, how the server did, what went wrong.

Weapon_Row :: struct {
	kills:  int,
	shots:  int,
	hits:   int,
	damage: f64, // health points dealt
	ttk_ms: [dynamic]f64,
}

Player_Row :: struct {
	id:          i64,
	kills:       int,
	deaths:      int,
	shots:       int,
	hits:        int,
	dealt:       f64,
	taken:       f64,
	grapples:    int,
	jumps:       int,
	air_jumps:   int,
	deaths_by:   map[string]int, // by weapon or cause
	gpu, driver: string,
	os:          string,
	width:       f64,
	height:      f64,
	frame_p50:   [dynamic]f64, // us, one a minute
	frame_p95:   [dynamic]f64,
	frame_worst: f64,
	pings:       [dynamic]f64, // ms
	sent, recv:  f64, // bytes
	resent:      f64,
	minutes:     int, // bandwidth samples
}

// session_summary: the report.
session_summary :: proc(events: []Event) -> string {
	context.allocator = context.temp_allocator // (a report is built, printed and forgotten)
	weapons := make(map[string]Weapon_Row, allocator = context.temp_allocator)
	players := make(map[i64]Player_Row, allocator = context.temp_allocator)
	player :: proc(m: ^map[i64]Player_Row, id: i64) -> ^Player_Row {
		if id not_in m {
			m[id] = Player_Row {
				id        = id,
				deaths_by = make(map[string]int, allocator = context.temp_allocator),
			}
		}
		return &m[id]
	}
	weapon :: proc(m: ^map[string]Weapon_Row, name: string) -> ^Weapon_Row {
		if name not_in m {m[name] = {}}
		return &m[name]
	}
	first, last := max(i64), i64(0)
	started, stopped := false, false
	ticks_p50, ticks_p95, ticks_worst: [dynamic]f64
	ticks_p50 = make([dynamic]f64, context.temp_allocator)
	ticks_p95 = make([dynamic]f64, context.temp_allocator)
	ticks_worst = make([dynamic]f64, context.temp_allocator)
	desyncs, judged, skipped: f64
	errors := make([dynamic]string, context.temp_allocator)
	for e in events {
		first, last = min(first, e.t), max(last, e.t)
		switch e.kind {
		case "server_start":
			started = true
		case "server_stop":
			stopped = true
		case "shot_fired":
			w := weapon(&weapons, text(e, "weapon"))
			w.shots += 1
			w.hits += int(number(e, "hit"))
			if e.actor >= 0 {
				p := player(&players, e.actor)
				p.shots += 1
				p.hits += int(number(e, "hit"))
			}
		case "damage_dealt":
			amount := number(e, "tenths") / 10
			weapon(&weapons, text(e, "weapon")).damage += amount
			if e.actor >= 0 {player(&players, e.actor).dealt += amount}
			player(&players, i64(number(e, "victim"))).taken += amount
		case "kill":
			name := text(e, "weapon")
			w := weapon(&weapons, name)
			w.kills += 1
			append(&w.ttk_ms, number(e, "ttk_ms"))
			if e.actor >= 0 {player(&players, e.actor).kills += 1}
			v := player(&players, i64(number(e, "victim")))
			v.deaths_by[name] += 1
		case "death":
			if e.actor >= 0 {
				p := player(&players, e.actor)
				p.deaths += 1
				// (a death with no killer: its cause alone says how)
			}
		case "grapple_used":
			if e.actor >= 0 {player(&players, e.actor).grapples += 1}
		case "jump":
			if e.actor >= 0 {
				p := player(&players, e.actor)
				if text(e, "kind") == "air" {p.air_jumps += 1} else {p.jumps += 1}
			}
		case "client_info":
			if e.actor >= 0 {player(&players, e.actor).os = text(e, "os")}
		case "client_hardware":
			if e.actor >= 0 {
				p := player(&players, e.actor)
				p.gpu, p.width, p.height = text(e, "gpu"), number(e, "width"), number(e, "height")
			}
		case "client_driver":
			if e.actor >= 0 {player(&players, e.actor).driver = text(e, "driver")}
		case "client_frames":
			if e.actor >= 0 {
				p := player(&players, e.actor)
				append(&p.frame_p50, number(e, "p50_us"))
				append(&p.frame_p95, number(e, "p95_us"))
				p.frame_worst = max(p.frame_worst, number(e, "worst_us"))
			}
		case "ping_sample":
			if e.actor >= 0 {append(&player(&players, e.actor).pings, number(e, "rtt_ms"))}
		case "bandwidth_sample":
			if e.actor >= 0 {
				p := player(&players, e.actor)
				p.sent += number(e, "sent")
				p.recv += number(e, "received")
				p.resent += number(e, "resent")
				p.minutes += 1
			}
		case "server_perf":
			append(&ticks_p50, number(e, "p50_us"))
			append(&ticks_p95, number(e, "p95_us"))
			append(&ticks_worst, number(e, "worst_us"))
		case "server_net":
			desyncs, judged, skipped =
				number(e, "desyncs"), number(e, "judged"), number(e, "skipped")
		case "log_line":
			append(&errors, text(e, "line"))
		}
	}
	b := strings.builder_make(context.temp_allocator)
	seconds := f64(last - first) / 1000 if len(events) > 0 else 0
	fmt.sbprintfln(
		&b,
		"session: %d events over %.0f s, %d players",
		len(events),
		seconds,
		len(players),
	)
	switch {
	case !started:
		fmt.sbprintln(&b, "  no server_start: not a session file?")
	case !stopped:
		fmt.sbprintln(&b, "  no clean stop: the server crashed or was killed")
	}

	// Weapon balance.
	fmt.sbprintln(&b, "\nweapon balance")
	fmt.sbprintfln(
		&b,
		"  %-16s %6s %6s %6s %8s %9s %8s",
		"weapon",
		"kills",
		"shots",
		"hits",
		"accuracy",
		"damage",
		"ttk med",
	)
	names := make([dynamic]string, context.temp_allocator)
	for name in weapons {append(&names, name)}
	slice.sort(names[:])
	for name in names {
		w := weapons[name]
		accuracy, ttk := "-", "-"
		if w.shots > 0 {accuracy = fmt.tprintf("%d%%", 100 * w.hits / w.shots)}
		if len(w.ttk_ms) > 0 {
			slice.sort(w.ttk_ms[:])
			ttk = fmt.tprintf("%.2f s", w.ttk_ms[len(w.ttk_ms) / 2] / 1000)
		}
		label := name if name != "" else "(none)"
		// (fmt pads numbers with zeros: the columns are padded as text)
		fmt.sbprintfln(
			&b,
			"  %-16s %6s %6s %6s %8s %9s %8s",
			label,
			fmt.tprint(w.kills),
			fmt.tprint(w.shots),
			fmt.tprint(w.hits),
			accuracy,
			fmt.tprintf("%.1f", w.damage),
			ttk,
		)
	}

	// Players.
	ids := make([dynamic]i64, context.temp_allocator)
	for id in players {append(&ids, id)}
	slice.sort(ids[:])
	fmt.sbprintln(&b, "\nplayers")
	for id in ids {
		p := players[id]
		accuracy := "-"
		if p.shots > 0 {accuracy = fmt.tprintf("%d%%", 100 * p.hits / p.shots)}
		fmt.sbprintfln(
			&b,
			"  player %d: %d kills, %d deaths, accuracy %s, dealt %.1f, took %.1f, %d grapples, %d jumps, %d double jumps",
			p.id,
			p.kills,
			p.deaths,
			accuracy,
			p.dealt,
			p.taken,
			p.grapples,
			p.jumps,
			p.air_jumps,
		)
		if len(p.deaths_by) > 0 {
			by := make([dynamic]string, context.temp_allocator)
			for name, n in p.deaths_by {append(&by, fmt.tprintf("%s %d", name, n))}
			slice.sort(by[:])
			fmt.sbprintfln(
				&b,
				"    killed by: %s",
				strings.join(by[:], ", ", context.temp_allocator),
			)
		}
	}

	// Frame times and hardware.
	fmt.sbprintln(&b, "\nclients: hardware and frame times")
	for id in ids {
		p := players[id]
		if p.gpu == "" && len(p.frame_p50) == 0 && p.os == "" {continue}
		fmt.sbprintfln(
			&b,
			"  player %d: %s, gpu %s, driver %s, %.0f x %.0f",
			p.id,
			p.os if p.os != "" else "os ?",
			p.gpu if p.gpu != "" else "?",
			p.driver if p.driver != "" else "?",
			p.width,
			p.height,
		)
		if len(p.frame_p50) > 0 {
			slice.sort(p.frame_p50[:])
			slice.sort(p.frame_p95[:])
			fmt.sbprintfln(
				&b,
				"    frame time: median %.1f ms, p95 %.1f ms, worst %.1f ms (%d minutes)",
				p.frame_p50[len(p.frame_p50) / 2] / 1000,
				p.frame_p95[len(p.frame_p95) / 2] / 1000,
				p.frame_worst / 1000,
				len(p.frame_p50),
			)
		}
	}

	// Network.
	fmt.sbprintln(&b, "\nnetwork")
	for id in ids {
		p := players[id]
		if len(p.pings) == 0 && p.minutes == 0 {continue}
		line := fmt.tprintf("  player %d:", p.id)
		if len(p.pings) > 0 {
			slice.sort(p.pings[:])
			line = fmt.tprintf(
				"%s ping median %.0f ms, p95 %.0f ms, worst %.0f ms",
				line,
				p.pings[len(p.pings) / 2],
				p.pings[len(p.pings) * 95 / 100],
				p.pings[len(p.pings) - 1],
			)
		}
		if p.minutes > 0 {
			line = fmt.tprintf(
				"%s, %.1f KB/s down, %.1f KB/s up, %.0f records resent",
				line,
				p.sent / f64(p.minutes) / 60 / 1024,
				p.recv / f64(p.minutes) / 60 / 1024,
				p.resent,
			)
		}
		fmt.sbprintln(&b, line)
	}

	// The server.
	fmt.sbprintln(&b, "\nserver")
	if len(ticks_p50) > 0 {
		slice.sort(ticks_p50[:])
		slice.sort(ticks_p95[:])
		slice.sort(ticks_worst[:])
		fmt.sbprintfln(
			&b,
			"  tick time: median %.2f ms, p95 %.2f ms, worst %.2f ms (%d minutes)",
			ticks_p50[len(ticks_p50) / 2] / 1000,
			ticks_p95[len(ticks_p95) / 2] / 1000,
			ticks_worst[len(ticks_worst) - 1] / 1000,
			len(ticks_p50),
		)
	} else {
		fmt.sbprintln(&b, "  no tick time minutes (the session was shorter than one)")
	}
	fmt.sbprintfln(
		&b,
		"  desyncs: %.0f of %.0f checks judged (%.0f skipped)",
		desyncs,
		judged,
		skipped,
	)
	fmt.sbprintfln(&b, "  warnings and errors: %d", len(errors))
	for line in errors[:min(len(errors), 20)] {fmt.sbprintfln(&b, "    %s", line)}
	if len(errors) > 20 {fmt.sbprintfln(&b, "    ... %d more", len(errors) - 20)}
	return strings.to_string(b)
}
