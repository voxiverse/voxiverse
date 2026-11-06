package platform_common

import "core:os"

import "common:base"

// Package platform_common (the folder is common/platform; client/platform already holds the name
// `platform`, and two packages of one name cannot be linked together).

// boot fills host from the operating system. It is called once, first thing in the
// entry packages' main (client/main, server/dedicated), which pass the host down; nothing
// else reads the process's start-up state. The strings are the process's own (they live
// as long as it does).
boot :: proc(host: ^base.Host) {
	host^ = {
		boot = {args = os.args[1:] if len(os.args) > 0 else nil},
	}
}
