package wave

// Waves: the rules both sides of a wave survival share, whichever game runs it (Horde's
// runs, the sandbox's ruined site): which of the base pack's hostile creatures come, and
// how many of each and how tough in wave n. Where they come out, whom they go for and
// what a kill is worth is the game's; the server's part of a crowd of them is
// server/play's (crowd.odin).

// Foe: the creatures (the base pack's hostile kinds, which any game may use).
Foe :: enum u8 {
	Shambler, // closes in and strikes
	Skitter, // small and fast, in swarms
	Spitter, // keeps its distance and spits
	Hulk, // slow, tough, strikes hard
	Matriarch, // every fifth wave: strikes near, spits far
}

// KINDS: each foe's entity kind.
@(rodata)
KINDS := [Foe]string {
	.Shambler  = "voxiverse:shambler",
	.Skitter   = "voxiverse:skitter",
	.Spitter   = "voxiverse:spitter",
	.Hulk      = "voxiverse:hulk",
	.Matriarch = "voxiverse:matriarch",
}

// Plan: how many creatures of each kind a wave sends, and how much tougher than its kind
// each is.
Plan :: struct {
	count:  [Foe]int,
	health: f32, // times the kind's health
}

// BOSS_EVERY: a matriarch comes with every wave whose number is a multiple of this.
BOSS_EVERY :: 5

// plan: wave n (from 1): shamblers from the first, a swarm of skitters from the second,
// spitters from the third, hulks from the fourth, more of each as it goes, and the
// matriarch every fifth; each wave's creatures an eighth tougher than the last's.
plan :: proc(n: int) -> Plan {
	return {
		count = {
			.Shambler = 3 + n,
			.Skitter = 0 if n < 2 else 2 + n,
			.Spitter = 0 if n < 3 else n / 2,
			.Hulk = 0 if n < 4 else (n - 2) / 2,
			.Matriarch = 1 if n % BOSS_EVERY == 0 else 0,
		},
		health = 1 + 0.125 * f32(n - 1),
	}
}

// size: how many creatures wave n sends.
size :: proc(n: int) -> (total: int) {
	for c in plan(n).count {total += c}
	return
}
