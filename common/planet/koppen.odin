package planet

// Köppen classes from twelve monthly temperatures and precipitations (docs/world.md, the
// planet model, step 8), with the textbook's thresholds.

Koppen :: enum u8 {
	Ocean,
	Af,
	Am,
	Aw,
	BWh,
	BWk,
	BSh,
	BSk,
	Csa,
	Csb,
	Csc,
	Cwa,
	Cwb,
	Cwc,
	Cfa,
	Cfb,
	Cfc,
	Dsa,
	Dsb,
	Dsc,
	Dsd,
	Dwa,
	Dwb,
	Dwc,
	Dwd,
	Dfa,
	Dfb,
	Dfc,
	Dfd,
	ET,
	EF,
}

@(private = "file")
KOPPEN_CODES := [Koppen]string {
	.Ocean = "Ocean",
	.Af    = "Af",
	.Am    = "Am",
	.Aw    = "Aw",
	.BWh   = "BWh",
	.BWk   = "BWk",
	.BSh   = "BSh",
	.BSk   = "BSk",
	.Csa   = "Csa",
	.Csb   = "Csb",
	.Csc   = "Csc",
	.Cwa   = "Cwa",
	.Cwb   = "Cwb",
	.Cwc   = "Cwc",
	.Cfa   = "Cfa",
	.Cfb   = "Cfb",
	.Cfc   = "Cfc",
	.Dsa   = "Dsa",
	.Dsb   = "Dsb",
	.Dsc   = "Dsc",
	.Dsd   = "Dsd",
	.Dwa   = "Dwa",
	.Dwb   = "Dwb",
	.Dwc   = "Dwc",
	.Dwd   = "Dwd",
	.Dfa   = "Dfa",
	.Dfb   = "Dfb",
	.Dfc   = "Dfc",
	.Dfd   = "Dfd",
	.ET    = "ET",
	.EF    = "EF",
}

@(private = "file")
KOPPEN_NAMES := [Koppen]string {
	.Ocean = "Ocean",
	.Af    = "Tropical rainforest",
	.Am    = "Tropical monsoon",
	.Aw    = "Tropical savanna",
	.BWh   = "Hot desert",
	.BWk   = "Cold desert",
	.BSh   = "Hot semi-arid",
	.BSk   = "Cold semi-arid",
	.Csa   = "Hot-summer Mediterranean",
	.Csb   = "Warm-summer Mediterranean",
	.Csc   = "Cold-summer Mediterranean",
	.Cwa   = "Monsoon humid subtropical",
	.Cwb   = "Subtropical highland",
	.Cwc   = "Cold subtropical highland",
	.Cfa   = "Humid subtropical",
	.Cfb   = "Marine west coast",
	.Cfc   = "Subpolar oceanic",
	.Dsa   = "Hot dry-summer continental",
	.Dsb   = "Warm dry-summer continental",
	.Dsc   = "Dry-summer subarctic",
	.Dsd   = "Dry-summer extreme subarctic",
	.Dwa   = "Monsoon hot-summer continental",
	.Dwb   = "Monsoon warm-summer continental",
	.Dwc   = "Monsoon subarctic",
	.Dwd   = "Monsoon extreme subarctic",
	.Dfa   = "Hot-summer humid continental",
	.Dfb   = "Warm-summer humid continental",
	.Dfc   = "Subarctic",
	.Dfd   = "Extreme subarctic",
	.ET    = "Tundra",
	.EF    = "Ice cap",
}

// koppen_code is the class's letters, "Cfb".
koppen_code :: proc(k: Koppen) -> string {
	return KOPPEN_CODES[k]
}

// koppen_name is the class's name, "Marine west coast".
koppen_name :: proc(k: Koppen) -> string {
	return KOPPEN_NAMES[k]
}

// koppen_group is the class's main letter: 'A'..'E', or 0 for the ocean.
koppen_group :: proc(k: Koppen) -> u8 {
	if k == .Ocean {return 0}
	return KOPPEN_CODES[k][0]
}

// koppen_classify classifies a place from its monthly mean temperatures (°C, January
// first) and precipitation (mm per month). `north` says which half-year is the summer:
// April to September in the north, October to March in the south.
koppen_classify :: proc(temp, precip: [12]f64, north: bool) -> Koppen {
	t_min, t_max := temp[0], temp[0]
	t_sum, p_sum := 0.0, 0.0
	for m in 0 ..< 12 {
		t_min = min(t_min, temp[m])
		t_max = max(t_max, temp[m])
		t_sum += temp[m]
		p_sum += precip[m]
	}
	t_year := t_sum / 12

	// The summer and winter half-years.
	summer, winter: [6]f64
	p_summer := 0.0
	for k in 0 ..< 6 {
		a := (3 + k) % 12 // April..September
		b := (9 + k) % 12 // October..March
		if !north {a, b = b, a}
		summer[k], winter[k] = precip[a], precip[b]
		p_summer += precip[a]
	}
	p_winter := p_sum - p_summer
	s_min, s_max := min_max(summer[:])
	w_min, w_max := min_max(winter[:])

	if t_max < 10 {return .ET if t_max >= 0 else .EF}

	// Dry climates: annual precipitation below 10 × the threshold.
	p_th := 2 * t_year + 14
	if p_sum > 0 && p_summer >= 0.7 * p_sum {
		p_th = 2 * t_year + 28
	} else if p_sum > 0 && p_winter >= 0.7 * p_sum {
		p_th = 2 * t_year
	}
	if p_sum < 10 * p_th {
		if p_sum < 5 * p_th {return .BWh if t_year >= 18 else .BWk}
		return .BSh if t_year >= 18 else .BSk
	}

	if t_min >= 18 {
		if p_min(precip) >= 60 {return .Af}
		if p_min(precip) >= 100 - p_sum / 25 {return .Am}
		return .Aw
	}

	second: u8 = 'f'
	if s_min < 40 && s_min < w_max / 3 {
		second = 's'
	} else if w_min < s_max / 10 {
		second = 'w'
	}
	warm_months := 0
	for m in 0 ..< 12 {
		if temp[m] >= 10 {warm_months += 1}
	}
	if t_min > -3 {
		switch second {
		case 's':
			return .Csa if t_max >= 22 else (.Csb if warm_months >= 4 else .Csc)
		case 'w':
			return .Cwa if t_max >= 22 else (.Cwb if warm_months >= 4 else .Cwc)
		}
		return .Cfa if t_max >= 22 else (.Cfb if warm_months >= 4 else .Cfc)
	}
	third := 'a' if t_max >= 22 else ('b' if warm_months >= 4 else ('d' if t_min < -38 else 'c'))
	switch second {
	case 's':
		return Koppen(int(Koppen.Dsa) + d_index(third))
	case 'w':
		return Koppen(int(Koppen.Dwa) + d_index(third))
	}
	return Koppen(int(Koppen.Dfa) + d_index(third))
}

@(private = "file")
d_index :: proc(third: rune) -> int {
	return int(third) - int('a')
}

@(private = "file")
min_max :: proc(v: []f64) -> (lo, hi: f64) {
	lo, hi = v[0], v[0]
	for x in v {
		lo = min(lo, x)
		hi = max(hi, x)
	}
	return
}

@(private = "file")
p_min :: proc(v: [12]f64) -> f64 {
	lo := v[0]
	for x in v {lo = min(lo, x)}
	return lo
}
