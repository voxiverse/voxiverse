package update

import "core:testing"

SUMS_SAMPLE :: `92ad0d95bc021892f6c5ab150b2e17686ff01a63a8b6bdbb9265aabeef968b1e  voxiverse-0.5.1-linux-x64.tar.gz
8f5ee56aba7c2170a5a2900147b23ce432b136946177297289ded0056fe6fe1d  voxiverse-0.5.1-macos-arm64.zip
ae6f9c4b2ce2067e61d1d9f495365f47b0bd336a0bb8990e3f1cbc08f9a09ecb *voxiverse-0.5.1-windows-x64.zip
`

@(test)
test_sums_find :: proc(t: ^testing.T) {
	d, ok := sums_find(SUMS_SAMPLE, "voxiverse-0.5.1-linux-x64.tar.gz")
	testing.expect(t, ok)
	testing.expect_value(t, d[0], 0x92)
	testing.expect_value(t, d[31], 0x1e)
	d, ok = sums_find(SUMS_SAMPLE, "voxiverse-0.5.1-windows-x64.zip")
	testing.expect(t, ok)
	testing.expect_value(t, d[0], 0xae)
	_, ok = sums_find(SUMS_SAMPLE, "voxiverse-0.5.1-linux-x64.tar")
	testing.expect(t, !ok, "a name the file does not have")
	_, ok = sums_find(SUMS_SAMPLE, "")
	testing.expect(t, !ok)
	d, _ = sums_find(SUMS_SAMPLE, "voxiverse-0.5.1-linux-x64.tar.gz")
	testing.expect_value(t, digest_text(d), SUMS_SAMPLE[:64])
}

// Anything but sha256sum's lines refuses the whole file, and so does a name given twice.
@(test)
test_sums_refuse :: proc(t: ^testing.T) {
	name :: "a.zip"
	sum :: "92ad0d95bc021892f6c5ab150b2e17686ff01a63a8b6bdbb9265aabeef968b1e"
	_, ok := sums_find(sum + "  a.zip\r\n\n", name)
	testing.expect(t, ok, "CRLF and blank lines are fine")
	bad := []string {
		sum + "  a.zip\n" + sum + "  a.zip\n",
		sum + " a.zip\n",
		sum + "\ta.zip\n",
		sum[:63] + "  a.zip\n",
		sum[:63] + "g  a.zip\n",
		sum + "  a.zip\n<html>\n",
		"",
	}
	for text in bad {
		_, bad_ok := sums_find(text, name)
		testing.expectf(t, !bad_ok, "%q was read", text)
	}
}
