package platform_common

import "core:fmt"
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

@(test)
test_boot_reads_the_directories :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	exe, err := os.get_executable_directory(context.temp_allocator)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, host.boot.dirs.exe, exe)
	testing.expect(t, host.boot.dirs.exe != "")
	testing.expect_value(t, base.boot_info().dirs, host.boot.dirs)
}

@(test)
test_boot_reads_the_machine :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect(t, host.boot.machine.os != "")
	testing.expect(t, host.boot.machine.threads > 0)
	testing.expect_value(t, base.boot_info().machine, host.boot.machine)
}

@(test)
test_boot_installs_the_clocks :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect(t, host.clock.thread_cpu_us != nil)
	testing.expect(t, host.clock.ticks != nil)
	a := base.thread_cpu_us()
	spin := 0
	for i in 0 ..< 2_000_000 {spin += i}
	testing.expect(t, base.thread_cpu_us() >= a)
	testing.expect(t, spin != 0)
	b := base.ticks()
	testing.expect(t, base.ticks() >= b)
}

@(test)
test_boot_installs_the_file_lock :: proc(t: ^testing.T) {
	host: base.Host
	boot(&host)
	testing.expect(t, host.file.lock != nil)
	testing.expect(t, host.file.unlock != nil)
	path := fmt.tprintf("vx_boot_lock_%d", host.boot.pid) // relative: /tmp does not exist on Windows
	defer os.remove(path)
	first, _, ok := base.file_lock(path, "mine")
	testing.expect(t, ok)
	_, holder, again := base.file_lock(path, "other")
	testing.expect(t, !again)
	// The holder's text is read back on POSIX; Windows opens the lock with no sharing, so nobody
	// else can read it ("" by contract: lock_windows.odin).
	when ODIN_OS == .Windows {
		testing.expect_value(t, holder, "")
	} else {
		testing.expect_value(t, holder, "mine")
	}
	delete(holder)
	base.file_unlock(&first)
	second, _, retaken := base.file_lock(path, "")
	testing.expect(t, retaken)
	base.file_unlock(&second)
}
