#+build linux
package tests

import "core:log"
import "core:os"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "../client/platform"
// The Linux backend against a virtual pad made through /dev/uinput: connect,
// a button, an axis and the disconnect, through the real inotify and evdev
// paths. Where /dev/uinput cannot be written the test warns and passes,
// unless VX_REQUIRE_UINPUT=1 (CI), where it fails.

UI_SET_EVBIT :: 0x40045564
UI_SET_KEYBIT :: 0x40045565
UI_SET_ABSBIT :: 0x40045567
UI_DEV_CREATE :: 0x5501
UI_DEV_DESTROY :: 0x5502

@(private = "file")
Uinput_User_Dev :: struct #packed {
	name:       [80]u8,
	bustype:    u16,
	vendor:     u16,
	product:    u16,
	version:    u16,
	ff_effects: u32,
	absmax:     [64]i32,
	absmin:     [64]i32,
	absfuzz:    [64]i32,
	absflat:    [64]i32,
}
#assert(size_of(Uinput_User_Dev) == 1116)

@(private = "file")
Input_Event :: struct #packed {
	sec, usec: i64,
	type:      u16,
	code:      u16,
	value:     i32,
}

@(private = "file")
send :: proc(fd: linux.Fd, type, code: u16, value: i32) {
	e := Input_Event {
		type  = type,
		code  = code,
		value = value,
	}
	linux.write(fd, ([^]u8)(&e)[:size_of(e)])
}

@(private = "file")
wait_for :: proc(
	p: ^platform.Pads,
	events: ^[dynamic]platform.Event,
	found: proc(e: platform.Event) -> bool,
) -> bool {
	for _ in 0 ..< 200 {
		clear(events)
		platform.pads_poll(p, events, true)
		for e in events {
			if found(e) {return true}
		}
		time.sleep(10 * time.Millisecond)
	}
	return false
}

@(test)
test_uinput_pad :: proc(t: ^testing.T) {
	require := os.get_env("VX_REQUIRE_UINPUT", context.temp_allocator) == "1"
	fd, err := linux.open("/dev/uinput", {.WRONLY, .NONBLOCK})
	if err != .NONE {
		if require {testing.fail_now(t, "/dev/uinput cannot be opened and VX_REQUIRE_UINPUT=1")}
		log.warn("pad_uinput_test: /dev/uinput not writable: skipped")
		return
	}
	defer linux.close(fd)
	ioctl :: proc(fd: linux.Fd, req: u32, arg: uintptr) {_ = linux.ioctl(fd, req, arg)}
	ioctl(fd, UI_SET_EVBIT, platform.EV_KEY)
	ioctl(fd, UI_SET_EVBIT, platform.EV_ABS)
	ioctl(fd, UI_SET_EVBIT, platform.EV_SYN)
	ioctl(fd, UI_SET_KEYBIT, platform.BTN_SOUTH)
	ioctl(fd, UI_SET_ABSBIT, platform.ABS_X)
	ioctl(fd, UI_SET_ABSBIT, platform.ABS_Y)
	dev: Uinput_User_Dev
	copy(dev.name[:], "Voxiverse Test Pad")
	dev.bustype, dev.vendor, dev.product = 3, 0x1209, 0x0001
	for a in 0 ..< 2 {
		dev.absmin[a], dev.absmax[a] = -32768, 32767
	}
	linux.write(fd, ([^]u8)(&dev)[:size_of(dev)])

	p: platform.Pads
	platform.pads_open(&p)
	defer platform.pads_close(&p)
	events: [dynamic]platform.Event
	defer delete(events)

	ioctl(fd, UI_DEV_CREATE, 0)
	created := true
	defer if created {ioctl(fd, UI_DEV_DESTROY, 0)}

	is_ours :: proc(e: platform.Event) -> bool {
		c, ok := e.(platform.Pad_Connect_Event)
		return ok && c.connected && c.vendor == 0x1209 && c.product == 1
	}
	if !wait_for(&p, &events, is_ours) {
		if require {testing.fail_now(t, "the virtual pad did not connect")}
		log.warn(
			"pad_uinput_test: the virtual pad did not appear (no permission on its node?): skipped",
		)
		return
	}
	send(fd, platform.EV_KEY, platform.BTN_SOUTH, 1)
	send(fd, platform.EV_SYN, platform.SYN_REPORT, 0)
	testing.expect(t, wait_for(&p, &events, proc(e: platform.Event) -> bool {
			b, ok := e.(platform.Pad_Button_Event)
			return ok && b.button == .A && b.pressed
		}), "the A press arrived")
	send(fd, platform.EV_ABS, platform.ABS_X, 32767)
	send(fd, platform.EV_SYN, platform.SYN_REPORT, 0)
	testing.expect(t, wait_for(&p, &events, proc(e: platform.Event) -> bool {
			a, ok := e.(platform.Pad_Axis_Event)
			return ok && a.axis == .Left_X && a.value > 0.99
		}), "Left_X reached 1")
	ioctl(fd, UI_DEV_DESTROY, 0)
	created = false
	testing.expect(t, wait_for(&p, &events, proc(e: platform.Event) -> bool {
			c, ok := e.(platform.Pad_Connect_Event)
			return ok && !c.connected && c.vendor == 0x1209
		}), "the disconnect arrived")
}
