package game

import "../base"

// Sheep genetics, real and tiny: two genes, each with a common dominant
// form and a rare recessive one; a sheep carries two copies of each. Wool:
// white (dominant) or black (recessive: both copies black shows it). Coat:
// plain (dominant) or spotted (recessive). A lamb takes one copy of each
// gene from each parent, at random, and one copy in MUTATION_RATE flips.
// Nothing here knows about relatives: inbred lines show recessives more
// often because they share copies.

// Gene_Copy: the four copies a sheep carries; set means the recessive form.
Gene_Copy :: enum u8 {
	Wool_A, // from one parent
	Wool_B, // from the other
	Coat_A,
	Coat_B,
}
Genes :: bit_set[Gene_Copy;u8]

WOOL_BLACK :: Genes{.Wool_A, .Wool_B}
COAT_SPOTTED :: Genes{.Coat_A, .Coat_B}

MUTATION_RATE :: 1000 // one copy in this many flips in a new lamb
WILD_RECESSIVE :: 10 // a wild sheep carries each recessive copy 1 time in this many

genes_black :: proc(g: Genes) -> bool {return WOOL_BLACK <= g}
genes_spotted :: proc(g: Genes) -> bool {return COAT_SPOTTED <= g}

// genes_wild: the genes of a sheep found in the wild.
genes_wild :: proc(r: ^base.Rng) -> (g: Genes) {
	for c in Gene_Copy {
		if base.rng_int_max(r, WILD_RECESSIVE) == 0 {g += {c}}
	}
	return
}

// genes_child: a lamb of a and b: one copy of each gene from each, chosen at
// random, then the mutations.
genes_child :: proc(a, b: Genes, r: ^base.Rng) -> (g: Genes) {
	pick :: proc(parent: Genes, first, second: Gene_Copy, r: ^base.Rng) -> bool {
		return (first in parent) if base.rng_int_max(r, 2) == 0 else (second in parent)
	}
	if pick(a, .Wool_A, .Wool_B, r) {g += {.Wool_A}}
	if pick(b, .Wool_A, .Wool_B, r) {g += {.Wool_B}}
	if pick(a, .Coat_A, .Coat_B, r) {g += {.Coat_A}}
	if pick(b, .Coat_A, .Coat_B, r) {g += {.Coat_B}}
	for c in Gene_Copy {
		if base.rng_int_max(r, MUTATION_RATE) == 0 {g ~= {c}}
	}
	return
}

// Sheep_Flag: what a client is told about a sheep (every tick, in
// Entity_Entry): how it looks, and whether it is in love (hearts).
Sheep_Flag :: enum u8 {
	Shorn,
	Lamb,
	Black,
	Spotted,
	In_Love,
}
Sheep_Flags :: bit_set[Sheep_Flag;u8]

// Breeding and growing (ticks): fed, a sheep is ready for BREED_READY_TICKS;
// after a lamb it waits BREED_WAIT_TICKS; a lamb grows up in LAMB_TICKS; wheat
// brings that forward by a tenth.
BREED_READY_TICKS :: 30 * TICK_RATE
BREED_WAIT_TICKS :: 5 * 60 * TICK_RATE
LAMB_TICKS :: 10 * 60 * TICK_RATE
BREED_RANGE :: 8 // blocks within which ready sheep find each other
