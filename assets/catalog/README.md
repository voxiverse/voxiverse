# The catalog: Earth's content, as data, before it is in the game

Raw material for the game's living Earth: the species, plants, places, structures, materials
and crops a later task turns into mobs, plants, blocks and structures. **Nothing here is loaded
by the game yet.** Each entry is real (a real species, a real dwelling type, a real mineral)
with coarse, plausible numbers. The game's scale: 1 block = 1 m vertically for things on the
ground; the planet is 65 536 blocks around.

Layout: one JSON file per job, `assets/catalog/<kind>/<group>.json`, an object
`{"kind": "<kind>", "group": "<group>", "entries": [ ... ]}`. Ids are `snake_case`, unique within
their kind. Units are in the key names. Use `null` for an unknown value, never a guess
dressed as a fact. `notes` holds what a designer should know (one or two sentences).

Biomes are the game's (`common/worldgen/earth.odin`, `BIOME_NAMES`): ocean, frozen_ocean, beach,
river, plains, forest, taiga, tundra, desert, mountains, ice_sheet, rainforest, savanna,
cold_desert, steppe, mediterranean, subtropical_forest, mixed_forest.

## fauna/<biome>.json: animals

```json
{"id": "plains_zebra", "name": "Plains zebra", "latin": "Equus quagga",
 "class": "mammal", "biomes": ["savanna"], "regions": ["east_africa", "southern_africa"],
 "mass_kg": 300, "length_m": 2.4, "height_m": 1.3, "lifespan_years": 25,
 "diet": "grazer", "eats": ["grass"], "eaten_by": ["lion", "spotted_hyena"],
 "group_size": [5, 1000], "active": "day", "speed_kmh": 65,
 "migrates": "follows the rains", "temperature_c": [5, 40],
 "breeding": {"season": "rains", "young": 1, "gestation_days": 375},
 "behaviour": ["herds mix with wildebeest", "kicks and bites when cornered"],
 "sounds": ["barking bray", "snort"],
 "voxel_model": {"blocks_long": 3, "blocks_tall": 2, "parts": ["body", "head", "neck", "legs4", "tail"],
                 "colors": ["#f2f2f2", "#1a1a1a"], "pattern": "vertical stripes"},
 "drops": ["hide", "meat"], "player": "huntable; tamable: no",
 "notes": "The herd is the unit: model herds, not individuals, at a distance."}
```

`class`: mammal, bird, reptile, amphibian, fish, insect, arachnid, mollusc, crustacean, other.
`diet`: grazer, browser, herbivore, frugivore, granivore, nectarivore, insectivore, carnivore,
piscivore, omnivore, scavenger, filter_feeder, detritivore. `active`: day, night, dusk_dawn, any.

## flora/<biome>.json: plants and fungi

```json
{"id": "baobab", "name": "African baobab", "latin": "Adansonia digitata",
 "form": "tree", "biomes": ["savanna"], "regions": ["africa"],
 "height_m": [5, 25], "trunk_m": [2, 10], "lifespan_years": 1500,
 "growth": "slow", "leaves": "deciduous, dry season bare", "flowers": "white, at night, bats",
 "fruit": "dry pod, edible pulp", "temperature_c": [10, 45], "rain_mm_year": [200, 1500],
 "fire": "survives", "voxel_shape": "very thick short trunk, sparse flat crown of root-like branches",
 "blocks": {"trunk": "#8a7a6a", "leaves": "#6b8e3a"}, "uses": ["fruit", "fibre", "water store"],
 "notes": "A landmark tree: one is visible across the savanna."}
```

`form`: tree, shrub, grass, herb, succulent, fern, moss, lichen, fungus, aquatic, vine, crop.

## structures/<group>.json: built and natural features

```json
{"id": "yurt", "name": "Yurt", "origin": "human", "biomes": ["steppe", "cold_desert"],
 "cultures": ["Mongolic", "Turkic"], "era": "ancient to now", "footprint_m": [6, 6], "height_m": 3,
 "materials": ["felt", "wood lattice", "rope"], "purpose": "dwelling, moved with the herds",
 "parts": ["round lattice wall", "conical roof", "crown ring", "south door", "central stove"],
 "layout": ["a circle 6 blocks across", "door faces south", "stove in the middle, flue through the crown"],
 "blueprint": [
   "layer 0: . . w w w . .|. w . . . w .|w . . . . . w|w . . s . . w|w . . . . . w|. w . . . w .|. . w d w . .",
   "legend: w felt wall, d door, s stove, . air"],
 "found": "in groups of 2-8 near water and pasture",
 "notes": "Packed in a day: a camp may be gone when the player returns."}
```

`origin`: human, natural, animal (nests, dams, mounds). `blueprint`: optional layers from the ground up, rows
separated by `|`, one character per block, with a legend.

## materials/<group>.json: rocks, minerals, soils

```json
{"id": "granite", "name": "Granite", "type": "igneous rock", "found": ["mountains", "shields"],
 "depth_m": [0, 30000], "hardness_mohs": 6, "density_kg_m3": 2700, "color": "#b0a090",
 "made_of": ["quartz", "feldspar", "mica"], "weathers_to": "sandy soil, clay",
 "uses": ["building stone", "tools"], "notes": "The continents' foundation."}
```

## crops/<group>.json: domesticated plants and animals

```json
{"id": "emmer_wheat", "name": "Emmer wheat", "wild_ancestor": "wild emmer",
 "domesticated": {"where": "Fertile Crescent", "years_ago": 10000}, "kind": "cereal",
 "climate": ["Cs", "BS"], "season_days": 120, "yield_t_ha": 1.5, "spread": "Europe, Egypt, India by 5000 BCE",
 "needs": ["dry summer", "cool wet winter"], "notes": "One of the founder crops."}
```

## Rules for whoever writes entries

- Real things only, with their real names; plausible numbers, `null` when unknown.
- Breadth before depth: the common and the iconic first, then the strange.
- Write only your own file. Valid JSON (no comments, no trailing commas).
