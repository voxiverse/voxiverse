package update

import "core:strings"

// Reading GitHub's list of releases (GET /repos/<owner>/<repo>/releases): untrusted input,
// read by a scanner of our own that keeps only what the updater needs (each release's
// tag, whether it is a draft, and its assets' names, download addresses and sizes) and
// passes over everything else (the notes, the authors, the reactions). It recurses on
// nothing: nesting is a stack of at most JSON_DEPTH_MAX levels, so a hostile reply
// cannot exhaust the thread's stack, and every count is capped. The strings point into
// the text read; a string with an escape in it is never one the updater keeps (names,
// tags and addresses of ours have none), so nothing is copied.

RELEASES_TEXT_MAX :: 4 << 20 // the reply's bytes at most (curl's --max-filesize too)
RELEASES_MAX :: 100 // releases kept; the rest are passed over
ASSETS_MAX :: 32 // assets kept of each release
JSON_DEPTH_MAX :: 64
ASSET_SIZE_MAX :: 1 << 40

Asset :: struct {
	name: string,
	url:  string, // browser_download_url
	size: i64, // bytes; -1 when the reply gave none that reads as one
}

Release :: struct {
	tag:    string,
	draft:  bool,
	assets: []Asset, // a slice of Releases.assets
}

Releases :: struct {
	list:   [dynamic]Release,
	assets: [dynamic]Asset,
}

releases_destroy :: proc(r: ^Releases) {
	delete(r.list)
	delete(r.assets)
}

// What a JSON container is to the reader.
@(private = "file")
Role :: enum u8 {
	Other, // passed over
	List, // the reply: an array of releases
	Release,
	Assets, // a release's "assets"
	Asset,
}

@(private = "file")
Frame :: struct {
	role:   Role,
	object: bool,
	key:    string, // an object's member being read (its raw text)
	state:  Expect,
	index:  int, // the release or asset this frame fills (-1: none)
}

@(private = "file")
Expect :: enum u8 {
	Value_Or_End, // after [ (arrays) or { (objects: a key)
	Value, // after a key's colon, or a comma in an array
	Key, // after a comma in an object
	Comma_Or_End,
}

@(private = "file")
Scalar :: struct {
	text:    string, // a string's raw content, or the literal or number
	quoted:  bool, // a string
	escaped: bool, // ... with an escape in it
}

// releases_read reads the reply. ok is false when it is not one well-formed JSON array
// within the caps; then nothing in it is used. The lists are allocated with allocator
// (releases_destroy frees them) and point into text.
releases_read :: proc(text: string, allocator := context.allocator) -> (r: Releases, ok: bool) {
	r.list = make([dynamic]Release, allocator)
	r.assets = make([dynamic]Asset, allocator)
	if len(text) > RELEASES_TEXT_MAX {return r, false}
	asset_from := make([dynamic]int, allocator) // each release's first asset
	defer delete(asset_from)
	stack: [JSON_DEPTH_MAX]Frame
	depth := 0
	pos := 0
	done := false // the reply's value is read
	list := false // ... and it is an array
	for {
		pos = skip_space(text, pos)
		if pos >= len(text) {break}
		if done {return r, false} 	// text after the value
		c := text[pos]
		if depth > 0 {
			f := &stack[depth - 1]
			if c == ']' || c == '}' {
				// The end: of this container's kind, and not after a comma or a colon.
				if (c == '}') != f.object || f.state == .Key || f.state == .Value {
					return r, false
				}
				pos += 1
				depth -= 1
				if depth == 0 {done = true} else {stack[depth - 1].state = .Comma_Or_End}
				continue
			}
			if f.state == .Comma_Or_End {
				if c != ',' {return r, false}
				f.state = .Key if f.object else .Value
				pos += 1
				continue
			}
			if f.object && f.state != .Value {
				// A key, then its colon.
				key, next, key_ok := read_string(text, pos)
				if !key_ok {return r, false}
				pos = skip_space(text, next)
				if pos >= len(text) || text[pos] != ':' {return r, false}
				pos += 1
				f.key = key.text if !key.escaped else ""
				f.state = .Value
				continue
			}
		}
		// A value, of the frame on top (none: the whole reply).
		parent: ^Frame = &stack[depth - 1] if depth > 0 else nil
		if parent != nil {parent.state = .Comma_Or_End}
		if c == '[' || c == '{' {
			if depth == JSON_DEPTH_MAX {return r, false}
			role := child_role(parent, c == '{')
			index := -1
			switch role {
			case .List:
				list = true
			case .Release:
				if len(r.list) < RELEASES_MAX {
					index = len(r.list)
					append(&r.list, Release{})
					append(&asset_from, len(r.assets))
				} else {
					role = .Other
				}
			case .Assets:
				index = parent.index
			case .Asset:
				// (parent: the release's assets, its index the release's)
				if len(r.assets) - asset_from[parent.index] < ASSETS_MAX {
					index = len(r.assets)
					append(&r.assets, Asset{size = -1})
				} else {
					role = .Other
				}
			case .Other:
			}
			stack[depth] = {
				role   = role,
				object = c == '{',
				state  = .Value_Or_End,
				index  = index,
			}
			depth += 1
			pos += 1
			continue
		}
		value: Scalar
		next: int
		value_ok: bool
		switch c {
		case '"':
			value, next, value_ok = read_string(text, pos)
		case 't', 'f', 'n':
			value, next, value_ok = read_literal(text, pos)
		case:
			value, next, value_ok = read_number(text, pos)
		}
		if !value_ok {return r, false}
		pos = next
		if parent == nil {
			done = true // (a lone value: no list, refused below)
			continue
		}
		if parent.index < 0 || !parent.object || value.escaped {continue}
		#partial switch parent.role {
		case .Release:
			rel := &r.list[parent.index]
			switch {
			case parent.key == "tag_name" && value.quoted:
				rel.tag = value.text
			case parent.key == "draft" && !value.quoted:
				rel.draft = value.text == "true"
			}
		case .Asset:
			a := &r.assets[parent.index]
			switch {
			case parent.key == "name" && value.quoted:
				a.name = value.text
			case parent.key == "browser_download_url" && value.quoted:
				a.url = value.text
			case parent.key == "size" && !value.quoted:
				a.size = size_parse(value.text)
			}
		}
	}
	if !done || !list {return r, false}
	for &rel, i in r.list {
		to := asset_from[i + 1] if i + 1 < len(asset_from) else len(r.assets)
		rel.assets = r.assets[asset_from[i]:to]
	}
	return r, true
}

// child_role: what a container opened as a value of parent is.
@(private = "file")
child_role :: proc(parent: ^Frame, object: bool) -> Role {
	if parent == nil {return .List if !object else .Other}
	switch parent.role {
	case .List:
		if object {return .Release}
	case .Release:
		if !object && parent.key == "assets" && parent.index >= 0 {return .Assets}
	case .Assets:
		if object {return .Asset}
	case .Asset, .Other:
	}
	return .Other
}

@(private = "file")
skip_space :: proc(text: string, pos: int) -> int {
	pos := pos
	for pos < len(text) {
		switch text[pos] {
		case ' ', '\t', '\n', '\r':
			pos += 1
		case:
			return pos
		}
	}
	return pos
}

// read_string: the string at pos (its opening quote), its raw content and where it ends.
@(private = "file")
read_string :: proc(text: string, pos: int) -> (s: Scalar, next: int, ok: bool) {
	if pos >= len(text) || text[pos] != '"' {return}
	s.quoted = true
	i := pos + 1
	for i < len(text) {
		c := text[i]
		switch {
		case c == '"':
			s.text = text[pos + 1:i]
			return s, i + 1, true
		case c < 0x20:
			return
		case c == '\\':
			s.escaped = true
			if i + 1 >= len(text) {return}
			switch text[i + 1] {
			case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
				i += 2
			case 'u':
				if i + 6 > len(text) {return}
				for h in transmute([]u8)text[i + 2:i + 6] {
					if !is_hex(h) {return}
				}
				i += 6
			case:
				return
			}
		case:
			i += 1
		}
	}
	return
}

@(private = "file")
read_literal :: proc(text: string, pos: int) -> (s: Scalar, next: int, ok: bool) {
	for word in ([]string{"true", "false", "null"}) {
		if strings.has_prefix(text[pos:], word) {
			return {text = word}, pos + len(word), true
		}
	}
	return
}

// read_number: JSON's grammar: -?(0|[1-9][0-9]*)(.[0-9]+)?([eE][+-]?[0-9]+)?
@(private = "file")
read_number :: proc(text: string, pos: int) -> (s: Scalar, next: int, ok: bool) {
	i := pos
	digits :: proc(text: string, i: ^int) -> int {
		from := i^
		for i^ < len(text) && text[i^] >= '0' && text[i^] <= '9' {i^ += 1}
		return i^ - from
	}
	if i < len(text) && text[i] == '-' {i += 1}
	if i < len(text) && text[i] == '0' {
		i += 1
	} else if digits(text, &i) == 0 {
		return
	}
	if i < len(text) && text[i] == '.' {
		i += 1
		if digits(text, &i) == 0 {return}
	}
	if i < len(text) && (text[i] == 'e' || text[i] == 'E') {
		i += 1
		if i < len(text) && (text[i] == '+' || text[i] == '-') {i += 1}
		if digits(text, &i) == 0 {return}
	}
	return {text = text[pos:i]}, i, true
}

// size_parse: a plain count of bytes (no sign, fraction or exponent), else -1.
@(private = "file")
size_parse :: proc(text: string) -> i64 {
	if len(text) == 0 || len(text) > 15 {return -1}
	n: i64
	for c in transmute([]u8)text {
		if c < '0' || c > '9' {return -1}
		n = n * 10 + i64(c - '0')
	}
	return n if n <= ASSET_SIZE_MAX else -1
}

@(private)
is_hex :: proc(c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}
