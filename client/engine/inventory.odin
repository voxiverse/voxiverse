package engine

import "client:ui"
import "common:game"
import "core:time"

SLOT_SIZE :: ui.Vec2{48, 48} // the hotbar's

CURSOR_CATALOG_BASE :: 1000 // the pad's cursor on catalog cell k is this plus k (a slot is its index)

Drag_Mode :: enum u8 {
	None,
	Quick, // shift + left: quick-move each slot entered
	Spread, // left with a stack on the cursor: share it over the slots entered
	One_Each, // right with a stack on the cursor: one into each slot entered
}

// Inventory_Tab: the overlay's two halves. Creative (the catalog of every
// item, with a search; only with items.catalog) shows the hotbar under it,
// so a stack goes from the catalog straight into a hotbar slot.
Inventory_Tab :: enum u8 {
	Inventory,
	Creative,
	Chest, // looking into a chest (not chosen: the server opened it)
}

Inventory_View :: struct {
	tab:         Inventory_Tab,
	drop_repeat: Drop_Repeat, // the drop key held over a slot
	drop_slot:   int, // the slot it was held over
	drag_from:   int, // the slot a drag began on (-1: none)
	scroll:      f32, // catalog rows scrolled
	mode:        Drag_Mode,
	visited:     [game.ALL_SLOTS]bool, // the slots the drag has passed
	first:       int, // where the drag began
	click_slot:  int, // the last left press (-1: none), for double-clicks
	click_time:  time.Tick,
	spin:        f32, // the preview turned by dragging (radians)
	spinning:    bool, // a drag on the preview is going
	spin_x:      f32, // where the pointer was last frame
	cursor:      int, // the pad's cursor: a slot, or CURSOR_CATALOG_BASE + a catalog cell (-1: not placed)
}

// PREVIEW_IMAGE: the ui image the player's preview is (the renderer maps it).
PREVIEW_IMAGE :: ui.Image(1)
