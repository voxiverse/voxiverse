#+build darwin
package smoke

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"
import "core:testing"
import "core:time"

import "../client/platform"

@(private = "file")
msg :: intrinsics.objc_send

@(private = "file")
nobj: ^NS.Object

// visible_frame: the visible area of the screen window is on.
@(private = "file")
visible_frame :: proc(window: ^NS.Object) -> NS.Rect {
	return msg(NS.Rect, msg(^NS.Object, window, "screen"), "visibleFrame")
}

// pump_until polls the window's events (collecting the Fullscreen_Events seen)
// until done says so, or three seconds have passed.
@(private = "file")
pump_until :: proc(
	w: ^platform.Window,
	seen: ^[dynamic]bool,
	done: proc(w: ^platform.Window) -> bool,
) -> bool {
	start := time.tick_now()
	for time.tick_since(start) < 3 * time.Second {
		for e in platform.poll_events(w) {
			if f, ok := e.(platform.Fullscreen_Event); ok {append(seen, f.fullscreen)}
		}
		if done(w) {return true}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(private = "file")
close_to :: proc(a, b: NS.Rect) -> bool {
	return(
		abs(a.x - b.x) < 1 &&
		abs(a.y - b.y) < 1 &&
		abs(a.width - b.width) < 1 &&
		abs(a.height - b.height) < 1 \
	)
}

// The window's two buttons, as AppKit sends them: zoom fills the screen's
// visible area and a second zoom gives the size back; the green button
// (toggleFullScreen:) enters and leaves the full-screen space, and the game is
// told of it (its setting follows), but not of what it asked for itself.
@(test)
test_zoom_and_green_button :: proc(t: ^testing.T) {
	w: platform.Window
	if !testing.expect(
		t,
		platform.window_open(&w, "Voxiverse test", 800, 600),
		"no window",
	) {return}
	defer platform.window_close(&w)
	window := w.native.window
	seen := make([dynamic]bool, context.temp_allocator)

	visible := visible_frame(window)
	msg(nil, window, "zoom:", nobj)
	zoomed := pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {
		return bool(msg(NS.BOOL, w.native.window, "isZoomed"))
	})
	testing.expect(t, zoomed, "zoom did nothing")
	now := msg(NS.Rect, window, "frame")
	for _ in 0 ..< 100 {
		if close_to(now, visible) {break}
		pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {return false}) 	// (animating)
		now = msg(NS.Rect, window, "frame")
	}
	testing.expectf(
		t,
		close_to(now, visible),
		"zoomed to %v, not the visible area %v",
		now,
		visible,
	)
	msg(nil, window, "zoom:", nobj)
	unzoomed := pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {
		return !bool(msg(NS.BOOL, w.native.window, "isZoomed"))
	})
	testing.expect(t, unzoomed, "a second zoom did not restore the window")

	// The green button.
	clear(&seen)
	msg(nil, window, "toggleFullScreen:", nobj)
	entered := pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {return w.fullscreen})
	testing.expect(t, entered, "the green button did not enter full screen")
	testing.expect(t, len(seen) == 1 && seen[0], "the game was not told it entered full screen")
	clear(&seen)
	msg(nil, window, "toggleFullScreen:", nobj)
	left := pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {return !w.fullscreen})
	testing.expect(t, left, "the green button did not leave full screen")
	testing.expect(t, len(seen) == 1 && !seen[0], "the game was not told it left full screen")

	// The game's own toggle works as before, and is not echoed as an event.
	clear(&seen)
	platform.set_fullscreen(&w, true)
	pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {
		return .FullScreen in msg(NS.WindowStyleMask, w.native.window, "styleMask")
	})
	testing.expect(t, w.fullscreen && len(seen) == 0, "the game's own full screen was echoed")
	platform.set_fullscreen(&w, false)
	pump_until(&w, &seen, proc(w: ^platform.Window) -> bool {
		return .FullScreen not_in msg(NS.WindowStyleMask, w.native.window, "styleMask")
	})
	testing.expect(t, !w.fullscreen && len(seen) == 0, "leaving the game's full screen was echoed")
}
