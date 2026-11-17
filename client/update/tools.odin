package update

import "core:fmt"
import "core:strings"

// The system's own programs the updater runs, by their full paths (never a search of
// PATH): curl to fetch, tar (or ditto on macOS) to list and unpack. curl comes with
// Windows 10 and later, macOS and Linux distributions; without it there are no updates.
// Every command is a list of arguments, never a shell's line.

Tools :: struct {
	curl:  string,
	tar:   string,
	ditto: string, // macOS: unpacks the zip keeping the app's metadata
}

USER_AGENT :: "voxiverse-updater" // all curl tells anyone: no name, machine or version

// Fetch: one download.
Fetch :: struct {
	url:     string,
	proto:   string, // the one protocol allowed, redirects included: "=https"
	max:     i64, // bytes at most
	seconds: int, // the whole transfer at most
	out:     string, // the file it goes to ("": stdout)
}

// curl_command: curl fetching f and nothing else: no config file read (--disable), only
// f.proto, TLS 1.2 or newer, a failed HTTP status is a failure, at most 5 redirects, the
// size and time capped, and a stalled transfer (under 1 kB/s for a minute) given up.
curl_command :: proc(tools: Tools, f: Fetch) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(
		&cmd,
		tools.curl,
		"--disable",
		"--silent",
		"--show-error",
		"--proto",
		f.proto,
		"--proto-redir",
		f.proto,
		"--tlsv1.2",
		"--fail",
		"--location",
		"--max-redirs",
		"5",
		"--max-filesize",
		fmt.tprint(f.max),
		"--connect-timeout",
		"20",
		"--max-time",
		fmt.tprint(f.seconds),
		"--speed-limit",
		"1000",
		"--speed-time",
		"60",
		"--user-agent",
		USER_AGENT,
	)
	if f.out != "" {append(&cmd, "--output", f.out)}
	append(&cmd, "--", f.url)
	return cmd[:]
}

// Unpack: the commands that list an archive (names, then names with their kinds) and
// unpack it into a folder.
Unpack :: struct {
	names, types, extract: []string,
}

unpack_commands :: proc(tools: Tools, archive, into: string) -> Unpack {
	gzip := strings.has_suffix(archive, ".tar.gz")
	list := "-tzf" if gzip else "-tf"
	verbose := "-tvzf" if gzip else "-tvf"
	u := Unpack {
		names = slice_of(tools.tar, list, archive),
		types = slice_of(tools.tar, verbose, archive),
	}
	if tools.ditto != "" {
		u.extract = slice_of(tools.ditto, "-x", "-k", archive, into)
	} else {
		u.extract = slice_of(tools.tar, "-xzf" if gzip else "-xf", archive, "-C", into)
	}
	return u
}

@(private = "file")
slice_of :: proc(args: ..string) -> []string {
	out := make([]string, len(args), context.temp_allocator)
	copy(out, args)
	return out
}

// ONE_SHOT: the game's options that do one thing and are not given again when it restarts
// into its update (client/engine/options.odin; a run with any of them never updates).
ONE_SHOT :: []string {
	"exec",
	"benchmark",
	"smoke",
	"bench-size",
	"check",
	"scene",
	"version",
	"capture-frame",
}
ONE_SHOT_FLAGS :: []string{"smoke", "version"} // (of those, the ones that take no value)

// restart_args: the game's arguments (without its own path) for the restart, the one-shot
// options and their values left out.
restart_args :: proc(args: []string) -> []string {
	out := make([dynamic]string, context.temp_allocator)
	for i := 0; i < len(args); i += 1 {
		arg := args[i]
		if !strings.has_prefix(arg, "-") {
			append(&out, arg)
			continue
		}
		name := strings.trim_left(arg, "-")
		joined := false
		if at := strings.index_any(name, "=:"); at >= 0 {
			name, joined = name[:at], true
		}
		name, _ = strings.replace_all(name, "_", "-", context.temp_allocator)
		if !contains(ONE_SHOT, name) {
			append(&out, arg)
			continue
		}
		if !joined && !contains(ONE_SHOT_FLAGS, name) {i += 1} 	// its value
	}
	return out[:]
}

@(private = "file")
contains :: proc(list: []string, s: string) -> bool {
	for x in list {if x == s {return true}}
	return false
}
