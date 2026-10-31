package base

import "core:os"
import "core:strconv"
import "core:strings"

// resident_memory is the process's resident memory in bytes (0 where the OS
// does not tell us cheaply).
resident_memory :: proc() -> int {
	data, err := os.read_entire_file_from_path("/proc/self/status", context.temp_allocator)
	if err != nil {return 0}
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if !strings.has_prefix(line, "VmRSS:") {continue}
		fields := strings.fields(line, context.temp_allocator) // VmRSS: <n> kB
		if len(fields) < 2 {return 0}
		kb, ok := strconv.parse_int(fields[1])
		return kb * 1024 if ok else 0
	}
	return 0
}
