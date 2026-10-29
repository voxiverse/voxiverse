package platform

import "core:dynlib"
import "core:log"
import "core:time"

// Windows gamepads through XInput, loaded at run time (xinput1_4.dll, else
// xinput9_1_0.dll: both ship with Windows) so the executable imports no
// XInput DLL. The four user slots are the pad slots. A slot that answers
// "not connected" is probed again at most every 250 ms, one slot per probe
// (reading an empty slot stalls).

XINPUT_PROBE_INTERVAL :: 250 * time.Millisecond

@(private = "file")
Get_State :: #type proc "system" (user: u32, state: ^Xinput_State) -> u32

Native_Pads :: struct {
	lib:        dynlib.Library,
	get_state:  Get_State,
	last_probe: time.Tick,
	next_probe: int,
}

native_pads_open :: proc(p: ^Pads) {
	n := &p.native
	for name in ([?]string{"xinput1_4.dll", "xinput9_1_0.dll"}) {
		lib, ok := dynlib.load_library(name)
		if !ok {continue}
		proc_ptr, found := dynlib.symbol_address(lib, "XInputGetState")
		if !found {
			dynlib.unload_library(lib)
			continue
		}
		n.lib = lib
		n.get_state = cast(Get_State)proc_ptr
		break
	}
	if n.get_state == nil {log.info("platform pads: XInput not found: no gamepads")}
	n.last_probe = time.tick_now()
}

native_pads_close :: proc(p: ^Pads) {
	n := &p.native
	if n.lib != nil {dynlib.unload_library(n.lib)}
	n^ = {}
}

native_pads_poll :: proc(p: ^Pads) {
	n := &p.native
	if n.get_state == nil {return}
	probe := time.tick_diff(n.last_probe, time.tick_now()) >= XINPUT_PROBE_INTERVAL
	probed := false
	for i in 0 ..< MAX_PADS {
		if !p.state[i].connected {
			if !probe || probed || i != n.next_probe {continue}
			probed = true
			n.next_probe = (n.next_probe + 1) % MAX_PADS
		}
		x: Xinput_State
		if n.get_state(u32(i), &x) == 0 {
			p.state[i] = xinput_to_state(
				x.buttons,
				x.left_trigger,
				x.right_trigger,
				x.lx,
				x.ly,
				x.rx,
				x.ry,
			)
		} else {
			p.state[i] = {}
		}
	}
	if probe {n.last_probe = time.tick_now()}
}
