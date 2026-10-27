package game

import "core:strconv"
import "core:strings"

// Permissions: what a player may do is a set of nodes, dotted names
// ("chat.format", "world.edit.bulk"). Grants name nodes or patterns: a
// trailing "*" covers everything under ("chat.*", or "*" for all), a
// leading "-" denies. A player's grants come from their own and their
// roles' (the server's permissions.cfg); resolved, each carries the rank
// of where it came from (0: the player's own; 1, 2, ...: their roles, and
// the roles those inherit, further down).
//
// Which grant decides a node: the most specific that matches (an exact
// node over a wildcard at the same depth, a deeper wildcard over a
// shallower one); among equals, the nearer source (lower rank); then a
// denial over an allow. No grant matching: not allowed.
//
// The server resolves and decides; it sends each player their resolved
// grants (Grants), and the client asks the same question so as not to
// offer what the server would refuse.

Grant :: struct {
	pattern: string, // "chat.format", "chat.*", "*"
	allow:   bool,
	rank:    int,
}

// grant_parse: "-chat.*" -> a denial of chat.*.
grant_parse :: proc(text: string, rank: int) -> (g: Grant, ok: bool) {
	t := strings.trim_space(text)
	g.allow = true
	if strings.has_prefix(t, "-") {
		g.allow = false
		t = t[1:]
	}
	if !node_pattern_valid(t) {return}
	g.pattern, g.rank = t, rank
	return g, true
}

// node_pattern_valid: lowercase dotted words (letters, digits, _), and at
// most one "*", as the last part.
node_pattern_valid :: proc(p: string) -> bool {
	if len(p) == 0 || len(p) > 64 {return false}
	parts := strings.split(p, ".", context.temp_allocator)
	for part, i in parts {
		if part == "*" {
			if i != len(parts) - 1 {return false}
			continue
		}
		if len(part) == 0 {return false}
		for c in transmute([]u8)part {
			if !((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_') {return false}
		}
	}
	return true
}

// pattern_match: whether pattern covers node, and how specifically (higher:
// more specific; exact nodes are odd, wildcards even).
pattern_match :: proc(pattern, node: string) -> (specificity: int, ok: bool) {
	if pattern == "*" {return 0, true}
	if strings.has_suffix(pattern, ".*") {
		stem := pattern[:len(pattern) - 2]
		if node == stem ||
		   (strings.has_prefix(node, stem) && len(node) > len(stem) && node[len(stem)] == '.') {
			return 2 * (strings.count(stem, ".") + 1), true
		}
		return 0, false
	}
	if pattern == node {return 2 * (strings.count(node, ".") + 1) + 1, true}
	return 0, false
}

// allowed: whether grants allow node.
allowed :: proc(grants: []Grant, node: string) -> bool {
	best: Maybe(Grant)
	best_specificity := -1
	for g in grants {
		specificity, ok := pattern_match(g.pattern, node)
		if !ok {continue}
		b, have := best.?
		better :=
			!have ||
			specificity > best_specificity ||
			(specificity == best_specificity && g.rank < b.rank) ||
			(specificity == best_specificity && g.rank == b.rank && !g.allow && b.allow)
		if better {
			best, best_specificity = g, specificity
		}
	}
	g, have := best.?
	return have && g.allow
}

// grants_text: grants as lines of "rank pattern" (denials with "-"), for
// the Grants message.
grants_text :: proc(grants: []Grant, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	for g in grants {
		strings.write_int(&b, g.rank)
		strings.write_byte(&b, ' ')
		if !g.allow {strings.write_byte(&b, '-')}
		strings.write_string(&b, g.pattern)
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// grants_parse reads grants_text's lines (patterns cloned with allocator);
// false at a bad line.
grants_parse :: proc(text: string, out: ^[dynamic]Grant, allocator := context.allocator) -> bool {
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		if strings.trim_space(line) == "" {continue}
		space := strings.index_byte(line, ' ')
		if space < 0 {return false}
		rank := strconv.parse_int(line[:space]) or_return
		g := grant_parse(line[space + 1:], rank) or_return
		g.pattern = strings.clone(g.pattern, allocator)
		append(out, g)
	}
	return true
}
