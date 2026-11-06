package game

import "core:strconv"
import "core:strings"

// Admins: who admins.cfg names, for the server and the collector. One entry per line: an
// account public key in hex (64 digits) or `steam:<SteamID64>`; `#` starts a comment.
Admins :: struct {
	accounts: map[Account]struct{},
	steam:    map[u64]struct{},
}

admins_destroy :: proc(a: ^Admins) {
	delete(a.accounts)
	delete(a.steam)
	a^ = {}
}

// admins_parse replaces the entries with those of text. It returns the lines it could not
// read (counted; the caller logs).
admins_parse :: proc(a: ^Admins, text: string) -> (bad: int) {
	clear(&a.accounts)
	clear(&a.steam)
	rest := text
	for line in strings.split_lines_iterator(&rest) {
		t := line
		if hash := strings.index_byte(t, '#'); hash >= 0 {t = t[:hash]}
		t = strings.trim_space(t)
		if t == "" {continue}
		if strings.has_prefix(t, "steam:") {
			id, ok := strconv.parse_u64(t[len("steam:"):])
			if ok && id != 0 {
				a.steam[id] = {}
			} else {
				bad += 1
			}
		} else if acc, ok := account_parse(t); ok {
			a.accounts[acc] = {}
		} else {
			bad += 1
		}
	}
	return
}

// is_admin: whether account is listed, or steam_id is. Pass a steam_id only when Steam has
// checked it for this very connection (0: none); an ID a client merely claims is not trusted.
is_admin :: proc(a: ^Admins, account: Account, steam_id: u64 = 0) -> bool {
	if account in a.accounts {return true}
	return steam_id != 0 && steam_id in a.steam
}
