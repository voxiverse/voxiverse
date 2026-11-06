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

@(test)
test_boot_reads_the_process_and_environment :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect_value(t, host.boot.pid, os.get_pid())
	testing.expect_value(t, host.boot.cpu_count, os.get_processor_core_count())
	testing.expect_value(t, base.boot_info().pid, host.boot.pid)
	value, set := os.lookup_env("VX_SETTINGS", context.temp_allocator)
	got, got_set := host.boot.env.settings.?
	testing.expect_value(t, got_set, set)
	if set {testing.expect_value(t, got, value)}
}
