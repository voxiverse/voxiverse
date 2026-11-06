package game

import "core:fmt"
import "core:testing"

@(test)
test_admins_parse :: proc(t: ^testing.T) {
	key := account_key_make()
	a: Admins
	defer admins_destroy(&a)
	text := fmt.tprintf(
		"# owner\n%s # me\nsteam:76561198000000001 # steam\nsteam:0\nsteam:abc\nnot a key\n",
		account_text(key.account),
	)
	bad := admins_parse(&a, text)
	testing.expect_value(t, bad, 3)
	testing.expect(t, is_admin(&a, key.account))
	other := account_key_make()
	testing.expect(t, !is_admin(&a, other.account))
	testing.expect(t, is_admin(&a, other.account, 76561198000000001))
	testing.expect(t, !is_admin(&a, other.account, 76561198000000002))
	testing.expect(t, !is_admin(&a, other.account, 0))
}
