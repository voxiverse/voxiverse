package client

import "core:fmt"
import "core:math"
import "core:sync"

import "../base"
import "audio"
import "ui"

// The audio inspector (M32e, dev builds): F8 freezes the last stretch of the
// mixer (audio.inspect_freeze: the rolling capture's newest window, replayed
// through a mixer of its own) and plays the last half second of it in a loop
// in place of the live output. The panel lists the buses and the frozen voices
// with what the engine decided about each, shows a spectrum of Master and the
// device's own counters; a button on a row solos it, a second press mutes it,
// a third clears it (the window is replayed with the commands rewritten). F8
// again, or Escape, thaws. The game runs on underneath: only what is heard is
// frozen.

INSPECTOR_VOICE_ROWS :: 14
@(private = "file")
SPECTRUM_ROWS :: 2

// audio_inspector_sync: the overlay and the freeze follow each other, once a
// frame: the key toggles the overlay; an open overlay without a freeze takes
// one; a closed one with a freeze ends it.
audio_inspector_sync :: proc(app: ^App) {
	d := &app.audio_debug
	if !base.DEV {return}
	if app.session == nil || !d.recording {
		if d.frozen != nil {audio_inspector_thaw(app)}
		return
	}
	if .F8 in app.input.pressed && app.screen == .Game {
		overlay_toggle(&app.overlays, .Audio_Inspector)
	}
	open := overlay_is_open(&app.overlays, .Audio_Inspector)
	switch {
	case open && d.frozen == nil:
		d.frozen = audio.inspect_freeze(app.mixer)
		if d.frozen == nil {
			console_print(
				&app.console,
				"audio inspector: nothing to freeze yet (the ring needs a moment of audio)",
				.Warning,
			)
			overlay_close(&app.overlays, .Audio_Inspector)
		} else {
			audio.inspect_start(d.frozen)
		}
	case !open && d.frozen != nil:
		audio_inspector_thaw(app)
	}
}

audio_inspector_thaw :: proc(app: ^App) {
	audio.inspect_destroy(app.audio_debug.frozen)
	app.audio_debug.frozen = nil
}

@(private = "file")
cycle_mode :: proc(m: audio.Inspect_Mode) -> audio.Inspect_Mode {
	switch m {
	case .Off:
		return .Solo
	case .Solo:
		return .Mute
	case .Mute:
		return .Off
	}
	return .Off
}

@(private = "file")
mode_text :: proc(m: audio.Inspect_Mode) -> string {
	switch m {
	case .Off:
		return "-"
	case .Solo:
		return "Solo"
	case .Mute:
		return "Mute"
	}
	return "-"
}

@(private = "file")
decision_text :: proc(v: audio.Frozen_Voice) -> string {
	if !v.heard {return "silent"}
	switch v.last {
	case .Started:
		return "playing"
	case .Virtualized:
		return "virtual"
	case .Restored:
		return "playing"
	case .Ended:
		return "ended"
	case .Stopped:
		return "stopped"
	case .Dropped:
		return "dropped"
	}
	return ""
}

audio_inspector_ui :: proc(app: ^App, ctx: ^ui.Context) {
	fz := app.audio_debug.frozen
	if fz == nil {return}
	ui.push_id(ctx, "audio inspector")
	defer ui.pop_id(ctx)
	prev := ui.begin_layer(ctx, .Popup)
	defer ui.end_layer(ctx, prev)
	t := &ctx.theme
	// (the rows that are always there; the voices take what height is left)
	fixed := 2 + 1 + len(Bus_Rows) + 1 + SPECTRUM_ROWS + 1 + 1
	row := t.row_height + t.spacing
	fit := int((ctx.screen.h - 2 * t.padding) / row) - fixed
	voice_rows := clamp(fit, 2, INSPECTOR_VOICE_ROWS)
	r := ctx.screen
	panel := ui.cut_left(&r, min(760, ctx.screen.w * 0.85))
	panel.h = min(panel.h, f32(fixed + voice_rows) * row + 2 * t.padding)
	ui.panel(ctx, panel)
	ui.layout_begin(ctx, ui.rect_shrink(panel, t.padding))
	defer ui.layout_end(ctx)

	seconds := f64(len(fz.loop) / 2) / f64(fz.live.rate)
	ui.label(
		ctx,
		fmt.tprintf(
			"Audio inspector: frozen, the last %.1f s looping (F8 to thaw)%s",
			seconds,
			"" if fz.pick.mode == .Off else "  [rewritten]",
		),
		ui.next(ctx),
		.Left,
	)
	// (not audio.stats: reading it resets the callback's worst case)
	st := &app.mixer.stats
	ui.label(
		ctx,
		fmt.tprintf(
			"%.1f ms, callback %.0f us (worst %.0f), %d underruns, %d late, %.0f ppm",
			audio.output_latency(&app.audio_device, app.mixer),
			f32(sync.atomic_load(&st.cb_last_ns)) / 1000,
			f32(sync.atomic_load(&st.cb_max_ns)) / 1000,
			sync.atomic_load(&st.underruns),
			sync.atomic_load(&st.late),
			audio.stats_drift_ppm(app.mixer),
		),
		ui.next(ctx),
		.Left,
		t.text_muted,
	)

	ui.label(ctx, "Buses", ui.next(ctx), .Left, t.text_muted)
	ui.push_id(ctx, "buses")
	defer ui.pop_id(ctx)
	for b, i in Bus_Rows {
		ui.push_id_int(ctx, i)
		row := ui.next(ctx)
		btn := ui.cut_right(&row, 80)
		ui.cut_right(&row, t.spacing)
		mine := fz.pick.mode if !fz.pick.voice && fz.pick.bus == b else audio.Inspect_Mode.Off
		peak := fz.an.peak[b]
		db := 20 * math.log10(max(peak, 1e-6))
		ui.label(ctx, fmt.tprintf("%v", b), ui.cut_left(&row, 110), .Left)
		bar := ui.cut_left(&row, 260)
		fill := clamp((db + 60) / 60, 0, 1)
		ui.fill_rect(ctx, bar, {40, 40, 40, 255})
		ui.fill_rect(ctx, {bar.x, bar.y, bar.w * fill, bar.h}, {90, 170, 220, 255})
		ui.label(ctx, fmt.tprintf("%.0f dB", db) if peak > 0 else "silent", row, .Right)
		if ui.button(ctx, fmt.tprintf("%s##bus%d", mode_text(mine), i), btn) {
			audio.inspect_pick(fz, {mode = cycle_mode(mine), bus = b})
		}
		ui.pop_id(ctx)
	}

	// Master's spectrum.
	ui.label(
		ctx,
		fmt.tprintf(
			"Master %.1f LUFS (momentary peak), spectrum 40 Hz to 20 kHz",
			fz.an.momentary_max[.Master],
		),
		ui.next(ctx),
		.Left,
		t.text_muted,
	)
	spec := ui.next(ctx, SPECTRUM_ROWS * t.row_height)
	ui.fill_rect(ctx, spec, {20, 20, 20, 255})
	bw := spec.w / audio.INSPECT_BANDS
	for v, i in fz.bands {
		h := clamp((v - audio.SPEC_FLOOR_DB) / -audio.SPEC_FLOOR_DB, 0, 1) * spec.h
		ui.fill_rect(
			ctx,
			{spec.x + f32(i) * bw, spec.y + spec.h - h, bw - 1, h},
			{230, 160, 60, 255},
		)
	}

	ui.label(
		ctx,
		"Voices (sound, bus, gain, pitch, priority, decision)",
		ui.next(ctx),
		.Left,
		t.text_muted,
	)
	// (the newest first: the old ones have ended)
	for k in 0 ..< len(fz.voices) {
		v, i := fz.voices[len(fz.voices) - 1 - k], k
		if i >= voice_rows {
			ui.label(
				ctx,
				fmt.tprintf("... and %d more", len(fz.voices) - i),
				ui.next(ctx),
				.Left,
				t.text_muted,
			)
			break
		}
		ui.push_id_int(ctx, i)
		row := ui.next(ctx)
		btn := ui.cut_right(&row, 80)
		ui.cut_right(&row, t.spacing)
		mine := fz.pick.mode if fz.pick.voice && fz.pick.id == v.id else audio.Inspect_Mode.Off
		buf: [audio.SOUND_NAME_LEN + 8]u8
		name := audio.sound_name(&fz.live.names[v.sound], int(v.sound), buf[:])
		ui.label(
			ctx,
			fmt.tprintf(
				"%-16s %-8v x%.2f p%d  %s",
				name,
				v.bus,
				v.pitch,
				v.priority,
				decision_text(v),
			),
			row,
			.Left,
			t.text if v.heard else t.text_muted,
		)
		if ui.button(ctx, fmt.tprintf("%s##voice%d", mode_text(mine), i), btn) {
			audio.inspect_pick(fz, {mode = cycle_mode(mine), voice = true, id = v.id})
		}
		ui.pop_id(ctx)
	}
}

@(private = "file")
Bus_Rows :: [?]audio.Bus{.World, .Player, .UI, .Effects, .Ambience, .Music}
