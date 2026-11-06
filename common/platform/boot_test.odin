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
