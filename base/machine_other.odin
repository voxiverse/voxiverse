#+build !darwin
package base

import "core:fmt"
import si "core:sys/info"

// machine_facts: the CPU, its cores and the OS, for benchmark results.
// (On macOS core:sys/info reads the OS version through the Objective-C
// runtime, which trips this Odin's compiler: machine_darwin.odin asks the
// kernel instead.)
@(private)
machine_facts :: proc(
	allocator := context.temp_allocator,
) -> (
	cpu: string,
	cores, threads: int,
	os: string,
) {
	cpu = si.cpu_name()
	if physical, logical, ok := si.cpu_core_count(); ok {cores, threads = physical, logical}
	if v, ok := si.os_version(allocator); ok {os = v.full} else {os = fmt.tprint(ODIN_OS)}
	return
}
