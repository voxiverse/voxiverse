package update

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:thread"

import "common:limited"

@(test)
test_curl_command :: proc(t: ^testing.T) {
	cmd := curl_command(
		{curl = "/usr/bin/curl"},
		{url = "https://x/y", proto = "=https", max = 100, seconds = 30, out = "f"},
	)
	line := strings.join(cmd, " ", context.temp_allocator)
	for want in ([]string{"/usr/bin/curl --disable ", "--proto =https --proto-redir =https --tlsv1.2 --fail --location --max-redirs 5 --max-filesize 100 ", "--max-time 30 ", "--user-agent voxiverse-updater ", "--output f -- https://x/y"}) {
		testing.expectf(t, strings.contains(line, want), "%q lacks %q", line, want)
	}
	testing.expect_value(t, cmd[len(cmd) - 1], "https://x/y")
}

// The restart leaves out what does one thing and keeps the rest.
@(test)
test_restart_args :: proc(t: ^testing.T) {
	args := []string {
		"--null-audio",
		"--exec",
		"update install; quit",
		"--game=flood",
		"--check=fly",
		"--version",
		"--frames",
		"300",
		"--capture_frame",
		"4",
		"-scene:title",
	}
	got := strings.join(restart_args(args), " ", context.temp_allocator)
	testing.expect_value(t, got, "--null-audio --game=flood --frames 300")
}

// The fake release folder of the end-to-end tests: releases.json listing v<version> with
// a Linux package of LAYOUT_LINUX whose files hold text, and its SHA256SUMS (sums: what
// it says, "" for the true one).
@(private = "file")
fake_release :: proc(t: ^testing.T, dir, version, text, sums: string) -> (source: Source) {
	os.make_directory_all(dir)
	absolute, _ := os.get_absolute_path(dir, context.temp_allocator)
	source = {
		list     = strings.concatenate(
			{"file://", absolute, "/releases.json"},
			context.temp_allocator,
		),
		download = strings.concatenate(
			{"file://", absolute, "/download/"},
			context.temp_allocator,
		),
	}
	tag := strings.concatenate({"v", version}, context.temp_allocator)
	folder := fmt.tprintf("voxiverse-%s-linux-x64", version)
	files := join(dir, "download", tag)
	package_tree(join(dir, "pkg"), folder, LAYOUT_LINUX, text)
	os.make_directory_all(files)
	archive := join(files, strings.concatenate({folder, ".tar.gz"}, context.temp_allocator))
	state, _, _, _ := limited.exec(
		{command = {"tar", "-czf", archive, "-C", join(dir, "pkg"), folder}},
		context.temp_allocator,
	)
	testing.expect(t, state.exited && state.exit_code == 0, "tar")
	digest, _ := file_sha256(archive)
	b := strings.builder_make(context.temp_allocator)
	for d in digest {fmt.sbprintf(&b, "%02x", d)}
	sum := sums if sums != "" else strings.to_string(b)
	_ = os.write_entire_file(
		join(files, SUMS_NAME),
		transmute([]u8)fmt.tprintf("%s  %s.tar.gz\n", sum, folder),
	)
	info, _ := os.stat(archive, context.temp_allocator)
	list := fmt.tprintf(
		`[{{"tag_name":"%s","draft":false,"assets":[{{"name":"%s","size":10,"browser_download_url":"%s%s/%s"}},{{"name":"%s.tar.gz","size":%d,"browser_download_url":"%s%s/%s.tar.gz"}}]}}]`,
		tag,
		SUMS_NAME,
		source.download,
		tag,
		SUMS_NAME,
		folder,
		info.size,
		source.download,
		tag,
		folder,
	)
	_ = os.write_entire_file(join(dir, "releases.json"), transmute([]u8)list)
	return
}

@(private = "file")
fake_updater :: proc(u: ^Updater, source: Source, install_dir, current: string) {
	tools, _ := tools_find()
	u.tools, u.source, u.proto = tools, source, "=file"
	u.current, _ = version_parse(current)
	u.version = current
	u.exe_dir, _ = os.get_absolute_path(install_dir, context.temp_allocator)
	u.phase = .Idle
}

@(private = "file")
wait :: proc(u: ^Updater) {
	if u.worker == nil {return}
	thread.join(u.worker)
	thread.destroy(u.worker)
	u.worker = nil
}

// The whole update on this computer, from a folder of releases instead of GitHub's: the
// check finds the newer one, the install puts its files in place, and the restart runs the
// installed game.
@(test)
test_update_end_to_end :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		dir := "build/tmp/update_end_to_end"
		os.remove_all(dir)
		defer os.remove_all(dir)
		source := fake_release(t, join(dir, "release"), "0.9.1", "new", "")
		package_tree(dir, "install", LAYOUT_LINUX, "old")
		u: Updater
		defer destroy(&u)
		fake_updater(&u, source, join(dir, "install"), "0.9.0")
		check(&u)
		wait(&u)
		s := status(&u)
		testing.expect_value(t, s.phase, Phase.Available)
		testing.expect_value(t, s.version, "0.9.1")
		install(&u)
		wait(&u)
		s = status(&u)
		testing.expect_value(t, s.phase, Phase.Ready)
		for file in LAYOUT_LINUX.required {
			data, _ := os.read_entire_file_from_path(
				join(dir, "install", file),
				context.temp_allocator,
			)
			testing.expect_value(t, string(data), "new")
		}
		testing.expect(
			t,
			!os.exists(join(dir, "install", STAGING_NAME)),
			"the staging folder is gone",
		)
		cmd, ok := restart_command(&u, {"--exec", "x", "--null-audio"}, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, cmd[0], join(u.exe_dir, "voxiverse"))
		testing.expect_value(t, len(cmd), 2)
	}
}

// A package whose SHA-256 is not the one SHA256SUMS gives is never unpacked: the
// installed game stays as it was, and nothing is left behind.
@(test)
test_update_wrong_checksum_refused :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		dir := "build/tmp/update_wrong_sum"
		os.remove_all(dir)
		defer os.remove_all(dir)
		wrong := strings.repeat("ab", 32, context.temp_allocator)
		source := fake_release(t, join(dir, "release"), "0.9.1", "new", wrong)
		package_tree(dir, "install", LAYOUT_LINUX, "old")
		u: Updater
		defer destroy(&u)
		fake_updater(&u, source, join(dir, "install"), "0.9.0")
		check(&u)
		wait(&u)
		testing.expect_value(t, status(&u).phase, Phase.Available)
		install(&u)
		wait(&u)
		s := status(&u)
		testing.expect_value(t, s.phase, Phase.Failed)
		testing.expect_value(t, s.failure, Failure.Mismatch)
		for file in LAYOUT_LINUX.required {
			data, _ := os.read_entire_file_from_path(
				join(dir, "install", file),
				context.temp_allocator,
			)
			testing.expect_value(t, string(data), "old")
		}
		testing.expect(t, !os.exists(join(dir, "install", STAGING_NAME)))
		_, ok := restart_command(&u, {}, context.temp_allocator)
		testing.expect(t, !ok)
	}
}

// Nothing newer, or a game not run from a package: no update, and nothing touched.
@(test)
test_update_not_offered_or_not_a_package :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		dir := "build/tmp/update_not_offered"
		os.remove_all(dir)
		defer os.remove_all(dir)
		source := fake_release(t, join(dir, "release"), "0.9.1", "new", "")
		os.make_directory_all(join(dir, "build"))
		{
			u: Updater
			defer destroy(&u)
			fake_updater(&u, source, join(dir, "build"), "0.9.1")
			check(&u)
			wait(&u)
			testing.expect_value(t, status(&u).phase, Phase.Current)
		}
		u: Updater
		defer destroy(&u)
		fake_updater(&u, source, join(dir, "build"), "0.9.0")
		check(&u)
		wait(&u)
		install(&u)
		wait(&u)
		s := status(&u)
		testing.expect_value(t, s.phase, Phase.Failed)
		testing.expect_value(t, s.failure, Failure.Not_Package)
	}
}
