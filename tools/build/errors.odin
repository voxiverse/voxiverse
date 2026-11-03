package build

import "core:fmt"
import "core:strings"

// Failed_Log: the output of one failed `check` job and the target it was built for.
Failed_Log :: struct {
	target: string,
	text:   string,
}

// Error_Group: one distinct compiler message and the targets that reported it.
Error_Group :: struct {
	key:     string, // its first line, without trailing blanks
	block:   string, // the message with its source excerpt, as first printed
	targets: [dynamic]string,
}

// is_diagnostic_line: whether a line opens a compiler message (`path(line:col) Error: ...`).
is_diagnostic_line :: proc(line: string) -> bool {
	for mark in ([]string{") Error:", ") Syntax Error:", ") Warning:"}) {
		if strings.contains(line, mark) {return true}
	}
	return false
}

// group_errors merges the failed jobs' logs: each distinct message (its first line, which
// carries the file, line, column and text, is the key) is printed once, followed by the
// targets that failed on it. A package's error reached by several targets is thus one
// block, not one per target. Lines outside any message are kept as their own blocks.
group_errors :: proc(logs: []Failed_Log, allocator := context.temp_allocator) -> string {
	groups := make([dynamic]Error_Group, allocator)
	for log in logs {
		lines := strings.split_lines(strings.trim_right(log.text, "\r\n"), allocator)
		i := 0
		for i < len(lines) {
			j := i + 1
			if is_diagnostic_line(lines[i]) {
				// the excerpt: indented lines follow the message
				for j < len(lines) &&
				    len(lines[j]) > 0 &&
				    (lines[j][0] == '\t' || lines[j][0] == ' ') {
					j += 1
				}
			}
			key := strings.trim_right(lines[i], " \t\r")
			if len(key) > 0 {
				found := -1
				for g, k in groups {
					if g.key == key {found = k; break}
				}
				if found < 0 {
					append(
						&groups,
						Error_Group {
							key = key,
							block = strings.join(lines[i:j], "\n", allocator),
							targets = make([dynamic]string, allocator),
						},
					)
					found = len(groups) - 1
				}
				g := &groups[found]
				seen := false
				for t in g.targets {if t == log.target {seen = true}}
				if !seen {append(&g.targets, log.target)}
			}
			i = j
		}
	}
	b := strings.builder_make(allocator)
	for g in groups {
		fmt.sbprintln(&b, g.block)
		fmt.sbprintfln(&b, "  failed on: %s", strings.join(g.targets[:], ", ", allocator))
	}
	return strings.to_string(b)
}
