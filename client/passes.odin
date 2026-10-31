package client

import "core:strings"

import "client:render"

// The render passes, in one table: what start-up (pipelines from their
// shaders), shader hot reload and teardown go through. A pass's shaders are
// <shader>.vert and <shader>.frag (and maybe more of its own, which it
// reads itself); includes: the .glsl files they include.

Pass :: enum u8 {
	UI,
	Debug,
	Sky,
	Entity,
	Held,
	World,
}

Pass_Info :: struct {
	shader:   string,
	others:   []string, // more shader files of its own (their names without extension)
	includes: []string, // the .glsl files its shaders include (without extension)
	init:     proc(app: ^App, vert, frag: []u8) -> bool,
	reload:   proc(app: ^App, vert, frag: []u8) -> bool,
	destroy:  proc(app: ^App),
}

PASSES := [Pass]Pass_Info {
	.UI = {
		shader = "ui",
		init = proc(app: ^App, vert, frag: []u8) -> bool {return render.ui_init(
				&app.ui_pass,
				&app.g,
				vert,
				frag,
			)},
		reload = proc(app: ^App, vert, frag: []u8) -> bool {return render.ui_reload(
				&app.ui_pass,
				&app.g,
				vert,
				frag,
			)},
		destroy = proc(app: ^App) {render.ui_destroy(&app.ui_pass, &app.g)},
	},
	.Debug = {
		shader = "debug",
		init = proc(app: ^App, vert, frag: []u8) -> bool {return render.debug_init(
				&app.debug_pass,
				&app.g,
				vert,
				frag,
			)},
		reload = proc(app: ^App, vert, frag: []u8) -> bool {return render.debug_reload(
				&app.debug_pass,
				&app.g,
				vert,
				frag,
			)},
		destroy = proc(app: ^App) {render.debug_destroy(&app.debug_pass, &app.g)},
	},
	.Sky = {
		shader = "sky",
		includes = {"scene"},
		init = proc(app: ^App, vert, frag: []u8) -> bool {return render.sky_init(
				&app.sky_pass,
				&app.g,
				vert,
				frag,
			)},
		reload = proc(app: ^App, vert, frag: []u8) -> bool {return render.sky_reload(
				&app.sky_pass,
				&app.g,
				vert,
				frag,
			)},
		destroy = proc(app: ^App) {render.sky_destroy(&app.sky_pass, &app.g)},
	},
	.Entity = {
		shader = "entity",
		includes = {"scene"},
		init = proc(app: ^App, vert, frag: []u8) -> bool {return render.entity_init(
				&app.entity_pass,
				&app.g,
				vert,
				frag,
			)},
		reload = proc(app: ^App, vert, frag: []u8) -> bool {return render.entity_reload(
				&app.entity_pass,
				&app.g,
				vert,
				frag,
			)},
		destroy = proc(app: ^App) {render.entity_destroy(&app.entity_pass, &app.g)},
	},
	.Held = {
		shader = "held",
		includes = {"scene"},
		init = proc(app: ^App, vert, frag: []u8) -> bool {return render.held_init(
				&app.held_pass,
				&app.g,
				vert,
				frag,
			)},
		reload = proc(app: ^App, vert, frag: []u8) -> bool {return render.held_reload(
				&app.held_pass,
				&app.g,
				vert,
				frag,
			)},
		destroy = proc(app: ^App) {render.held_destroy(&app.held_pass, &app.g)},
	},
	.World = {
		shader = "world",
		others = {"world_cutout", "water", "world_cull"},
		includes = {"scene", "world"},
		init = world_pass_init,
		reload = proc(app: ^App, vert, frag: []u8) -> bool {
			shaders := world_shaders(vert, frag) or_return
			return render.world_reload(&app.world_pass, &app.g, shaders)
		},
		destroy = proc(app: ^App) {render.world_destroy(&app.world_pass, &app.g)},
	},
}

// passes_init makes every pass, in order; false at the first that fails
// (passes_destroy undoes what was made).
passes_init :: proc(app: ^App) -> bool {
	for &info in PASSES {
		vert, frag := pass_shaders(info) or_return
		info.init(app, vert, frag) or_return
	}
	return true
}

// passes_destroy: in reverse. Destroying a pass never made does nothing.
passes_destroy :: proc(app: ^App) {
	#reverse for &info in PASSES {info.destroy(app)}
}

// pass_shaders reads a pass's compiled shaders.
pass_shaders :: proc(info: Pass_Info) -> (vert, frag: []u8, ok: bool) {
	vert = read_shader(
		strings.concatenate({info.shader, ".vert.spv"}, context.temp_allocator),
	) or_return
	frag = read_shader(
		strings.concatenate({info.shader, ".frag.spv"}, context.temp_allocator),
	) or_return
	return vert, frag, true
}

// world_shaders: the world pass's vertex shader, its opaque fragment
// shader (given), the other layers' and the culling pass's (read here).
world_shaders :: proc(vert, frag: []u8) -> (shaders: render.World_Shaders, ok: bool) {
	shaders.vertex = vert
	shaders.fragment[.Opaque] = frag
	shaders.fragment[.Cutout] = read_shader("world_cutout.frag.spv") or_return
	shaders.fragment[.Translucent] = read_shader("water.frag.spv") or_return
	shaders.cull = read_shader("world_cull.comp.spv") or_return
	return shaders, true
}
