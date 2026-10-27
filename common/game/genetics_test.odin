package game

import "core:testing"

import "../../base"

// Two carriers (one recessive copy each) have black lambs a quarter of the
// time, spotted ones likewise and independently; a black parent gives its
// recessive copy to every lamb.
@(test)
test_carriers_make_a_quarter_black :: proc(t: ^testing.T) {
	state := base.rng_make(1)
	r := &state
	carrier := Genes{.Wool_A, .Coat_B}
	N :: 40000
	black, spotted, both := 0, 0, 0
	for _ in 0 ..< N {
		g := genes_child(carrier, carrier, r)
		b, s := genes_black(g), genes_spotted(g)
		if b {black += 1}
		if s {spotted += 1}
		if b && s {both += 1}
	}
	for n, what in ([]int{black, spotted}) {
		share := f64(n) / N
		testing.expectf(
			t,
			share > 0.23 && share < 0.27,
			"carriers' lambs: %d of %d were %d (a quarter expected)",
			n,
			N,
			what,
		)
	}
	testing.expectf(
		t,
		f64(both) / N > 0.05 && f64(both) / N < 0.075,
		"both traits in %d of %d (1/16 expected)",
		both,
		N,
	)
	// A black sheep with a plain one: every lamb a carrier, none black (bar mutation).
	carriers, blacks := 0, 0
	for _ in 0 ..< N {
		g := genes_child(WOOL_BLACK, {}, r)
		if (Gene_Copy.Wool_A in g) != (Gene_Copy.Wool_B in g) {carriers += 1}
		if genes_black(g) {blacks += 1}
	}
	testing.expect(
		t,
		carriers > N * 98 / 100,
		"lambs of a black sheep and a plain one are carriers",
	)
	testing.expect(t, blacks < N / 200)
}

// One copy in a thousand flips in a new lamb: the lambs of two sheep with no
// recessive copies show about that many.
@(test)
test_mutation_rate :: proc(t: ^testing.T) {
	state := base.rng_make(2)
	r := &state
	N :: 200000
	copies := 0
	for _ in 0 ..< N {
		g := genes_child({}, {}, r)
		copies += card(g)
	}
	want := N * 4 / MUTATION_RATE // 800
	testing.expectf(
		t,
		copies > want * 80 / 100 && copies < want * 120 / 100,
		"%d mutated copies in %d lambs (about %d expected)",
		copies,
		N,
		want,
	)
}

// Wild sheep carry each recessive copy 1 time in 10: about 1 in 100 show a trait.
@(test)
test_wild_sheep :: proc(t: ^testing.T) {
	state := base.rng_make(3)
	r := &state
	N :: 100000
	black, copies := 0, 0
	for _ in 0 ..< N {
		g := genes_wild(r)
		if genes_black(g) {black += 1}
		copies += card(g)
	}
	testing.expectf(
		t,
		black > N * 8 / 1000 && black < N * 12 / 1000,
		"%d of %d wild sheep were black (1 in 100 expected)",
		black,
		N,
	)
	testing.expectf(
		t,
		copies > N * 36 / 100 && copies < N * 44 / 100,
		"%d recessive copies in %d sheep (0.4 each expected)",
		copies,
		N,
	)
}

// Related sheep share copies, so breeding within a family shows recessive
// traits more often: nothing is coded for it. Lines founded by a wild pair
// and bred brother to sister for six generations show black wool several
// times as often as the wild does.
@(test)
test_inbred_lines_show_more :: proc(t: ^testing.T) {
	state := base.rng_make(4)
	r := &state
	LINES :: 4000
	FAMILY :: 6
	inbred, inbred_total, wild := 0, 0, 0
	for _ in 0 ..< LINES {
		a, b := genes_wild(r), genes_wild(r)
		for _ in 0 ..< 6 {
			// A family from the pair; two of its children are the next pair.
			family: [FAMILY]Genes
			for &c in family {c = genes_child(a, b, r)}
			i := base.rng_int_max(r, FAMILY)
			j := (i + 1 + base.rng_int_max(r, FAMILY - 1)) % FAMILY
			a, b = family[i], family[j]
		}
		for _ in 0 ..< FAMILY {
			inbred_total += 1
			if genes_black(genes_child(a, b, r)) {inbred += 1}
		}
		if genes_black(genes_child(genes_wild(r), genes_wild(r), r)) {wild += 1}
	}
	inbred_rate := f64(inbred) / f64(inbred_total)
	wild_rate := f64(wild) / LINES
	testing.expectf(
		t,
		inbred_rate > 3 * wild_rate,
		"inbred lines %.3f black against %.3f for unrelated pairs",
		inbred_rate,
		wild_rate,
	)
}

@(private = "file")
card :: proc(g: Genes) -> (n: int) {
	for c in Gene_Copy {if c in g {n += 1}}
	return
}
