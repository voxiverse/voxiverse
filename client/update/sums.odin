package update

import "core:strings"

// Reading a release's SHA256SUMS: untrusted input. It is `sha256sum`'s output (the
// release workflow writes it): a line per file, 64 hexadecimal digits, a space, a space
// or "*", and the file's name. A file of anything else is refused whole.

SUMS_TEXT_MAX :: 64 << 10
SUMS_LINES_MAX :: 256

Digest :: [32]u8

// sums_find: the digest the file gives name. ok is false when the file is not
// well-formed, too long, or names it never or twice.
sums_find :: proc(text: string, name: string) -> (digest: Digest, ok: bool) {
	if len(text) > SUMS_TEXT_MAX {return}
	found := false
	lines := 0
	rest := text
	for len(rest) > 0 {
		line := rest
		if i := strings.index_byte(rest, '\n'); i >= 0 {
			line, rest = rest[:i], rest[i + 1:]
		} else {
			rest = ""
		}
		if len(line) > 0 && line[len(line) - 1] == '\r' {line = line[:len(line) - 1]}
		if len(line) == 0 {continue}
		lines += 1
		if lines > SUMS_LINES_MAX {return {}, false}
		if len(line) < 67 || line[64] != ' ' || (line[65] != ' ' && line[65] != '*') {
			return {}, false
		}
		d, hex_ok := hex_digest(line[:64])
		if !hex_ok {return {}, false}
		if line[66:] == name {
			if found {return {}, false}
			digest, found = d, true
		}
	}
	return digest, found
}

// hex_digest: 64 hexadecimal digits as the 32 bytes they spell.
hex_digest :: proc(text: string) -> (d: Digest, ok: bool) {
	if len(text) != 64 {return}
	for i in 0 ..< 32 {
		hi, hi_ok := hex_value(text[2 * i])
		lo, lo_ok := hex_value(text[2 * i + 1])
		if !hi_ok || !lo_ok {return}
		d[i] = hi << 4 | lo
	}
	return d, true
}

@(private = "file")
hex_value :: proc(c: u8) -> (u8, bool) {
	switch c {
	case '0' ..= '9':
		return c - '0', true
	case 'a' ..= 'f':
		return c - 'a' + 10, true
	case 'A' ..= 'F':
		return c - 'A' + 10, true
	}
	return 0, false
}
