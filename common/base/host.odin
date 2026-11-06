package base

// Host: everything the core knows about the machine it runs on. It is plain data and
// procedure values, filled in by the platform layer (`common/platform`, `client/platform`)
// once at start and handed down by the entry packages (`client/main`, `server/dedicated`);
// the core imports only base and never a platform package. Tests fill it with fakes.
//
// The services land one step at a time (docs/design.md, "The OS quarantine"): this is the
// contract with its first field, the boot information.
Host :: struct {
	boot: Boot_Info,
}

// Boot_Info: what the process was started with, read once at boot.
Boot_Info :: struct {
	args: []string, // argv[1:] (the program's own name is not in it)
}
