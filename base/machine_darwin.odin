#+build darwin
package base

import "core:fmt"
import "core:sys/unix"

// machine_facts: the CPU, its cores and the OS, for benchmark results, from
// the kernel (machine_other.odin says why not core:sys/info here).
@(private)
machine_facts :: proc(
	allocator := context.temp_allocator,
) -> (
	cpu: string,
	cores, threads: int,
	os: string,
) {
	brand: [256]u8
	if unix.sysctlbyname("machdep.cpu.brand_string", &brand) {cpu = fmt.tprint(cstring(&brand[0]))}
	physical, logical: i32
	if unix.sysctlbyname("hw.physicalcpu", &physical) {cores = int(physical)}
	if unix.sysctlbyname("hw.logicalcpu", &logical) {threads = int(logical)}
	version: [64]u8
	if unix.sysctlbyname("kern.osproductversion", &version) {
		os = fmt.aprintf("macOS %s", cstring(&version[0]), allocator = allocator)
	} else {
		os = "macOS"
	}
	return
}
