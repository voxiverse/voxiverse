package fuzz

// The minimizer: removes runs (halving, then single bytes) and replaces bytes with 0 while
// the same failure holds. The check says which failure a candidate causes ("" for none), by
// running it in a child process (the tool) or in this one (the tests).

Check_Proc :: proc(candidate: []u8, user: rawptr) -> string

minimize :: proc(data: []u8, check: Check_Proc, user: rawptr) -> []u8 {
	want := check(data, user)
	cur := clone_bytes(data)
	if want == "" {return cur}
	changed := true
	for changed {
		changed = false
		for size := max(len(cur) / 2, 1); size >= 1; size /= 2 {
			at := 0
			for at < len(cur) {
				n := min(size, len(cur) - at)
				cand := make([]u8, len(cur) - n)
				copy(cand, cur[:at])
				copy(cand[at:], cur[at + n:])
				if check(cand, user) == want {
					delete(cur)
					cur = cand
					changed = true
				} else {
					delete(cand)
					at += n
				}
			}
			if size == 1 {break}
		}
		for i in 0 ..< len(cur) {
			if cur[i] == 0 {continue}
			old := cur[i]
			cur[i] = 0
			if check(cur, user) == want {
				changed = true
			} else {
				cur[i] = old
			}
		}
	}
	return cur
}
