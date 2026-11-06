package engine

import "core:fmt"
import "core:os"
import "core:slice"

import "client:platform"
import "client:ui"

// The offer: when the title first shows and an earlier run left crash bundles the player has
// not seen, a dialog says so and offers to open the folder. A bundle is seen once it holds a
// file named `seen`; the dialog (either button, Escape, B) writes one into every unseen bundle.

CRASH_SEEN :: "seen"

Crash_Offer :: struct {
	root:     [512]u8, // the crashes directory ("": no offer; set by main)
	root_n:   int,
	checked:  bool, // looked once this run
	newest:   [512]u8, // the newest unseen bundle's path
	newest_n: int,
	earlier:  int, // how many unseen bundles are older than it
}

// crash_offer_root sets the crashes directory the offer looks in.
crash_offer_root :: proc(app: ^App, root: string) {
	o := &app.crash_offer
	o.root_n = copy(o.root[:], root)
	if o.root_n < len(root) {o.root_n = 0}
}

// crash_unseen lists the bundle folders in root without a `seen` file, oldest first.
crash_unseen :: proc(root: string, allocator := context.temp_allocator) -> []string {
	list := make([dynamic]string, allocator)
	infos, err := os.read_directory_by_path(root, -1, context.temp_allocator)
	if err != nil {return list[:]}
	for fi in infos {
		if fi.type != .Directory {continue}
		path := fmt.aprintf("%s/%s", root, fi.name, allocator = allocator)
		if os.exists(fmt.tprintf("%s/%s", path, CRASH_SEEN)) {
			delete(path, allocator)
		} else {
			append(&list, path)
		}
	}
	slice.sort(list[:]) // (names start with the UTC time)
	return list[:]
}

// crash_offer_update: once a frame. Opens the dialog the first time the title shows over
// unseen bundles (not in scripts or benchmarks, which crash on purpose).
crash_offer_update :: proc(app: ^App) {
	o := &app.crash_offer
	if o.checked || o.root_n == 0 || app.screen != .Title || app.scripted || app.benchmark {return}
	o.checked = true
	unseen := crash_unseen(string(o.root[:o.root_n]))
	if len(unseen) == 0 {return}
	newest := unseen[len(unseen) - 1]
	o.newest_n = copy(o.newest[:], newest)
	o.earlier = len(unseen) - 1
	overlay_open(&app.overlays, .Crash_Report)
}

// crash_offer_dismiss marks every bundle seen and closes the dialog.
crash_offer_dismiss :: proc(app: ^App) {
	o := &app.crash_offer
	for path in crash_unseen(string(o.root[:o.root_n])) {
		_ = os.write_entire_file(
			fmt.tprintf("%s/%s", path, CRASH_SEEN),
			transmute([]u8)string("seen\n"),
		)
	}
	overlay_close(&app.overlays, .Crash_Report)
}

// crash_dialog: what the last run left, and the way to look at it.
crash_dialog :: proc(app: ^App, ctx: ^ui.Context) {
	o := &app.crash_offer
	ui.push_id(ctx, "crash dialog")
	defer ui.pop_id(ctx)
	t := &ctx.theme
	prev := ui.begin_layer(ctx, .Modal)
	defer ui.end_layer(ctx, prev)
	ui.backdrop(ctx)
	box := ui.rect_center(ctx.screen, 560, 240)
	ui.panel(ctx, box)
	inner := ui.rect_shrink(box, 2 * t.padding)
	ui.label(ctx, tr(.Crash_Title), ui.cut_top(&inner, t.row_height), .Center)
	ui.cut_top(&inner, t.spacing)
	ui.label(ctx, tr(.Crash_Saved), ui.cut_top(&inner, t.row_height), .Center)
	ui.label(ctx, tr(.Crash_Not_Sent), ui.cut_top(&inner, t.row_height), .Center)
	if o.earlier > 0 {
		ui.label(ctx, tr(.Crash_Earlier, o.earlier), ui.cut_top(&inner, t.row_height), .Center)
	}
	buttons := ui.cut_bottom(&inner, t.row_height)
	close := ui.cut_right(&buttons, (buttons.w - t.spacing) / 2)
	ui.cut_right(&buttons, t.spacing)
	if ui.button(ctx, tr(.Crash_Open_Folder), buttons) {
		path := string(o.newest[:o.newest_n])
		if !platform.open_folder(path) {toast(app, .Crash_Folder_Failed, path)}
		crash_offer_dismiss(app)
	}
	ui.default_focus(ctx)
	if ui.button(ctx, tr(.Crash_Close), close) {crash_offer_dismiss(app)}
}
