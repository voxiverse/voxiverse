package platform

import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"

// Linux gamepads: /dev/input/event* devices read directly (never js*, never
// grabbed), found by scanning once and watching the directory with inotify
// for hot-plug. Permissions as they are: systemd's uaccess rule gives the
// logged-in seat user an ACL on joystick nodes; a node we cannot open is
// normal and retried when udev changes it (IN_ATTRIB).

INPUT_DIR :: "/dev/input"

IN_ATTRIB :: 0x4
IN_MOVED_TO :: 0x80
IN_CREATE :: 0x100
IN_DELETE :: 0x200

@(private = "file")
Linux_Pad :: struct {
	fd:       linux.Fd,
	open:     bool,
	dropping: bool,
	node:     [32]u8, // "event7"
	node_len: int,
	dev:      Evdev_Pad,
}

Native_Pads :: struct {
	inotify: linux.Fd,
	watch:   bool,
	pads:    [MAX_PADS]Linux_Pad,
	ignore:  string, // Steam's SDL_GAMECONTROLLER_IGNORE_DEVICES
	except:  string,
}

@(private = "file")
EVIOCGID :: 0x80084502
@(private = "file")
EVIOCGABS_BASE :: 0x80184540

@(private = "file")
ioc_read :: proc(nr, size: u32) -> u32 {
	return (2 << 30) | (size << 16) | (0x45 << 8) | nr
}

@(private = "file")
ioctl_ok :: proc(fd: linux.Fd, req: u32, ptr: rawptr) -> bool {
	r := linux.ioctl(fd, req, uintptr(ptr))
	return int(r) >= 0
}

native_pads_open :: proc(p: ^Pads) {
	n := &p.native
	for &d in n.pads {
		d.fd = -1
	}
	n.ignore = strings.clone(
		os.get_env("SDL_GAMECONTROLLER_IGNORE_DEVICES", context.temp_allocator),
	)
	n.except = strings.clone(
		os.get_env("SDL_GAMECONTROLLER_IGNORE_DEVICES_EXCEPT", context.temp_allocator),
	)
	fd, err := linux.inotify_init1({.NONBLOCK, .CLOEXEC})
	n.inotify = -1
	if err != .NONE {
		log.warnf("platform pads: inotify unavailable (%v): no hot-plug", err)
	} else {
		_, werr := linux.inotify_add_watch(
			fd,
			INPUT_DIR,
			transmute(linux.Inotify_Event_Mask)u32(
				IN_CREATE | IN_ATTRIB | IN_MOVED_TO | IN_DELETE,
			),
		)
		if werr != .NONE {
			log.warnf("platform pads: cannot watch %s (%v): no hot-plug", INPUT_DIR, werr)
			linux.close(fd)
		} else {
			n.inotify = fd
			n.watch = true
		}
	}
	dir, derr := linux.open(INPUT_DIR, {.DIRECTORY, .CLOEXEC})
	if derr != .NONE {return}
	defer linux.close(dir)
	buf: [4096]u8
	for {
		got, gerr := linux.getdents(dir, buf[:])
		if gerr != .NONE || got <= 0 {break}
		off := 0
		for off < got {
			ent := cast(^linux.Dirent)&buf[off]
			name := cstring(cast([^]u8)&buf[off + 19])
			pad_try_node(p, string(name))
			off += int(ent.reclen)
		}
	}
}

native_pads_close :: proc(p: ^Pads) {
	n := &p.native
	for &d in n.pads {
		if d.open {linux.close(d.fd)}
	}
	if n.watch {linux.close(n.inotify)}
	delete(n.ignore)
	delete(n.except)
	n^ = {}
}

native_pads_poll :: proc(p: ^Pads) {
	n := &p.native
	if n.watch {
		buf: [2048]u8
		for {
			got, err := linux.read(n.inotify, buf[:])
			if err == .EINTR {continue}
			if err != .NONE || got <= 0 {break}
			off := 0
			for off + size_of(linux.Inotify_Event) <= got {
				ev := cast(^linux.Inotify_Event)&buf[off]
				name_ptr := cast([^]u8)&buf[off + size_of(linux.Inotify_Event)]
				name := string(cstring(name_ptr)) if ev.len > 0 else ""
				mask := u32(transmute(u32)ev.mask)
				if mask & IN_DELETE != 0 {
					pad_drop_node(p, name)
				} else {
					pad_try_node(p, name)
				}
				off += size_of(linux.Inotify_Event) + int(ev.len)
			}
		}
	}
	for i in 0 ..< MAX_PADS {
		if n.pads[i].open {pad_read(p, i)}
	}
}

@(private = "file")
node_matches :: proc(d: ^Linux_Pad, name: string) -> bool {
	return d.open && string(d.node[:d.node_len]) == name
}

@(private = "file")
pad_drop_node :: proc(p: ^Pads, name: string) {
	for i in 0 ..< MAX_PADS {
		if node_matches(&p.native.pads[i], name) {pad_close_slot(p, i)}
	}
}

@(private = "file")
pad_close_slot :: proc(p: ^Pads, i: int) {
	d := &p.native.pads[i]
	if d.open {linux.close(d.fd)}
	d.open = false
	d.fd = -1
	p.state[i] = {}
}

// pad_try_node opens /dev/input/<name> if it is an event node, not open
// already, and a pad.
@(private = "file")
pad_try_node :: proc(p: ^Pads, name: string) {
	if !strings.has_prefix(name, "event") || len(name) >= 32 {return}
	n := &p.native
	for &d in n.pads {
		if node_matches(&d, name) {return}
	}
	slot := -1
	for d, i in n.pads {
		if !d.open {
			slot = i
			break
		}
	}
	path := strings.clone_to_cstring(
		strings.concatenate({INPUT_DIR, "/", name}, context.temp_allocator),
		context.temp_allocator,
	)
	fd, err := linux.open(path, {.NONBLOCK, .CLOEXEC})
	if err != .NONE {
		if err == .EACCES {log.debugf("platform pads: %s: no permission (yet)", name)}
		return
	}
	keys: [96]u8
	abs: [8]u8
	ok := ioctl_ok(fd, ioc_read(0x20 + EV_KEY, 96), &keys)
	ok &&= ioctl_ok(fd, ioc_read(0x20 + EV_ABS, 8), &abs)
	if !ok || !evdev_is_pad(keys, abs) {
		linux.close(fd)
		return
	}
	if slot < 0 {
		log.infof("platform pads: %s ignored: %d pads are connected already", name, MAX_PADS)
		linux.close(fd)
		return
	}
	id: [4]u16
	ioctl_ok(fd, EVIOCGID, &id)
	vendor, product := id[1], id[2]
	if pad_ignored(vendor, product, n.ignore, n.except) {
		log.debugf("platform pads: %s ignored (Steam presents it)", name)
		linux.close(fd)
		return
	}
	namebuf: [64]u8
	ioctl_ok(fd, ioc_read(0x06, 64), &namebuf)
	devname := string(cstring(&namebuf[0]))
	ranges: [ABS_COUNT]Evdev_Abs
	for a in 0 ..< ABS_COUNT {
		if !evdev_bit(abs[:], a) {continue}
		info: [6]i32 // value, minimum, maximum, fuzz, flat, resolution
		if ioctl_ok(fd, u32(EVIOCGABS_BASE + a), &info) {ranges[a] = {info[1], info[2]}}
	}
	d := &n.pads[slot]
	d^ = {}
	d.fd, d.open = fd, true
	copy(d.node[:], name)
	d.node_len = len(name)
	evdev_setup(&d.dev, vendor, product, devname, abs, ranges)
	pad_resync(d)
	p.state[slot] = d.dev.pending
}

// pad_resync reads the whole state of the device (opening, and after
// SYN_DROPPED).
@(private = "file")
pad_resync :: proc(d: ^Linux_Pad) {
	dev := &d.dev
	dev.pending.buttons = {}
	dev.pending.axes = {}
	dev.hat = {}
	keys: [96]u8
	if ioctl_ok(d.fd, ioc_read(0x18, 96), &keys) {
		for code in u16(BTN_SOUTH) ..= u16(BTN_DPAD_RIGHT) {
			if evdev_bit(keys[:], int(code)) {evdev_event(dev, EV_KEY, code, 1)}
		}
	}
	for a in 0 ..< ABS_COUNT {
		if !dev.has_abs[a] {continue}
		info: [6]i32
		if ioctl_ok(
			d.fd,
			u32(EVIOCGABS_BASE + a),
			&info,
		) {evdev_event(dev, EV_ABS, u16(a), info[0])}
	}
}

@(private = "file")
pad_read :: proc(p: ^Pads, i: int) {
	d := &p.native.pads[i]
	buf: [64 * 24]u8
	for {
		got, err := linux.read(d.fd, buf[:])
		if err == .EINTR {continue}
		if err == .EAGAIN {return}
		if err != .NONE || got <= 0 {
			pad_close_slot(p, i)
			return
		}
		for off := 16; off + 8 <= got; off += 24 {
			type := (^u16)(&buf[off])^
			code := (^u16)(&buf[off + 2])^
			value := (^i32)(&buf[off + 4])^
			if type == EV_SYN {
				if code == SYN_DROPPED {
					d.dropping = true
				} else if code == SYN_REPORT {
					if d.dropping {
						d.dropping = false
						pad_resync(d)
					}
					p.state[i] = d.dev.pending
				}
			} else if !d.dropping {
				evdev_event(&d.dev, type, code, value)
			}
		}
	}
}
