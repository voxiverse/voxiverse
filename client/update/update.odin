// Package update: the game updating itself from its releases on GitHub
// (docs/platforms.md, "Updates"). On reaching the title, once a launch, a thread asks
// GitHub's API for the releases and, when one is newer and has this platform's package,
// reads its SHA256SUMS: the title then offers it. Installing downloads the package beside
// the installed game, checks its SHA-256 against SHA256SUMS, lists, unpacks and checks it,
// and swaps it in by renames (swap.odin), all on a thread of its own while the game goes
// on; the player then restarts into it. Everything from the network is read by our own
// code (release.odin, sums.odin), and curl and tar are the system's (tools.odin).
//
// Built with -define:VX_UPDATER=false (`build package --no-updater`, for a store that
// updates the game itself) the updater is not compiled in: the title never offers one and
// Options has no setting for it.
package update

import "core:crypto/sha2"
import "core:log"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

import "common:base"
import "common:limited"

ENABLED :: #config(VX_UPDATER, true)

Phase :: enum u8 {
	Off, // it never checks: a development build, a script's run, the setting off, no curl
	Idle, // it may check
	Checking,
	Current, // checked: nothing newer for this computer (or the check failed)
	Available, // found: what Updater.found says
	Downloading,
	Installing, // checking, unpacking and swapping in what was downloaded
	Ready, // installed: a restart runs it
	Failed, // installing failed (the installed game is as it was): Updater.failure says why
}

Failure :: enum u8 {
	None,
	Download, // the download failed
	Mismatch, // the download is not what SHA256SUMS says
	Not_Writable, // the install folder cannot be written
	Not_Package, // the game does not run from an unpacked package
	Install, // unpacking or swapping in failed
}

// Found: the release a check found to offer.
Found :: struct {
	version: string, // "0.5.3"
	archive: string, // the package's file name
	url:     string,
	size:    i64,
	folder:  string, // the folder in the package
	digest:  Digest, // its SHA-256, from SHA256SUMS
}

// Status: what the title shows.
Status :: struct {
	phase:   Phase,
	failure: Failure,
	version: string, // Found.version (Available and after)
	percent: int, // Downloading: how much is here
}

Updater :: struct {
	arena:       virtual.Arena, // its strings (the found release, the tools' paths)
	mutex:       sync.Mutex,
	phase:       Phase, // (under mutex)
	failure:     Failure, // (under mutex)
	found:       Found, // set before phase becomes Available, not changed after
	stop:        b32, // the game is quitting: the running curl is killed
	worker:      ^thread.Thread,
	tools:       Tools,
	source:      Source,
	proto:       string, // the protocol fetched with: "=https" ("=file": a development build's source)
	current:     Version, // what this build is
	version:     string, // ... as its text
	exe_dir:     string,
	install:     Install, // where it was installed (Ready)
	partial:     string, // the download being written (Downloading)
	progress_at: time.Tick, // when status last looked at it
	percent:     int,
}

// init readies the updater for a game running from exe_dir; allowed false (a script's,
// a benchmark's, a check's run) leaves it Off. A development build is Off too, unless
// VX_UPDATE_AS gives it a version to check as (and VX_UPDATE_SOURCE a folder of releases
// to read instead of GitHub's). What an update left in the install folder is cleaned up.
init :: proc(u: ^Updater, exe_dir: string, allowed: bool) {
	_ = virtual.arena_init_growing(&u.arena)
	when ENABLED {init_enabled(u, exe_dir, allowed)}
}

@(private = "file")
init_enabled :: proc(u: ^Updater, exe_dir: string, allowed: bool) {
	a := virtual.arena_allocator(&u.arena)
	u.exe_dir = strings.clone(exe_dir, a)
	u.source, u.proto = GITHUB, "=https"
	if install, ok := install_find(exe_dir, LAYOUT); ok {cleanup(install.dir)}
	version := base.VERSION
	dev := base.version_is_dev()
	when base.DEV {
		env := base.boot_info().env
		if as, set := env.update_as.?; set {version, dev = strings.clone(as, a), false}
		if dir, set := env.update_source.?; set {
			absolute, _ := os.get_absolute_path(dir, a)
			u.source = Source {
				list     = strings.concatenate({"file://", absolute, "/releases.json"}, a),
				download = strings.concatenate({"file://", absolute, "/download/"}, a),
			}
			u.proto = "=file"
			log.infof("update reads releases from path=%s (VX_UPDATE_SOURCE)", absolute)
		}
	}
	if dev {
		log.infof("update off: a development build (version=%s)", version)
		return
	}
	current, parsed := version_parse(version)
	if !parsed {
		log.warnf("update off: this build's version does not read (version=%s)", version)
		return
	}
	tools, found := tools_find(a)
	if !found {
		log.info("update off: no curl or tar where the system keeps them")
		return
	}
	u.current, u.version, u.tools = current, version, tools
	u.phase = .Idle if allowed else .Off
}

// destroy stops what runs (a download is killed, its files removed) and frees the rest.
destroy :: proc(u: ^Updater) {
	sync.atomic_store(&u.stop, true)
	if u.worker != nil {
		thread.join(u.worker)
		thread.destroy(u.worker)
		u.worker = nil
	}
	virtual.arena_destroy(&u.arena)
}

// check starts a check, if none was made this launch: a thread asks GitHub and the phase
// becomes Available or Current. A failed check says so in the log only. force checks in
// a run that does not otherwise (a script's: the console's `update check`), though never
// in a build that cannot (a development build without VX_UPDATE_AS, no curl).
check :: proc(u: ^Updater, force := false) {
	sync.guard(&u.mutex)
	if force && u.phase == .Off && u.tools.curl != "" {u.phase = .Idle}
	if u.phase != .Idle {return}
	u.phase = .Checking
	u.worker = thread.create_and_start_with_poly_data(u, check_main, base.thread_context())
}

// install starts installing what a check found: a thread downloads, checks and swaps it
// in, and the phase becomes Ready or Failed.
install :: proc(u: ^Updater) {
	sync.guard(&u.mutex)
	if u.phase != .Available {return}
	if u.worker != nil {
		thread.join(u.worker) // (the check's, done)
		thread.destroy(u.worker)
	}
	u.phase = .Downloading
	u.worker = thread.create_and_start_with_poly_data(u, install_main, base.thread_context())
}

status :: proc(u: ^Updater) -> Status {
	sync.guard(&u.mutex)
	s := Status {
		phase   = u.phase,
		failure = u.failure,
	}
	if u.phase >= .Available {s.version = u.found.version}
	if u.phase == .Downloading {
		// The file as curl writes it, looked at five times a second at most.
		if u.partial != "" &&
		   u.found.size > 0 &&
		   time.tick_since(u.progress_at) > 200 * time.Millisecond {
			u.progress_at = time.tick_now()
			if info, err := os.stat(u.partial, context.temp_allocator); err == nil {
				u.percent = int(clamp(info.size * 100 / u.found.size, 0, 99))
			}
		}
		s.percent = u.percent
	}
	return s
}

// restart_command: the command that starts the installed update with the game's
// arguments (without its path; the one-shot ones are left out), once it is Ready. macOS
// opens the app (a new instance: this one is quitting). The list and the path in it are
// allocated with allocator; the arguments are args' own.
restart_command :: proc(
	u: ^Updater,
	args: []string,
	allocator := context.allocator,
) -> (
	cmd: []string,
	ok: bool,
) {
	sync.guard(&u.mutex)
	if u.phase != .Ready {return}
	out := make([dynamic]string, allocator)
	when ODIN_OS == .Darwin {
		app, _ := filepath.join({u.install.dir, LAYOUT.app}, allocator)
		append(&out, "/usr/bin/open", "-n", app, "--args")
	} else {
		game, _ := filepath.join({u.install.dir, LAYOUT.game}, allocator)
		append(&out, game)
	}
	append(&out, ..restart_args(args))
	return out[:], true
}

@(private = "file")
set_phase :: proc(u: ^Updater, phase: Phase, failure := Failure.None) {
	sync.guard(&u.mutex)
	u.phase, u.failure = phase, failure
}

// fetch_text: what url holds, at most max bytes; ok false (and why, in the log) on any
// failure.
@(private = "file")
fetch_text :: proc(u: ^Updater, url: string, max: i64) -> (text: string, ok: bool) {
	cmd := curl_command(u.tools, {url = url, proto = u.proto, max = max, seconds = 30})
	state, stdout, stderr, err := limited.exec(
		{command = cmd},
		context.allocator,
		&u.stop,
		hidden = true,
	)
	defer delete(stderr)
	if err != nil || !state.exited || state.exit_code != 0 || i64(len(stdout)) > max {
		log.warnf(
			"update could not fetch url=%s exit=%d error=%v: %s",
			url,
			state.exit_code,
			err,
			strings.trim_space(string(stderr)),
		)
		delete(stdout)
		return "", false
	}
	return string(stdout), true
}

@(private = "file")
check_main :: proc(u: ^Updater) {
	// A scratch arena of its own (never its starter's temp allocator).
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	phase := Phase.Current
	defer set_phase(u, phase)
	text, fetched := fetch_text(u, u.source.list, RELEASES_TEXT_MAX)
	if !fetched {return}
	defer delete(text)
	releases, read := releases_read(text)
	defer releases_destroy(&releases)
	if !read {
		log.warnf("update the list of releases does not read (%d bytes)", len(text))
		return
	}
	offer, offered := offer_choose(releases, u.current, PLATFORM, u.source)
	if !offered {
		log.infof(
			"update none newer than version=%s for %s-%s",
			u.version,
			PLATFORM.os,
			PLATFORM.arch,
		)
		return
	}
	sums, sums_fetched := fetch_text(u, offer.sums.url, SUMS_TEXT_MAX)
	if !sums_fetched {return}
	defer delete(sums)
	digest, listed := sums_find(sums, offer.archive.name)
	if !listed {
		log.warnf("update %s does not list name=%s", offer.sums.url, offer.archive.name)
		return
	}
	a := virtual.arena_allocator(&u.arena)
	u.found = Found {
		version = strings.clone(offer.text, a),
		archive = strings.clone(offer.archive.name, a),
		url     = strings.clone(offer.archive.url, a),
		size    = offer.archive.size,
		folder  = strings.clone(offer.folder, a),
		digest  = digest,
	}
	log.infof(
		"update available version=%s url=%s size=%d sha256=%s",
		u.found.version,
		u.found.url,
		u.found.size,
		digest_text(digest),
	)
	phase = .Available
}

@(private = "file")
install_main :: proc(u: ^Updater) {
	scratch: virtual.Arena
	_ = virtual.arena_init_growing(&scratch)
	defer virtual.arena_destroy(&scratch)
	context.temp_allocator = virtual.arena_allocator(&scratch)
	f := u.found
	install, laid_out := install_find(u.exe_dir, LAYOUT)
	if !laid_out {
		log.warnf(
			"update not installed: the game does not run from a package (folder=%s)",
			u.exe_dir,
		)
		set_phase(u, .Failed, .Not_Package)
		return
	}
	staging := join(install.dir, STAGING_NAME)
	os.remove_all(staging)
	if err := os.make_directory(staging); err != nil {
		log.warnf("update not installed: cannot write folder=%s error=%v", install.dir, err)
		set_phase(u, .Failed, .Not_Writable)
		return
	}
	failure := install_staged(u, install, staging)
	os.remove_all(staging)
	if failure != .None {
		set_phase(u, .Failed, failure)
		return
	}
	u.install = install
	log.infof("update installed version=%s folder=%s: restart to run it", f.version, install.dir)
	set_phase(u, .Ready)
}

// install_staged downloads into staging, checks, unpacks and swaps in; the install is as
// it was unless it returns None.
@(private = "file")
install_staged :: proc(u: ^Updater, install: Install, staging: string) -> Failure {
	f := u.found
	archive := join(staging, f.archive)
	{
		sync.guard(&u.mutex)
		u.partial = archive
	}
	cmd := curl_command(
		u.tools,
		{url = f.url, proto = u.proto, max = ARCHIVE_SIZE_MAX, seconds = 3600, out = archive},
	)
	state, _, stderr, err := limited.exec(
		{command = cmd},
		context.temp_allocator,
		&u.stop,
		hidden = true,
	)
	{
		sync.guard(&u.mutex)
		u.partial = ""
	}
	if err != nil || !state.exited || state.exit_code != 0 {
		log.warnf(
			"update could not download url=%s exit=%d error=%v: %s",
			f.url,
			state.exit_code,
			err,
			strings.trim_space(string(stderr)),
		)
		return .Download
	}
	set_phase(u, .Installing)
	digest, hashed := file_sha256(archive)
	if !hashed || digest != f.digest {
		log.warnf("update the download does not match SHA256SUMS: name=%s", f.archive)
		return .Mismatch
	}
	unpacked := join(staging, "unpacked")
	commands := unpack_commands(u.tools, archive, unpacked)
	names, names_ok := run_text(commands.names)
	types, types_ok := run_text(commands.types)
	if !names_ok || !types_ok || !listing_check(names, types, f.folder) {
		log.warnf("update the package's listing is not one of ours: name=%s", f.archive)
		return .Install
	}
	if os.make_directory(unpacked) != nil || !run_ok(commands.extract) {
		log.warnf("update could not unpack name=%s", f.archive)
		return .Install
	}
	if !tree_check(unpacked, f.folder, LAYOUT) {
		log.warnf("update the unpacked package is not one of ours: name=%s", f.archive)
		return .Install
	}
	steps, planned := swap_plan(install, join(unpacked, f.folder), LAYOUT)
	if !planned {return .Install}
	swapped, restored := swap_run(steps)
	if !swapped {
		if restored {
			log.warn("update the swap failed; the installed game is as it was")
		} else {
			log.error("update the swap failed and could not be undone in full (see above)")
		}
		return .Install
	}
	return .None
}

@(private = "file")
run_text :: proc(cmd: []string) -> (string, bool) {
	state, stdout, _, err := limited.exec({command = cmd}, context.temp_allocator, hidden = true)
	return string(stdout), err == nil && state.exited && state.exit_code == 0
}

@(private = "file")
run_ok :: proc(cmd: []string) -> bool {
	_, ok := run_text(cmd)
	return ok
}

// file_sha256: the SHA-256 of the file at path, read a piece at a time.
file_sha256 :: proc(path: string) -> (digest: Digest, ok: bool) {
	f, err := os.open(path)
	if err != nil {return}
	defer os.close(f)
	ctx: sha2.Context_256
	sha2.init_256(&ctx)
	buf: [64 * 1024]u8
	for {
		n, rerr := os.read(f, buf[:])
		if n > 0 {sha2.update(&ctx, buf[:n])}
		if rerr == .EOF || (rerr == nil && n == 0) {break}
		if rerr != nil {return}
	}
	sha2.final(&ctx, digest[:])
	return digest, true
}

// fake shows a phase as if it had come about (development builds: the title's
// screenshots, `update fake`).
fake :: proc(u: ^Updater, phase: Phase, version: string, percent: int, failure: Failure) {
	when base.DEV {
		sync.guard(&u.mutex)
		u.phase, u.failure, u.percent = phase, failure, percent
		u.found.version = strings.clone(version, virtual.arena_allocator(&u.arena))
		u.found.size = 0 // (status keeps the percent given)
	}
}
