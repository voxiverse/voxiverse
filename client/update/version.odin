package update

import "core:strconv"
import "core:strings"

// Version: a release's version as its tag gives it, "0.5.3" or "0.4.0-flood.5": three
// numbers and an optional pre-release part (semver's, without build metadata: a "+"
// is a development build's, which no release has).
Version :: struct {
	numbers: [3]u32,
	pre:     string, // after the "-"; "" for none (a slice of the text parsed)
}

VERSION_TEXT_MAX :: 64
VERSION_NUMBER_MAX :: 999_999

// version_parse reads "X.Y.Z" or "X.Y.Z-pre" (pre: dot-separated identifiers of
// letters, digits and "-"). Anything else, a "+" included, is refused.
version_parse :: proc(text: string) -> (v: Version, ok: bool) {
	if len(text) == 0 || len(text) > VERSION_TEXT_MAX {return}
	core := text
	if i := strings.index_byte(text, '-'); i >= 0 {
		core, v.pre = text[:i], text[i + 1:]
		if !pre_valid(v.pre) {return}
	}
	rest := core
	for i in 0 ..< 3 {
		part := rest
		if i < 2 {
			dot := strings.index_byte(rest, '.')
			if dot < 0 {return}
			part, rest = rest[:dot], rest[dot + 1:]
		}
		n, number_ok := number_parse(part)
		if !number_ok {return}
		v.numbers[i] = n
	}
	return v, true
}

// version_newer: a comes after b. The numbers decide first; with the same numbers a
// version without a pre-release part comes after one with (0.4.0 after 0.4.0-flood.5),
// and two pre-releases go by semver's order of their identifiers.
version_newer :: proc(a, b: Version) -> bool {
	for i in 0 ..< 3 {
		if a.numbers[i] != b.numbers[i] {return a.numbers[i] > b.numbers[i]}
	}
	if a.pre == b.pre {return false}
	if a.pre == "" {return true}
	if b.pre == "" {return false}
	return pre_after(a.pre, b.pre)
}

// number_parse: a number without a sign or leading zeros, at most VERSION_NUMBER_MAX.
@(private)
number_parse :: proc(s: string) -> (n: u32, ok: bool) {
	if len(s) == 0 || len(s) > 6 || (len(s) > 1 && s[0] == '0') {return}
	for c in transmute([]u8)s {if c < '0' || c > '9' {return}}
	value, _ := strconv.parse_uint(s, 10)
	return u32(value), value <= VERSION_NUMBER_MAX
}

@(private = "file")
pre_valid :: proc(pre: string) -> bool {
	if len(pre) == 0 {return false}
	part_len := 0
	for c in transmute([]u8)pre {
		switch c {
		case '.':
			if part_len == 0 {return false}
			part_len = 0
		case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '-':
			part_len += 1
		case:
			return false
		}
	}
	return part_len > 0
}

// pre_after: semver's precedence of two pre-release parts: identifier by identifier,
// numbers as numbers and below words, words by their bytes; a longer list after its
// own beginning.
@(private = "file")
pre_after :: proc(a, b: string) -> bool {
	ra, rb := a, b
	for {
		pa, more_a := strings.split_iterator(&ra, ".")
		pb, more_b := strings.split_iterator(&rb, ".")
		if !more_a || !more_b {return more_a && !more_b}
		if pa == pb {continue}
		na, a_number := number_parse(pa)
		nb, b_number := number_parse(pb)
		switch {
		case a_number && b_number:
			return na > nb
		case a_number != b_number:
			return b_number
		case:
			return pa > pb
		}
	}
}
