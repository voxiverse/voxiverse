package client

import "core:fmt"

import "ui"

// The player menu: one overlay with a section open (Inventory, Statistics;
// later the Map, Journal, Character and Atlas). A section is a row of
// SECTIONS (its key, whether it is shown, its draw proc) and a draw proc
// that calls section_tabs for the strip. A hidden section's key does
// nothing: its row is there for the day it is built (design.md, The player
// menu).
//
// Keys (player_menu_keys): a section's key opens it, and closes the menu
// when its section is the open one, else switches to it; Tab opens the
// section shown last (Inventory the first time) and closes the menu when
// open; Escape closes it (overlay.odin); the pad's View is Tab, LB and RB
// step the shown sections, round. The world runs on behind it.

Section_Id :: enum u8 {
	Map,
	Journal,
	Inventory,
	Character,
	Atlas,
	Statistics,
}

Section :: struct {
	label:   string,
	action:  Action, // the key that opens it
	visible: bool, // hidden: no key, no tab (design.md: not yet decided or built)
	draw:    proc(app: ^App, ctx: ^ui.Context, top: bool),
}

@(rodata)
SECTIONS := [Section_Id]Section {
	.Map        = {"Map", .World_Map, false, nil},
	.Journal    = {"Journal", .Journal, false, nil},
	.Inventory  = {"Inventory", .Inventory, true, inventory_ui},
	.Character  = {"Character", .Character, false, nil},
	.Atlas      = {"Atlas", .Atlas, false, nil},
	.Statistics = {"Statistics", .Stats, true, stats_ui},
}

Player_Menu :: struct {
	section:  Section_Id, // the one shown
	last:     Section_Id, // the one shown last (Tab opens it); not saved between runs
	has_last: bool,
}

// section_open: the player menu is open at id.
section_open :: proc(app: ^App, id: Section_Id) -> bool {
	return overlay_is_open(&app.overlays, .Player_Menu) && app.player_menu.section == id
}

// player_menu_show opens the menu at id (a hidden section is not shown), or
// switches to it; the section it leaves is told (the inventory gives the
// cursor's stack back).
player_menu_show :: proc(app: ^App, id: Section_Id) {
	if !SECTIONS[id].visible {return}
	m := &app.player_menu
	if overlay_is_open(&app.overlays, .Player_Menu) {
		if m.section == id {return}
		section_leave(app, m.section)
	} else {
		overlay_open(&app.overlays, .Player_Menu)
	}
	m.section, m.last, m.has_last = id, id, true
	switch id {
	case .Inventory:
		inventory_enter(app)
	case .Statistics:
		stats_enter(app)
	case .Map, .Journal, .Character, .Atlas:
	}
}

// player_menu_close closes the menu (Escape, the section's key, Tab).
player_menu_close :: proc(app: ^App) {
	if !overlay_is_open(&app.overlays, .Player_Menu) {return}
	section_leave(app, app.player_menu.section)
	overlay_close(&app.overlays, .Player_Menu)
}

@(private = "file")
section_leave :: proc(app: ^App, id: Section_Id) {
	#partial switch id {
	case .Inventory:
		inventory_leave(app)
	}
}

// section_step: the next (or previous) shown section from id, round.
section_step :: proc(id: Section_Id, step: int) -> Section_Id {
	n := len(Section_Id)
	to := id
	for _ in 0 ..< n {
		to = Section_Id((int(to) + step + n) % n)
		if SECTIONS[to].visible {break}
	}
	return to
}

// player_menu_keys: the keys above; nothing while a text field, the
// on-screen keyboard or a binding has the keyboard, or another overlay is
// above the menu.
player_menu_keys :: proc(app: ^App) {
	s := app.session
	if s == nil || s.state != .Playing {return}
	a := &app.actions
	m := &app.player_menu
	if overlay_is_open(&app.overlays, .Player_Menu) {
		top, _ := overlay_top(&app.overlays)
		if top != .Player_Menu ||
		   app.ui.edit.active ||
		   ui.osk_is_open(&app.ui) ||
		   app.options.listening != .None {return}
		if action_pressed(a, .Player_Menu) || key_action_pressed(a, .Player_Menu) {
			player_menu_close(app)
			return
		}
		for sec, id in SECTIONS {
			if !sec.visible || !key_action_pressed(a, sec.action) {continue}
			if id == m.section {player_menu_close(app)} else {player_menu_show(app, id)}
			return
		}
		if action_pressed(a, .Section_Prev) {player_menu_show(app, section_step(m.section, -1))}
		if action_pressed(a, .Section_Next) {player_menu_show(app, section_step(m.section, 1))}
		return
	}
	if !game_controls(app) {return}
	if action_pressed(a, .Player_Menu) {
		player_menu_show(app, m.last if m.has_last else .Inventory)
		return
	}
	for sec, id in SECTIONS {
		if sec.visible && action_pressed(a, sec.action) {
			player_menu_show(app, id)
			return
		}
	}
}

// player_menu_ui: the overlay: the open section draws itself.
player_menu_ui :: proc(app: ^App, ctx: ^ui.Context, top: bool) {
	if draw := SECTIONS[app.player_menu.section].draw; draw != nil {draw(app, ctx, top)}
}

SECTION_TAB_WIDTH :: 130

// section_tabs: the strip of shown sections in r with their keys, the open
// one lit; the one chosen with the mouse, if any.
section_tabs :: proc(
	app: ^App,
	ctx: ^ui.Context,
	r: ui.Rect,
) -> (
	chosen: Section_Id,
	picked: bool,
) {
	t := &ctx.theme
	row := r
	for sec, id in SECTIONS {
		if !sec.visible {continue}
		b := ui.cut_left(&row, SECTION_TAB_WIDTH)
		ui.cut_left(&row, t.spacing)
		name := fmt.tprintf("%s (%s)", sec.label, action_label(app, sec.action))
		if id == app.player_menu.section {
			ui.fill_rect(ctx, b, t.hover)
			ui.stroke_rect(ctx, b, t.border_width, t.border)
			ui.draw_text(ctx, b, name, t.font_size, t.hover_text, .Center)
		} else if ui.button(ctx, name, b) {
			chosen, picked = id, true
		}
	}
	return
}
