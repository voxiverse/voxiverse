package base

// Chance: one keyed hash family, and what is made of it (docs/determinism.md,
// rule 3). mix is a bijection of 64 bits; hash folds a key and integers through
// it, a counter stepping by GOLDEN; splitmix is that counter kept in a variable;
// Rng is seeded from it; unit_f32 and unit_f64 read any of their bits as a number
// in [0, 1). A seed for a stream of its own is hash(seed, SALT), never seed ~ SALT:
// an XOR leaves two streams' seeds a known distance apart.

// GOLDEN is the counter's step: 2^64 over the golden ratio, rounded to odd.
@(private = "file")
GOLDEN :: 0x9e37_79b9_7f4a_7c15

// mix is splitmix64's finalizer (Stafford's variant 13): a bijection of u64
// in which every input bit reaches every output bit. mix(0) is 0.
mix :: #force_inline proc "contextless" (x: u64) -> u64 {
	z := x
	z = (z ~ (z >> 30)) * 0xbf58_476d_1ce4_e5b9
	z = (z ~ (z >> 27)) * 0x94d0_49bb_1331_11eb
	return z ~ (z >> 31)
}

// hash is the family: 64 well-mixed bits from a key and any integers. Each
// integer folds in as one step of the counter from the bits so far:
// hash(k, i) = mix(k + (i + 1) * GOLDEN) and hash(k, i, j) = hash(hash(k, i), j);
// with no integer it is the key. A signed integer is passed as its bits, u64(i).
hash :: proc "contextless" (key: u64, ints: ..u64) -> u64 {
	h := key
	for i in ints {h = mix(h + (i + 1) * GOLDEN)}
	return h
}

// splitmix is splitmix64 (Steele, Lea and Flood): the counter in state steps
// once and its mix comes out, so the k-th draw from a state that began at s is
// hash(s, k). It seeds Rng. A stream that reaches state is an Rng; the
// starmap's addresses and galaxies, a world's life and the music tool's
// variations drew from this one before Rng existed, and keep it.
splitmix :: proc "contextless" (state: ^u64) -> u64 {
	state^ += GOLDEN
	return mix(state^)
}

// unit_f32 is the top 24 bits of a hash, of either width, times 2^-24: in
// [0, 1), never 1, every value a multiple of 2^-24.
unit_f32 :: proc {
	unit_f32_u64,
	unit_f32_u32,
}

unit_f32_u64 :: proc "contextless" (bits: u64) -> f32 {
	return f32(bits >> 40) * (1.0 / 16777216.0)
}

unit_f32_u32 :: proc "contextless" (bits: u32) -> f32 {
	return f32(bits >> 8) * (1.0 / 16777216.0)
}

// unit_f64 is the top 53 bits of a hash times 2^-53: in [0, 1), never 1, every
// value a multiple of 2^-53.
unit_f64 :: proc "contextless" (bits: u64) -> f64 {
	return f64(bits >> 11) * (1.0 / 9007199254740992.0)
}

// lcg64 is Knuth's MMIX linear congruential step: the state moves on and is
// the draw. Its low bits are weak, so a draw is read from the top (>> 33, or
// unit_f32). It is no stream for new state, which is an Rng: a gate world's
// kind, the test and benchmark bots and the Ogg fuzzer's seeks drew from it
// before Rng existed, and keep it.
lcg64 :: proc "contextless" (state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1442695040888963407
	return state^
}

// lcg32 is the 32-bit step of Numerical Recipes, kept in the same way for the
// starfield, the holiday backdrop and the patterns of a few tests and the
// audio benchmark. Its draw is read from the top too (unit_f32).
lcg32 :: proc "contextless" (state: ^u32) -> u32 {
	state^ = state^ * 1664525 + 1013904223
	return state^
}
