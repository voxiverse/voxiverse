package client

// The rendered music (assets/music, made by `build music`) inside the
// executable: the Ogg of each piece and its metadata (a `.json`, read by the
// director, M44). Nothing plays it yet. The order is fixed, the title first.

Music_File :: struct {
	name: string,
	ogg:  []byte,
	json: string,
}

MUSIC_BUDGET :: 24 << 20 // bytes of Ogg, all pieces together

@(rodata)
MUSIC := [?]Music_File {
	{"title", #load("../assets/music/title.ogg"), #load("../assets/music/title.json", string)},
	{"meadow", #load("../assets/music/meadow.ogg"), #load("../assets/music/meadow.json", string)},
	{"night", #load("../assets/music/night.ogg"), #load("../assets/music/night.json", string)},
	{"deep", #load("../assets/music/deep.ogg"), #load("../assets/music/deep.json", string)},
	{"far", #load("../assets/music/far.ogg"), #load("../assets/music/far.json", string)},
	{"death", #load("../assets/music/death.ogg"), #load("../assets/music/death.json", string)},
	{
		"discovery",
		#load("../assets/music/discovery.ogg"),
		#load("../assets/music/discovery.json", string),
	},
}
