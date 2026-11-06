package platform_common

import "core:os"
import "core:testing"

import "common:base"

@(test)
test_boot_reads_the_arguments :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect_value(t, len(host.boot.args), len(os.args) - 1)
	for arg, i in host.boot.args {testing.expect_value(t, arg, os.args[i + 1])}
}

@(test)
test_boot_installs_the_output :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect(t, host.output.write != nil)
	testing.expect(t, host.output.is_color != nil)
}

@(test)
test_boot_installs_the_entropy :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect(t, host.entropy != nil)
	a, b: [32]u8
	base.entropy_fill(a[:])
	base.entropy_fill(b[:])
	testing.expect(t, a != b)
}
