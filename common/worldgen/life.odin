package worldgen

import "common:base"
import "common:starmap"

// What lives on a world, from its address alone (level L0 of the peoples
// plan): instant, deterministic, no simulation. The home world is Earth and
// stays as it is: animals, no peoples beyond what Earth has.

Life :: enum u8 {
	None,
	Microbial,
	Plants,
	Animals,
}

// LIFE_SHARE: out of 100 addresses, how many have each kind of life.
@(rodata)
LIFE_SHARE := [Life]int {
	.None      = 15,
	.Microbial = 25,
	.Plants    = 20,
	.Animals   = 40,
}

// PEOPLES_ONE_IN: of the worlds with animals, one in this many has peoples.
PEOPLES_ONE_IN :: 8
PEOPLES_MAX :: 5
PEOPLES_AGE_MIN :: 500 // years since the first farming
PEOPLES_AGE_MAX :: 12000

World_Life :: struct {
	life:        Life,
	peoples:     u8, // how many arose; 0 for most worlds
	peoples_age: u32, // years since the first farming; 0 without peoples
}

// world_life: what lives at address. home: the address is the universe's
// home world (Earth), which has no peoples.
world_life :: proc(a: starmap.Address, home := false) -> (l: World_Life) {
	state := starmap.address_hash(a) ~ 0x5bd1_e995_a3c9_f0d1
	roll := int(base.splitmix(&state) % 100)
	for share, kind in LIFE_SHARE {
		if roll < share {
			l.life = kind
			break
		}
		roll -= share
	}
	has := base.splitmix(&state) % PEOPLES_ONE_IN == 0
	count := 1 + u8(base.splitmix(&state) % PEOPLES_MAX)
	age := PEOPLES_AGE_MIN + u32(base.splitmix(&state) % (PEOPLES_AGE_MAX - PEOPLES_AGE_MIN + 1))
	if home {
		l.life = .Animals
	} else if l.life == .Animals && has {
		l.peoples, l.peoples_age = count, age
	}
	return
}
