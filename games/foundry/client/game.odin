package foundry_client

import "core:fmt"
import "core:strings"

import "client:engine"
import "client:ui"
import "common:game"
import "common:protocol"
import "games:foundry"

// Foundry's client part: the factory's line across the top (the goal, the clock, the power,
// the research), a label over the machine aimed at (what it makes, why it stands), where a
// machine in hand would go and the way it would face, and the game's screen: a machine's
// panel (opened by using it) or the hand-crafting list (its action).

GAME :: engine.Game {
	info          = foundry.INFO,
	kinds         = foundry.KINDS,
	state         = View,
	received      = received,
	hud           = hud,
	debug         = debug,
	scoreboard    = scoreboard,
	screen        = screen,
	actions       = {"Craft", "Turn"},
	machine_shown = foundry.Shown,
}

CRAFT_ACTION :: 0
TURN_ACTION :: 1

Screen :: enum u8 {
	Panel,
	Craft,
}

View :: struct {
	status:   foundry.Status,
	panel:    foundry.Panel,
	showing:  Screen,
	builders: engine.Seats(foundry.Builder),
	goal:     engine.Flash,
	opening:  bool, // the craft list opened this frame (its key does not close it at once)
}

view :: proc(s: ^engine.Session) -> ^View {return engine.game_state(s, View)}

received :: proc(s: ^engine.Session, r: protocol.Received) {
	v := view(s)
	if st, ok := engine.game_value(s, r, foundry.Status); ok && st != nil {
		v.status = st^
	} else if p, is := engine.game_value(s, r, foundry.Panel); is {
		v.panel = p^ if p != nil else {}
		if !v.panel.open && v.showing == .Panel {engine.game_screen_close(s)}
	} else if o, opened := engine.game_value(s, r, foundry.Panel_Open); opened && o != nil {
		v.showing = .Panel
		engine.game_screen_open(s)
	} else if g, reached := engine.game_value(s, r, foundry.Goal_Reached); reached && g != nil {
		engine.flash(&v.goal, s, foundry.tr(.Goal_Banner, clock(g.seconds)), .Good, 6)
	} else {
		engine.seats_received(s, &v.builders, r)
	}
}

clock :: proc(seconds: u32) -> string {return fmt.tprintf("%d:%02d", seconds / 60, seconds % 60)}

// research_line: what the labs are studying, and how far.
research_line :: proc(st: ^foundry.Status) -> string {
	if st.studied == 0xFF {return foundry.tr(.Research_All)}
	info := foundry.RESEARCH[st.studying]
	return foundry.tr(.Research_Line, info.name, st.progress, info.insight)
}

hud :: proc(s: ^engine.Session, ctx: ^ui.Context) {
	v := view(s)
	st := &v.status
	rest := ctx.screen
	line :=
		foundry.tr(.Status_Done, st.goal, clock(st.seconds), st.supply, st.demand) if st.done else foundry.tr(.Status, st.made, st.goal, clock(st.seconds), st.supply, st.demand, research_line(st))
	engine.top_bar(ctx, &rest, line)
	keys := foundry.tr(
		.Keys,
		engine.game_action_key(s, CRAFT_ACTION),
		engine.game_action_key(s, TURN_ACTION),
	)
	ui.label(ctx, keys, ui.cut_top(&rest, ctx.theme.row_height), .Center, ctx.theme.text_muted)
	if st.demand > st.supply && st.parts > 0 {
		percent := 0 if st.demand == 0 else int(st.supply * 100 / st.demand)
		ui.label(
			ctx,
			foundry.tr(.Power_Short, percent),
			ui.cut_top(&rest, ctx.theme.row_height),
			.Center,
			ctx.theme.warning,
		)
	}
	engine.flash_draw(ctx, &v.goal, s)
	if engine.game_action_pressed(s, CRAFT_ACTION) && !engine.game_screen_shown(s) {
		v.showing, v.opening = .Craft, true
		engine.game_screen_open(s)
	}
	aim, aiming := s.aim.?
	if engine.game_action_pressed(s, TURN_ACTION) && aiming {
		turn := foundry.Turn{aim.block}
		engine.game_request(s, &turn)
	}
	if aiming {
		if shown := engine.machine_shown(s, aim.block, foundry.Shown); shown != nil {
			top := [3]f64{f64(aim.block.x) + 0.5, f64(aim.block.y) + 1.4, f64(aim.block.z) + 0.5}
			engine.world_label(s, ctx, top, label(s, shown))
		}
		preview(s, ctx, aim)
	}
}

// label: what a machine's label says: what it is, what it makes and how far, why it stands.
label :: proc(s: ^engine.Session, m: ^foundry.Shown) -> string {
	name := foundry.kind_name(m.kind)
	#partial switch m.kind {
	case .Crate, .Generator:
		return foundry.tr(.Label_Count, name, m.count)
	}
	if m.recipe != 0 && int(m.recipe) <= len(s.reg.recipes) {
		r := &s.reg.recipes[m.recipe - 1]
		return foundry.tr(
			.Label,
			name,
			item_label(s, r.output.item),
			foundry.state_name(m.state),
			m.progress,
		)
	}
	return foundry.tr(.Label_Plain, name, foundry.state_name(m.state))
}

// item_label: an item's name for people ("ember bar").
item_label :: proc(s: ^engine.Session, item: game.Item) -> string {
	name := game.item_name(s.reg, item)
	if colon := strings.index_byte(name, ':'); colon >= 0 {name = name[colon + 1:]}
	out, _ := strings.replace_all(name, "_", " ", context.temp_allocator)
	return out
}

// preview: where the machine in hand would go, outlined, and the way it would face.
preview :: proc(s: ^engine.Session, ctx: ^ui.Context, aim: game.Ray_Hit) {
	held := s.inventory.slots[s.inventory.selected]
	if game.stack_empty(held) {return}
	info, _ := game.item_info(s.reg, held.item)
	if info.block == .Air ||
	   !strings.has_prefix(game.item_id(s.reg, held.item), "foundry:") {return}
	at := aim.block + aim.normal
	engine.world_box(s, at, at, {240, 200, 80, 255})
	t := &s.reg.blocks
	if _, faces := game.facing_vector(t, info.block); !faces {return}
	way := game.ROTATE_VALUES[game.facing_of_yaw(s.camera.yaw)]
	top := [3]f64{f64(at.x) + 0.5, f64(at.y) + 1.2, f64(at.z) + 0.5}
	engine.world_label(s, ctx, top, foundry.tr(.Preview, item_label(s, held.item), way))
}

debug :: proc(s: ^engine.Session) -> string {
	st := &view(s).status
	return fmt.tprintf(
		"made %d/%d power %d/%d kW parts %d research %v %d",
		st.made,
		st.goal,
		st.supply,
		st.demand,
		st.parts,
		st.studying,
		st.progress,
	)
}

scoreboard :: proc(s: ^engine.Session, board: ^engine.Scoreboard) {
	v := view(s)
	board.title = foundry.tr(.Score_Title)
	engine.scoreboard_columns(board, foundry.tr(.Score_Crafted), foundry.tr(.Score_Placed))
	for id in engine.seats_ranked(&v.builders, proc(a, b: ^foundry.Builder) -> bool {return a.placed + a.crafted > b.placed + b.crafted}) {
		b := &v.builders.values[id]
		engine.scoreboard_row(
			board,
			b.name,
			fmt.tprint(b.crafted),
			fmt.tprint(b.placed),
			you = id == int(s.welcome.player),
		)
	}
}
