#+build !darwin
package platform_common

import "base:runtime"
import "core:fmt"
import si "core:sys/info"

// machine_facts: the CPU, its cores and the OS, for benchmark results.
// (On macOS core:sys/info reads the OS version through the Objective-C
// runtime, which trips this Odin's compiler: machine_darwin.odin asks the
// kernel instead.)
@(private)
machine_facts :: proc() -> (cpu: string, cores, threads: int, os: string) {
	allocator := runtime.heap_allocator() // lives as long as the process

	cpu = si.cpu_name()
	if physical, logical, ok := si.cpu_core_count(); ok {cores, threads = physical, logical}
	if v, ok := si.os_version(allocator);
	   ok {os = v.full} else {os = fmt.aprint(ODIN_OS, allocator = allocator)}
	return
}
