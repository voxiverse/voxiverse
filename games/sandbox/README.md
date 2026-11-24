# Sandbox

The engine's open world as a game, the one game players are offered (the title's
Singleplayer lists its universes), and the game a session plays when nobody names another
(`game.DEFAULT_GAME`). Players know it by the product's name, Voxiverse (its `INFO.name`);
the folder, the id and what saves and the wire carry stay `sandbox`. A universe of planets,
the home world Earth or one made from the seed, with its climate, sheep, farming, peoples and
their markets, and gates between worlds: build, explore, survive or create. There is no round
and no score. A universe nobody chose a mode for is played in survival (the creation screen
starts there; creative stays a choice), and a new player is given one field dressing and
nothing else (`KIT`; the pack empties the base pack's survival kit of its guns,
`pack/data/game_modes/survival.json`).

## Playing it

```sh
./build.sh run                                # the title: Singleplayer lists its universes
./build.sh run -- --game sandbox              # straight into a scratch Sandbox world
./build.sh serve -- --universe build/universe # the dedicated server plays it by default
```

The title's Singleplayer opens the saved universes; a new one made there (its planet, seed and
mode) plays the sandbox. The other games are met inside it as encounters (Horde's waves at
the ruined site, below) and run on their own only as dedicated servers.

## Gathering, crafting and outposts

The open world on one world: what a survivor gathers, what it makes of it, and the outposts
it sets down to come back to. The items, blocks and recipes are the pack's
(`pack/data/items/survival.json`, `blocks/survival.json`, `recipes/survival.json`,
`models/survival.json`); the rules are `survival.odin` and `server/survival.odin`,
`server/outposts.odin`, the screen `client/craft.odin`.

**Gathering.** Every block names the tier of tool that breaks it (the engine's block `tier`
and item `gather`, docs/packs.md). Hands break soil, sand, gravel, wood, leaves and plants;
stone, sandstone, coal and copper ore ask for tier 1 (a flint pick); iron ore and the
ancient alloy relics tier 2 (a copper pick); the sealed relic vaults tier 3 (the alloy
drill, which also gets one more of every ore and stone it breaks). A player in creative
breaks everything at once. Breaking with too little a tool keeps the block and says what
tier it needs.

Breaking takes time (the world rule `break_time`, which the sandbox sets to 1 as each world
opens when it finds it at 0; another value, a half or a double, stands;
docs/packs.md, "Breaking time"): hold the attack button on a block and a crack spreads over
it until it breaks. Each block's hardness is the seconds hands take; a pick is quick on
stone, ore and metal, a blade (the flint knife, the machete) on wood, plants and leaves,
and any tool a little on soil and sand. The alloy drill is the fastest tool (and keeps its
one more of every ore and stone). In seconds:

| Block (hardness, kind) | Hands | Flint knife | Machete | Flint pick | Copper pick | Alloy drill |
|---|---|---|---|---|---|---|
| Leaves (0.3, blade) | 0.3 | 0.1 | 0.07 | 0.3 | 0.3 | 0.3 |
| Dirt, grass, sand, gravel (0.6, any) | 0.6 | 0.4 | 0.2 | 0.5 | 0.3 | 0.17 |
| Log, planks (2, blade) | 2 | 0.67 | 0.33 | 2 | 2 | 2 |
| Stone, cobblestone (2.5, pick; tier 1) | no | no | no | 1 | 0.63 | 0.33 |
| Coal ore (3.5, pick; tier 1) | no | no | no | 1.4 | 0.9 | 0.47 |
| Copper ore (4, pick; tier 1) | no | no | no | 1.6 | 1 | 0.5 |
| Iron ore (5, pick; tier 2) | no | no | no | no | 1.27 | 0.63 |
| Salvage heap (2.5, pick; tier 1) | no | no | no | 1 | 0.63 | 0.33 |
| Alloy relic (4.5, pick; tier 2) | no | no | no | no | 1.13 | 0.57 |
| Relic vault (6, pick; tier 3) | no | no | no | no | no | 0.77 |

(Whole ticks, rounded up: a pick's speed is 2.5, 4 and 8, the knife's 3 and the machete's 6;
"no": the tool's tier is too low.) Where the sandbox is played, leaves leave fibre, gravel flint, coal ore coal, and
copper and iron ore their raw ore (the pack's overrides of the base pack's blocks).

The remains (salvage heaps, ancient alloy relics, remains caches, sealed relic vaults:
`sandbox:salvage_heap`, `alloy_relic`, `remains_cache`, `relic_vault`) are never placed by a
player: the remains round the home gate hold them (below, "Its remains"). A heap leaves salvage, a relic ancient
alloy, a vault a data shard; a cache (tier 1) and a vault spill a draw of finds when broken
open (`server/survival.odin`: `CACHE_LOOT`, `VAULT_LOOT`; `remains_spill` for remains opened
another way).

**Crafting.** The game's second action (`Craft`, X by default) opens the crafting screen
anywhere and closes it again: every recipe, what it makes, what it takes against what you
carry and how long it takes, those you can make where you stand first. Pick one and Make:
the server takes what it needs then and gives what it makes when its time is up (one at a
time; a line under the top says what is being made while the screen is closed), and it lands
with a chime made by code and "+2 Cord" floating up in front of you in gold (the event
`sandbox.made`, the engine's `made`). A recipe is the pack's, a process made by hand
(`sandbox:hand`) or within 5 blocks of a fabricator (`sandbox:fabricator`, a block made by
hand). Leaving with something being made gives back what it took.

**Using.** The third action (`Use`, B) works what is in the hand: a consumable is used up (a
field dressing heals 4, a ration heals over time, a stim patch turns a quarter of harm
aside: the engine's item `consume`), the survey scanner names the nearest ore, salvage or
relic within 24 blocks and which way it lies (then charges for 2 seconds), and a recall
unit, used up, takes you to your outpost.

**Outposts.** An outpost beacon (`sandbox:outpost_beacon`, made at a fabricator from iron, a
charge cell and an optic) placed anywhere makes an outpost. Whoever places it stands there
again after a death (kept with the character); any player may make it theirs too by using
it (the right button), so in co-op an outpost serves everyone on the server. No hostile
creature comes by itself within 48 blocks of a beacon (the spawned hook refuses it, as a
spawn rule's `safe` does round the world's spawn), so a lamp-lit camp by a beacon is a safe
night. An outpost goes into the logbook of whoever places or claims it (the journal, the compass
and the map show it). Only its placer may take a beacon down; a world keeps 32 at most. The crafting screen
lists the world's outposts (yours, and which is your respawn), and `/outposts` says them in
the chat. A death with no outpost (or one whose beacon is gone) stands you at the world's
spawn as before on the home world (its gate stands before it), and on a gate world before the
gate travellers arrive at, on its platform (its spawn may be thousands of blocks from any
gate), the death screen saying how far; one who leaves on a gate world comes back there.

**The pressure.** The night's creatures (below) and a death that drops what you carry, far
from where you were: an outpost is where you stand again and where nothing comes for you.
There is no hunger or thirst; what a survivor does earns it levels and skills (below).

**The first hour.** Break leaves for fibre and gravel for flint, logs for wood; by hand make
planks, cord, a flint knife and a flint pick (and padded armour). With the pick, stone and
coal and copper ore; by hand, a fabricator. At the fabricator: copper ingots, a copper pick,
wire, charge cells, glass and optics, lamps and a chest. With the copper pick, iron ore:
iron ingots, then an outpost beacon set down by your camp, and iron tools, weapons and plate.
Salvage and ancient alloy from the remains lead on to circuit boards, the scanner, alloy
plate, the drill and the exo armour.

The items, by kind (every one an ingredient or a use; `test_survival_every_item_is_obtainable`
walks what yields what):

- **Raw**: fibre, flint, coal, raw copper, raw iron; from the remains salvage (uncommon),
  ancient alloy and data shards (rare); from the creatures (below) hide, raw meat, feathers,
  raw fish and chitin, shell plates and venom glands (uncommon), and the machines' scrap
  (uncommon), power cells and lenses (rare), and the delves' servo bundles (uncommon), keeper
  coils (rare) and the custodian's core (epic); from the gate worlds' own creatures thistle
  horns, sail membranes, ember glands and spore sacs (uncommon), frost pelts and fangs
  (rare). What the creatures leave makes padding, trail
  rations (meat by hand, fish cooked at a fabricator), flechettes, climbing spikes, stim
  patches, charge cells, optics, salvage, padded boots and a plate cuirass another way, and
  the gate worlds' leave a machete, spark cartridges, lamps, regen ampoules and spore tonics
  another way and the sail cloak, the rimefur hood and the fang blade of their own.
- **Refined**: cord, padding, copper and iron ingots, wire, charge cells, optics, circuit
  boards, alloy plate; and the base pack's planks, glass, stone bricks, lamps, chest and hoe.
- **Tools**: flint pick (tier 1), copper pick (tier 2), alloy drill (tier 3, one more of each),
  keeper drill (an alloy drill upgraded with the custodian's core: the fastest; epic).
- **Melee**: flint knife (quick, short), machete (a wide sweep), survey maul (slow, heavy,
  long), shock baton (fast, hard), fang blade (a striper's fangs: quick, rare), relic blade
  (the remains': epic), arc lance (the delves': long and heavy; epic).
- **Ranged**, each loading its own: rivet driver (eight heavy shots, rivets), flechette
  caster (six darts close in, flechettes), arc repeater (automatic, forty light bolts, spark
  cartridges), coil rifle (three scoped long shots, coil charges; epic).
- **Armour** by slot, each set more `defence` (the engine's modifier: a fraction of harm
  turned aside, 0.8 at most): padded (common; its boots take a quarter off a fall), plate
  (uncommon; the cuirass slows), exo (rare; the harness quickens, the legs jump, the striders
  take four fifths off a fall), keeper helm and cuirass (the delves': rare, epic); climbing
  spikes (jump higher, land softer); the rimefur hood (a rimeclaw's pelt: rare).
- **Trinkets** (the two trinket slots; the offhand takes one too): stride coil (faster), gyro stabiliser (half a fall's harm), sail cloak (a sailback's sail: a third of a fall's harm, a little faster),
  heart regulator (more health), ward emitter (the remains': defence) and the phase lattice
  (a vault's: faster, one more jump in the air; legendary), and below the keeper sigil
  (defence, health) and servo spring (higher, faster).
- **Consumables**: field dressing, trail ration, med gel, stim patch, regen ampoule, and the
  remains' restorer.
- **Gadgets**: survey scanner, tether hook (short and quick) and long hook (the engine's
  grapple), recall unit.
- **Building**: fabricator, outpost beacon, hull plate, alloy panel, grating.

What it tells its players: `sandbox.survival` (whether a fabricator is in reach, what is
being made and how far, the world's outposts) and the event `sandbox.made`; what they ask:
`sandbox.craft`.

## Quests

A new survivor has a first hour with a direction: thirteen quests that walk it through the loop
above, from bare hands at the dead gate to the nearest camp's elder, the ruin's altar and back to
the gate's board (`pack/data/quests/first_hour.json`, the engine's quests:
[docs/packs.md](../../docs/packs.md#quests)), three after it lead down into a delve, and the
camps' people give seven more (below, "Its camps and their people").
Each opens when those it comes after are done; the journal (J) lists those under way and done
with their steps and rewards, and the HUD's tracker (top right) shows the step of the first
under way, or of the one picked there with Track. A step done chimes and says so in gold, as a
craft does; a quest done gives its reward. A step that needs a place points the compass and
the map at it once the logbook has it (a fallen tower, a sealed vault, the ruin, the court).
Nothing counts in creative.

| Quest | After | Steps | Reward | XP |
|---|---|---|---|---|
| Waking at the Gate | | carry 6 fibre, 5 flint, 4 logs | 2 cord | 40 |
| Edge and Point | Waking | make 4 planks, 2 cord, a flint knife, a flint pick | field dressing | 60 |
| The Court of Remains | Edge and Point | find a fallen tower; break open a remains cache | salvage | 80 |
| Under the Turf | Edge and Point | carry 8 stone, 3 coal, 4 raw copper | 4 coal | 80 |
| A Workshop | Under the Turf | make a fabricator; set it down; make 3 copper ingots | 2 copper ingots | 100 |
| Patch and Mend | A Workshop | make a field dressing; use one | 2 field dressings | 80 |
| Meat and Hide | Patch and Mend | kill a loper; make a trail ration; eat one | padded vest | 120 |
| A Light to Return To | Meat and Hide | make a copper pick; carry 3 raw iron; make an outpost beacon; place it | 4 lamps | 160 |
| Smoke on the Horizon | A Light | speak with the elder of a camp (the beacon hears the nearest camp's call: it goes into the logbook, and the compass points at it) | 2 trail rations | 150 |
| What the Keepers Left | A Light, The Court | carry 2 salvage, 3 ancient alloy; make a circuit board, 3 alloy plate | charge cell | 200 |
| The Sealed Vault | What the Keepers Left | find a sealed vault; make an alloy drill; kill a sentry; break the relic vault | 2 med gel | 300 |
| The Ruin Wakes | The Sealed Vault | find the ruin; win its fight (`sandbox:ruin`) | regen ampoule | 400 |
| An Address | The Ruin Wakes | write an address on a gate | data shard | 250 |
| The Sunken Stair | An Address | find a sunken stair; break open a keepers' cache | keeper's key | 250 |
| The Deep Works | The Sunken Stair | kill a carapace; reach a delve's third depth | restorer | 350 |
| The Custodian | The Deep Works | win the custodian's fight (`sandbox:delve`) | keeper sigil | 500 |

The engine sees most of it (what a player carries, places, breaks, finds, kills, uses up, an
address written on a gate); the sandbox tells it what its crafting made
(`server/survival.odin`), who won the ruin's fight (`server/ruin.odin`, `RUIN_ENCOUNTER`) or a
custodian's (`server/delve_boss.odin`, `BOSS_ENCOUNTER`) and
what was said in a conversation (`server/talk.odin`: a dialogue's id as it begins, a reply's
`talk`), by `core.quest_note`. `server/quests_test.odin` holds the chain to the world: every
step can be done from real ids with what the steps before gave (a tool of a block's tier, a
fabricator standing, a talk step said by a reply a dialogue offers on that very step), every
quest opens in turn (none left waiting for ever), and progress is kept with the character.

## Levels and skills

A survivor grows by what it does (`pack/data/levels/survivor.json`, `pack/data/skills/survivor.json`,
the engine's levels and skills: [docs/packs.md](../../docs/packs.md#levels-and-skills)). Its
experience shows as a bar over the hotbar with its level beside the health bar; the
Character section (C) holds its skills. Nothing is earned in creative. Every number is the
pack's, a first guess to tune there.

| Deed | Experience |
|---|---|
| A creature killed (by its threat, the creatures' table below) | 4 a point of threat |
| A creature met for the first time | 10 |
| A place found: a gate opened, the ruin, a site of the remains (a delve's stair head too), a town; a delve's third depth (as the ruin) | 50, 150, 40, 60; 150 |
| A thing made for the first time | 8 |
| The ruin's fight won, a custodian's | 300 |
| A quest done | its XP (the quests' table above, 1870 in all) |
| A sheep sheared, a sheep fed | 5, 2 |

The levels run to 30, each costing 40 more than the one before (60 for level 2, 17980 in all
for 30), and each gives a skill point. A skill's rank costs its points once its branch has
had what it needs spent in it; every skill and every rank takes 36 points, so a survivor
chooses. Unlearning every skill is free within 6 blocks of an outpost beacon (the Character
section's Unlearn, or `/skill reset`; `/skill <name>` learns a rank, `/skill` lists them).

| Skill | Title | Branch | Each rank | Ranks | Cost | Needs |
|---|---|---|---|---|---|---|
| `sandbox:quick_hands` | Quick Hands | Survival | breaks a tenth faster | 3 | 1 | 0 |
| `sandbox:hardy` | Hardy | Survival | 2 more health | 3 | 1 | 0 |
| `sandbox:sure_footing` | Sure Footing | Survival | 15% of a fall's harm turned aside | 2 | 1 | 2 |
| `sandbox:trapper` | Trapper | Survival | 10% likelier drops from creatures | 2 | 1 | 2 |
| `sandbox:second_wind` | Second Wind | Survival | regenerates a quarter faster | 2 | 2 | 4 |
| `sandbox:heavy_blows` | Heavy Blows | Combat | a swung weapon 12% harder | 3 | 1 | 0 |
| `sandbox:steady_aim` | Steady Aim | Combat | a shot's cone 15% tighter | 2 | 1 | 0 |
| `sandbox:quick_reload` | Quick Reload | Combat | a reload 12% quicker | 2 | 1 | 2 |
| `sandbox:hardened` | Hardened | Combat | 4% of every harm turned aside | 3 | 1 | 3 |
| `sandbox:fast_fabrication` | Fast Fabrication | Engineering | making takes a tenth less time | 3 | 1 | 0 |
| `sandbox:prospector` | Prospector | Engineering | stone, ore and relics give one more 10% of the time | 3 | 1 | 0 |
| `sandbox:field_chemistry` | Field Chemistry | Engineering | consumables heal 15% more | 2 | 1 | 2 |
| `sandbox:surplus` | Surplus | Engineering | making gives one more 10% of the time | 2 | 2 | 4 |

The sandbox reads the two of its own (`server/survival.odin`, through `core.skill_value`):
a recipe's time and the chance of one more made; the crafting screen shows the time as the
skills make it. Where a dead survivor stands again (its outpost, how far off, or the world's
spawn) is the sandbox's word on the death screen (`respawn_where`: `server/outposts.odin`).

## Its sheep

The sandbox's animals are its own: the sheep (`sandbox:sheep`, its pack's creature, whose mind
is the game's). A sheep stands and looks about, watches a player who comes within 6 blocks,
wanders up to 8 blocks, grazes (a shorn one eats the grass in front of it, which turns to dirt,
and its wool grows back) and runs from what hurt it. They come by themselves by day on grass,
in groups of one to three, at most six near a player (the pack's spawn rule), with wild genes.

Using one (the right button) with wheat feeds it: a lamb grows up a tenth sooner, an adult
becomes ready to breed for 30 seconds. Two ready sheep within 8 blocks walk together and have a
lamb of both, which grows up in ten minutes; then each waits five. Using an adult with anything
else shears it: one to three wool fall, black for a black sheep, and it is shorn until it
grazes. Their genetics are real and tiny (`genetics.odin`): two genes, wool (white or black)
and coat (plain or spotted), each with a rare recessive form; a lamb takes a copy of each from
each parent, and one copy in a thousand flips. What a player sees of one (shorn, a lamb, black,
spotted, in love: hearts rise) is its looks, shown by the server part and drawn from the
pack's model.

`/sheep [lamb] [shorn] [black] [spotted]` sets a sheep of those looks down in front of you
(the summoning permission, `world.summon`).

The statistics it keeps of a player: `sheep.sheared` (5 experience each) and `sheep.fed` (2),
and of a world `sheep.born`, shown with the engine's.

**The world classes' rare resources.** Each class of gate world (docs/world.md, "World
classes") has one resource no other has; the pack says what tool it asks for, what it
leaves and what it makes (`blocks/survival.json`, `items/survival.json`,
`recipes/survival.json`), so going there is worth it:

| Class | Block (tier) | Leaves | Makes |
|---|---|---|---|
| Temperate | amber ore (1) | amber (uncommon) | amber charm (trinket: +3 health, a little defence), amber salve (heals 6, then 1 a second) |
| Canyon | opal ore (2) | opal (rare) | opal visor (helm: defence 0.1, +4 health), 3 optics from one |
| Frozen | cryolite ore (2) | cryolite (rare) | 4 iron ingots from 2 raw iron (a flux), frost striders (boots: 0.6 fall guard, faster) |
| Ocean | nacre (1) | nacre shard (rare) | nacre greaves (legs: defence 0.1, jump higher), 2 optics |
| Volcanic | sulfur ore (1) | sulfur (uncommon) | 30 spark cartridges, 2 stim patches |
| Fungal | glow cap (a blade) | glow spores (uncommon) | 4 lamps, spore tonic (heals 6, then 1 a second for 20) |
| Moon | ilmenite ore (3) | ilmenite (epic) | the titan drill (the best tool: two more of each ore and stone, speed 12), the titan cuirass (defence 0.2, +4 health) |
| Jungle | jade ore (2) | jade (rare) | jade talisman (trinket: faster, +3 health), jade tonic (heals 4, then 3 a second) |

The classes' rock (basalt, slate, limestone, red rock) asks for tier 1 like stone, obsidian
for tier 2. `test_survival_every_item_is_obtainable` reaches every one of them.

## Its creatures

Beside the sheep the home world has twenty creatures of its own (`pack/data/entities`:
`wildlife.json`, `predators.json`, `machines.json`, `delve.json`), each with its model, its voice, its
place and hours and what it leaves where it dies (its kind's `drops`: hide, meat, feathers,
fish, shell plates, chitin, venom glands, and the machines' scrap, power cells and lenses,
`pack/data/items/creature_drops.json`; the survival loop's recipes make things of them,
above). Their minds are
the server's (`server/wild.odin`), made of `server:play`'s (`mind.odin`): what each does is
its state, and what a player sees of it (asleep, warning, winding up a blow, aloft) is the
look of that state, drawn by its model.

| Creature | Where and when | What it does | Health | Threat |
|---|---|---|---|---|
| loper | grass, by day, herds of 3 to 5 | grazes with its herd, watches a player from 10 blocks, runs with the herd from one within 5 | 8 | 1 |
| twitchet | open ground, day and dusk, 1 or 2 | freezes, ears up, at a player within 9 blocks; bolts from one within 5 | 2 | 1 |
| wheelwing | open ground, by day, 1 to 3 | pecks on the ground, wheels over its ground 6 to 12 blocks up, lands again; takes off from a player within 7 | 3 | 1 |
| glassfin | in water over sand, gravel, dirt or clay, any hour, schools of 2 to 4 | swims with its school, darts from a player within 5, never leaves the water | 2 | 1 |
| domeback | open ground, by day, alone | browses slowly, minds no one; hurt, shuts itself in its shell for 6 seconds (a quarter of any harm gets through) | 20 | 2 |
| hacklebird | open ground, by day | guards its ground: a player within 9 blocks sees its crest and ruff go up; one who stays within 5, or hits it, is kicked (3) until 16 blocks from its ground | 12 | 3 |
| snouter | grass in the woods, by day | roots about; a player within 6 sees its back bristle and dust fly; one who stays within 4, or hits it, is charged (4) | 16 | 4 |
| pitmaw | the floor of caves, any hour, never within 48 blocks of the spawn | lies buried with its eye stalks out; rises in a spray of grit (a second) at a player within 5 blocks and bites (4); slow, so walking away escapes it; buries itself again | 14 | 4 |
| barbcaster | sand or gravel by the water, dusk to dawn | keeps 6 to 10 blocks off and flings barbs (2) from its tail, drawing it back for most of a second first | 9 | 3 |
| duskrunner | open ground in the woods, by night, packs of 3 or 4 | the pack circles a player 6 blocks off; one at a time, its markings flaring first, darts in to bite (2); one badly hurt runs | 6 | 2 |
| cragmaul | open ground and bare rock, by night, alone | slow and heavy: lifts both fists over its head for more than a second before each blow (7); cannot run | 40 | 8 |
| sentry | posted at the remains | folded at its post until a player comes within 10 blocks of the post; wakes (sparks, a second and a half), shoots bolts (3) charging each first, folds again at its post, whole, once the player has gone | 24 | 5 |
| tender | posted at the remains | a mending drone that hovers from stone to stone 1 to 3 blocks up, working sparks into each; minds no one; hurt, flies off up | 8 | 1 |
| watcher | near the remains, by day | hovers 10 to 16 blocks from a player and 5 up, keeping it in sight for most of a minute, then rises and goes; never attacks; hurt, goes at once | 10 | 1 |
| bulwark | posted at the ruin's north gate | the guardian, kneeling until a player comes within 7 blocks of its post; rises (two and a half seconds) and fights with both fists, raising them for a second and a half before each blow (9); gives up 16 blocks from its post and kneels again, whole | 160 | 20 |
| longstrider | grass, by day, rare, alone, 40 to 60 blocks off | a giant as tall as the trees, to walk toward: walks slowly where it likes, grazing, and minds no one; hurt, walks away | 300 | 5 |
| scuttler | posted in a delve's rooms | folded flat until a player comes within 8 blocks of its post; wakes (half a second) and runs at it (5.5 a second), nipping (2) with its mandibles opening first (a quarter second); folds again at its post, whole, once the player has gone | 10 | 3 |
| spire | posted in a delve's rooms, fixed where it stands | folded until a player comes within 14 blocks; its head rises (a second) and it shoots bolts (3) at a player in its sight, charging each most of a second; never moves | 18 | 4 |
| carapace | posted in a delve's deeper rooms | kneels behind its great plate until a player comes within 9 blocks; wakes (two seconds) and walks at it, the plate turning all but 15% of a player's blow from before it aside; lowers it to raise its maul for a second before each blow (6), when blows from the front get through | 60 | 9 |
| custodian | kneeling in a delve's deepest chamber | the boss: below, "Its delves" | 360 | 30 |

A creature's threat (its kind's `threat`; the sheep's is 1, the night's creatures' come
from their health and blow) is what its kill's experience counts by and what the target
frame shows beside its name.

Every attack is wound up first (`play.fight_fair`): a player who sees it coming can step out
of reach or behind something. The creatures that fight go for a player who can be hurt (not
in creative, not watching) and leave alone one fighting at the ruin; the timid ones flee any
player they see. They come by themselves by their spawn rules (the sea's and the caves'
too: a rule's `place`), but a barbcaster only near water, a duskrunner or a snouter only
under trees, a watcher only within 96 blocks of remains, and none round a player who has 24
of them within 64 blocks. One with no player within 48 blocks thinks once in eight ticks.

The machines are the remains' own (`server/remains_machines.odin`) and never touch a gate. When the
ruined site is built in a session it posts its own, each kept with the world and set down
again if it is not at its post: a sentry at each corner of its apron, two tenders by its
walls and the bulwark before its north gate (the south gate is where the ruin puts players
out). The remains round the home gate (below) take theirs the same way: each site but the
road is marked once built (`remains_mark`: watchers come near it) and sets down the machine it
keeps as it is built (`remains_post`). Hurt while asleep, a machine lets half the harm
through.

On a gate world of a class only the creatures `worlds.odin` lists for it come by themselves
(`spawned` refuses the rest): Earth's kin all of them, a canyon its hacklebirds, twitchets,
duskrunners, cragmauls and pitmaws, a frozen world its cragmauls, pitmaws and fish, an ocean
world its fish, barbcasters and small island creatures, a volcanic world its cragmauls,
duskrunners and pitmaws, a fungal world its small and many-legged ones, a jungle nearly all,
a moon none. Their grounds include the classes' (`block_tags/creatures.json`: `wild_ground`,
the open ground the small creatures come on, is the plant soil and red sand, ash and mud).

The delves keep theirs the same way (below, "Its delves"): posted as a delve is built, kept
with the world, asleep at their posts; the custodian is set down by its delve each session.

**The gate worlds' own.** Each class of gate world but the moon has one or two creatures
found nowhere else (`pack/data/entities/natives.json`; `worlds.odin`'s `CLASS_NATIVES`, which
`spawned` holds them to: never on the home world, never on another class), on its own ground
(`block_tags/creatures.json`: `canyon_rock`, `ash_ground`, `jungle_floor` beside the others).
Their minds are the roster's pieces (`server/natives.odin`), and what they leave makes things
of its own or known things another way (`items/creature_drops.json`, `recipes/survival.json`):

| Creature | Class, where and when | What it does | Health | Threat | Leaves, and what it makes |
|---|---|---|---|---|---|
| thistlebuck | temperate; grass, by day, herds of 2 to 4 | a mossy grazer with thorny antlers: grazes with its herd, watches from 10 blocks, runs with the herd from a player within 5 | 12 | 1 | hide, meat, thistle horn: a machete (2 horns, planks, cord), 16 flechettes (with flint) |
| sailback | canyon; red rock and sand, by day | basks on the mesas; a player within 10 sees its sail flare red, one who stays within 5, or hits it, is bitten (4) until 18 blocks from its rock | 16 | 4 | hide, sail membrane: the sail cloak (trinket: 0.35 fall guard, a little faster), 2 padding |
| rimeclaw | frozen; snow, any hour, alone | a white stalker: its crest rises at a player within 14 blocks; one who stays within 7, or hits it, is run down, claws raised before each blow (5), until 28 blocks off | 26 | 6 | hide, meat, frost pelt: the rimefur hood (helm: defence 0.07, +3 health), 3 padding |
| surfclaw | ocean; shore sand and gravel by the water, any hour | a crab as broad as a man is tall: lifts its claw at a player within 8, pinches (4) one within 4 until 12 blocks off; half of any harm through its shell unless it is fighting | 18 | 4 | chitin, shell plates, fish |
| driftray | ocean; in the sea, any hour, in pairs | glides in the water, slides away from a player within 6 | 6 | 1 | fish |
| cinderhound | volcanic; ash and basalt, dusk to dawn, packs of 2 to 4 | its cracks glow like coals: the pack circles a player 6 blocks off and, one at a time, its glow flaring white, darts in to bite (3); one badly hurt runs | 9 | 3 | hide, ember gland: 24 spark cartridges (with copper), 3 lamps (with glass) |
| sporemaw | fungal; mycelium, any hour | passes for a toadstool: heaves out of the ground in a burst of spores at a player within 5 and lashes (4); slow, so walking away escapes it | 16 | 4 | spore sac, glow spores: a regen ampoule (with med gel), 2 spore tonics (with fibre) |
| lanternmoth | fungal; mycelium, dusk to dawn | a great moth glowing teal: rests, flutters over its ground, lands again; takes off from a player within 7 | 4 | 1 | glow spores, feathers |
| striper | jungle; grass and mud under the trees, any hour, alone | a great striped hunter: crouches, stripes darkening, at a player within 12; runs down one who stays within 6, or hits it, mauling (6) until 24 blocks off | 30 | 7 | hide, meat, fang: the fang blade (melee 7, quick, rare), 24 flechettes (with iron) |
| leafwing | jungle; grass and mud, by day | a green lizard that glides on flaps of skin; takes off from a player within 7 | 3 | 1 | meat, feathers |

The moon has none living: its keepers' machines (sentries) stand folded at its places (below,
"The gate worlds' places").

`/creatures wildlife|guards|predators|machines|giant|delve|natives|all [still]` sets a group
down in a row in front of you (the summoning permission; `all` is the home world's and the
delves', `natives` the gate worlds' own), `still` standing for a picture.

## Its nights

From dusk to dawn (a fifth of the day either side of midnight) the base pack's hostile
creatures come out in every world of the sandbox: shamblers in ones and twos, now and then a
pack of two or three skitters, on open ground (grass, dirt, sand) under the sky, 24 to 40
blocks from a player, never within 48 blocks of the world's spawn point, at most three of each
kind near one player. The rules are the sandbox pack's data (`pack/data/entities/hostile.json`,
overriding only the creatures' `spawn`) and the engine's spawner runs them, so they come from
each world's seed and tick like everything else, within its entity budget; a natural one goes
when nobody is near. Each goes for the nearest player within 16 blocks who can be hurt and
strikes it (`play.hunt_tick`, `server/danger.odin`); one in creative mode, or watching, is left
alone, and none comes within 48 blocks of an outpost's beacon (above). They drop nothing
(their kinds have no drops). The spitters, hulks and the matriarch
come only in Horde's waves, which are fought at the ruined site (below) too.

## Its ruined site

Every home world has a ruin, a few minutes' walk from the spawn: on ten rings round it from
240 to 456 blocks out, sixteen spots on each starting in a direction of the world's seed, the
first whose ground is dry and level (no sea, beach, river, lake, mountain, ice or overhang
under it or its apron, the land within 5 blocks of even); when none is, the dry spot whose
land is the least uneven. Its floor is the middle height of the land there (never under the
sea's top), and the ground is levelled as it is built: everything over the floor cleared over
the ruin and a 4-block apron round it, the hollows and the water under them filled with
stone, the apron's top grass, so it is never buried or perched and every gate opens on ground
(over 60 seeds, 35 sites were level, one touched water, and the land under the walls was at
most 11 blocks uneven before levelling). It is a square of broken walls 27 blocks wide with a gate in the
middle of each side, a tower in one corner whose lamps show it from afar, four stumps of
pillars, cracked ground in the other corners and a dais in the middle with the altar
(`sandbox:ruin_altar`) on it. It is built when a player first comes within 160 blocks of it in
a session (its ground is kept loaded while one is near, or while it is awake), whole, over
what stood there, so what a blast or a crash left is gone; its blocks are not the players' to
change. Once it is built it is a place in the logbook of every player in the home world
(`core.logbook_place`, kept with the character): their journal lists it, the compass marks
it and the map shows it.

Using the altar (the right button) wakes it, for everyone inside its walls who can be hurt
(not in creative, not watching; one who has things set aside already cannot wake it). Each of
them is locked in to fight: its own things are set aside (kept with its character, untouched
by death, saved with it) and the mode it was in remembered; it is put in the encounter's mode
(`sandbox:encounter`: health, nothing dropped at death, a pistol, a rifle, a shotgun and 90
rounds), and a ward of crystal (`sandbox:ruin_ward`) rises round the walls. Five waves come out
of the four lairs, Horde's waves (`common:wave`'s plan and `server:play`'s crowd: shamblers
from the first, skitters from the second, spitters from the third, hulks from the fourth, the
matriarch with the fifth, each wave an eighth tougher), three seconds after it wakes and ten
seconds after each wave is held; between waves each fighter gets 30 rounds and 10 health. While
it is awake nobody gets out and nobody gets in: a fighter outside the walls is put back by the
altar, anyone else inside is put out by the south gate, and a creature that gets out is gone and
comes out of a lair again. The night's creatures (danger, above) leave the fight's alone.

The guns are tuned as Horde tunes them (loading the ruin's rounds, `sandbox:round`; a reload
takes them from the pockets, and with none the gun stays empty), but only for the players in
the encounter's mode: the tuning is the mode's `weapons` (`pack/data/game_modes/encounter.json`,
the engine's `game.weapon_of`), not an `"override"` of the items, so every other player's guns
stay the base pack's. Nothing of the kit leaves the fight: a fighter cannot throw anything
away while it fights (the `dropping` hook refuses it), and the ruin's rounds vanish when
anyone not fighting walks over one.

The fight ends when the fifth wave is dead: every fighter standing has its own things back (in
place of the encounter's) and its own mode, and the altar drops each a sniper, jump boots and
a feather charm. A fighter who dies is out of it: it stands again at the world's spawn as any
death in the sandbox does, with its own things and mode given back as it stands, so it loses
nothing it brought. When no fighter is left the fight is lost. A fighter who leaves the server
is out too; its things stay set aside with its character and come back when it next joins (also
after a server that stopped during a fight), and it is put out of the ruin if it joins inside.
Then the ward falls and the ruin sleeps until its altar is used again. A fight does not outlive
the session.

What it tells its fighters: `sandbox.ruin` (the fight's phase, wave, creatures left and
seconds of a countdown or break; drawn as a bar across the top), and a notice as the ruin
wakes, each wave sets out and is held, and a fighter falls.

## Its remains

A new universe's home world has the remains of whoever stood its gate there, so its first
minutes have things to see and walk to; nothing says what they were (`server/remains.odin`
places them, `server/remains_build.odin` draws them). All of it comes from the world's seed:

- **The court.** The dead home gate stands a step down in a worn platform of slate tiles (21
  by 11 blocks round the gate's box, its floor a layer over the gate's platform), with gravel,
  moss and grass through it, a broken parapet open in front of the gate and toward the road,
  up to three rings of steps down (or up) to the land round it, copper conduits in its floor
  behind the gate, four pylons of dark steel on plinths (two flanking the gate, two behind it;
  one or two stand whole with grating and a copper cap, the others are broken low, their pieces
  lying on the floor) and up to eleven standing stones 18 to 20 blocks from the gate, some
  gone, some fallen, none on the spawn's side. The spawn, 8 blocks in front of the frame,
  looks at it.
- **The old road.** Stretches of paving (8 to 16 blocks, 12 to 36 apart) with kerbs and posts,
  from out of the court toward the ruin (below) to short of its apron, broken off where the
  water or a cliff took it.
- **Scattered remains**, 60 to 380 blocks from the gate, one of each kind and four or five more,
  at least 40 blocks apart: a fallen pylon beside its stump, its copper head at the far end; a
  wall half buried, rising and falling along its length, with a doorway and sometimes a corner;
  a round tower fallen in on one side, its rubble spilled, a remains cache inside one in two; a
  grassed mound over a sealed chamber of riveted iron whose dark steel door shows in a cut, with
  a relic vault inside (one digs in); a ring of standing stones round a dead plinth. Each is
  drawn from its own seed (its size, its way, its breaks, what grows on it) and follows the
  land, sunk a block into it. What a survivor takes from them is the survival loop's (above):
  salvage heaps in a tenth of a tower's rubble, along a fallen pylon's shaft and in a wall's
  doorway, an alloy relic in about a third of the towers' floors, pylons' gratings and rings'
  plinths, the towers' caches and the vaults' relic vaults. The court holds none.

Every site stands on dry ground not too uneven for its kind, clear of the court, the ruin's
apron, the generator's structures and each other. Over 60 seeds of the Earth generator: 4 to
10 scattered sites a world (8.9 on average), every kind in 58 to 60 of the 60 worlds, the road in
53 (in the others the way to the ruin is water or cliffs), at most 1% of a site on wet ground.
A site is built in one paste when a player comes within 192 blocks of it and its ground is
loaded (the court as the first player arrives), and is then the world's like any block: dig
it, break its finds open. The world's `sandbox.remains.txt` remembers which are built; a
world saved before there were remains gets none, so nothing is built over what its players
made. A player who comes within 32 blocks of a built site has it in its logbook (the court as
"Gate court", the others as a fallen pylon, a buried wall, a fallen tower, a sealed vault or
standing stones), so the journal lists it, the compass marks it and the map shows it.

The remains keep their machines (above), each set down once as its site is built and kept
with the world: a sentry asleep in the cut before each vault's door and in each tower that
holds a cache, a tender over each ring of stones and by each fallen pylon's stump, and one
tender on the court's floor behind the gate, which no machine ever touches. No sentry keeps a
post within 64 blocks of the spawn (the most any predator's spawn rule keeps clear), the
bulwark is the ruin's alone, and a world whose creatures do not come by themselves (the image
scenes, benchmarks) gets no machines from the remains.

## Its peoples and markets

On a world built on the planet (the home world when it is Earth), the sandbox keeps the
towns' markets (`economy.odin`, `market.odin`, `trade.odin`: docs/world.md describes the
model), on the peoples' history and settlements of `common/planet` (which stay there: the
benchmark tool, which may not import a game, times them). The history is a function of
the planet, the world's address and seed and the day; the towns it implies near the players
have markets in detail, stepped a market month (30 world days) at a time, with news and
caravans between them; the rest are priced lazily from the history, so a town left and come
back to does not jump. What the history does not give back (the detailed stocks, what the
lazy towns remember) is kept with the world, `sandbox.economy.vxe`.

Each character is a trader (its record, kept in its character file): silver (20 to start),
cargo of each good, and the prices it saw where it stood. Standing in a town (within 15 km of
it) the HUD says `Market of <town>` and the key that opens it; the game's action (`Market`,
Z by default) opens the market's screen there and pressed again closes it: each good's
price, stock (units of a person's month of the good: a fresh market holds one month of the
town's need of each, so every stock reads the same until trade and droughts move them), what
you carry and how old the news behind the price is; pick a good and a quantity, buy or sell.
Walking out of the town closes it. The
server judges every trade (where you stand, your silver, your cargo, the stock). `/town` takes you to the nearest
town with a market, set down from above on the dry land nearest its place within its market's
radius (a town's place is its climate cell's centre, which may be sea), so you arrive in its
market (the teleport permission, `teleport.tp`). Only Earth has towns: a world not built
on the planet (a scratch world, `--game sandbox` or `singleplayer`, or a universe made
elsewhere than Earth) has none, and `/town` says so; on Earth they are worked out on a thread
in the seconds after arriving, and `/town` before then says to try again.

A world's interventions log (`sandbox.interventions.vxi`: what players did that its history
carries forward; a settlement founded is a town of the history from then on) is listed by
`/interventions [radius]` (the `world.interventions` permission).

What it tells its players: `sandbox.market` (the market of the town a player stands in, or
none), the events `sandbox.trade_refused` (why) and `sandbox.market_open`; what they ask:
`sandbox.trade`.

## Its delves

Under the home world lie the keepers' works: two or three delves a world (2.4 on average over
60 seeds; at least one in each), the sandbox's second encounter beside the ruin
(`server/delve.odin` places and builds them, `server/delve_plan.odin` lays them out,
`server/delve_boss.odin` runs the fight at the bottom). All of it comes from the world's seed:

- **Where.** Each in its own third (or half) of the compass from a direction of the seed's,
  560 to 880 blocks from the spawn, past the ruin and the remains: the first of 96 spots whose
  land round the stair head is dry and at most 4 blocks uneven, whose land over the whole delve
  is dry and nowhere more than 8 blocks under the stair head's floor (so no depth shows in a
  hillside), and whose 39 by 39 footprint keeps 24 blocks from the ruin's apron, the remains,
  the camps and the generator's structures (its dungeons too) and 160 from the other delves
  (site.odin's footprints). One left out there is tried again anywhere round.
- **The stair head.** On the land: a platform of slate tiles round the opening of a spiral
  stair, four posts of dark steel under a frame of riveted iron, the ground round it levelled;
  it hums. A player within 24 blocks has it in its logbook as a "Sunken stair", so the journal
  lists it, the compass marks it and the map shows it (a camp's scout sells the way to one).
- **The layout.** Three depths, 9 blocks apart, the first 16 under the stair head: each a grid
  of 3 by 3 cells of 13 blocks, a room in each, joined by corridors three wide along a random
  tree of the grid, so every room is reached and by one way only. Each depth's landing is the
  foot of the stair from above; its descent, the room the most corridors from it, holds the
  spiral stair down to the next depth's landing straight below (a step a block, round a pillar
  whose top is a lamp in the floor above). The third depth's descent is the boss's chamber. A
  leaf of the tree that is neither landing nor descent may be a vault behind a locked door,
  never on the way down. The rest are guard posts, store rooms, machine halls and collapsed
  rooms. Slate above, basalt in the second depth, dark bricks at the bottom; moss and mossy
  bricks here and there; a lamp in each landing and in about a third of the other rooms, the
  corridors dark.
- **Shut in.** Every room and corridor has its own shell (walls, floor and ceiling); the rock
  between is the world's own, so a cave or water running through a delve's box is cut off by
  the shell and nothing of a delve opens into either. Over 200 seeds every layout is sealed,
  its boss's post and every room but the locked vaults are walked to from the stair head (a
  block up at a time, three down at most), each locked vault once its door is gone and the
  reward vault once its ward is (`delve_plan_test.odin`).

| Room | What it holds | Machines (depths 1, 2, 3) |
|---|---|---|
| Landing | the stair from above, a lamp | none |
| Descent | the stair down, its lamp in the floor | a scuttler, a scuttler, none |
| Guard post | crates of rusted iron in two corners | 2 scuttlers; 2 and a spire; 1 and 2 spires |
| Store room | 2 or 3 keepers' caches in its corners, salvage heaps by them | 1; 2; 2 scuttlers and a spire |
| Machine hall | pillars of dark steel (an alloy relic at the foot of one in four), copper conduits in the floor, a rune stone overhead | a spire; a carapace; a carapace and a spire |
| Collapsed room | heaps of rubble off the corridors' lines | 1; 2; 2 scuttlers and a carapace |
| Vault (locked) | a relic vault, 2 caches, a rune stone; a door of riveted iron | a spire; a spire and a carapace (both deeper) |
| Boss's chamber | a hall 11 by 8 and 6 high, two pillars, lamps and rune stones in the far wall; the reward vault behind a ward, its 2 caches | the custodian |

A delve is built in one paste when a player comes within 96 blocks of its stair head and its
ground is loaded (kept loaded while one is near, as the ruin's is: `keeps_update`); the
world's file remembers which are built, and a world saved before there were delves gets none.
What it posts as it is built is kept with the world (none in a world whose creatures do not
come by themselves: scenes, benchmarks). Its blocks are not the players' to break, but its
caches; what is set down in its air is theirs. Laying a delve out and drawing it takes 0.55 ms
(0.09 ms in a release build), building it (the levelling, the paste and its machines) 22 ms
(7 ms); with no player near, its tick is a few comparisons a delve (47 ns, 10 ns), and with
one in it its traps and fight 0.6 µs (0.1 µs) a tick besides what its machines think.

**What hurts.** The machines sleep at their posts until a player comes near, wake (each the
quicker the smaller) and fight it, and go back whole once it has gone (the creatures' table
above). Some corridors have a trap across their middle: a row of trip plates (a click, and a
quarter second later darts take 3 from whoever is still by it; it is quiet a second and a half
after) or, from the second depth, two rows of charged grating (3 a second while stood on: the block's
`harm`, the engine's harm on touch). A locked door opens to a keeper's key carried (spent; found in the caches of the
second and third depths or made at a fabricator), all of it at once.

**What it gives.** A keepers' cache (`sandbox:delve_cache`, any tier 1 tool) spills what its
depth holds (`server/survival.odin`, `DELVE_LOOT`): the first depth servo bundles, ancient
alloy, charge cells and med gel; the second keeper coils and keys too, and now and then a
trinket; the third more coils, alloy plate, restorers and the rarer trinkets. The machines
leave servo bundles (scuttlers, carapaces) and keeper coils (spires). The keepers' parts make
at a fabricator (`pack/data/recipes/delve.json`): a keeper's key (ancient alloy, a servo
bundle, a circuit board), a keeper helm and cuirass (servo bundles, keeper coils, alloy plate),
the arc lance and the keeper drill (each the custodian's core with coils; the drill an alloy
drill upgraded: tier 3, the fastest tool).

| Item | Rarity | What it is | Where from |
|---|---|---|---|
| servo bundle | uncommon | a part | scuttlers, carapaces, the custodian, caches |
| keeper coil | rare | a part | spires, the custodian, caches of depths 2 and 3 |
| custodian core | epic | a part | the custodian |
| keeper's key | uncommon | opens a locked door, spent | caches of depths 2 and 3, the reward vault; made |
| arc lance | epic | a blade: 18 a blow, reach 4 | made |
| keeper helm | rare | head: 0.11 defence, 4 health | made |
| keeper cuirass | epic | chest: 0.18 defence, 4 health | made |
| keeper drill | epic | tier 3, speed 12, one more of each | made from an alloy drill |
| keeper sigil | rare | trinket: 0.08 defence, 3 health | caches of depths 2 and 3, The Custodian's reward |
| servo spring | rare | trinket: a quarter higher, a little faster | caches of depths 2 and 3, the reward vault |

**The custodian.** It kneels in the middle of its chamber's hall, whole, and takes no harm
while it kneels. A player who can be hurt stepping into the hall wakes it: it rises (two
seconds) and the chamber's doorway is sealed with the ruin's ward. Everyone who can be hurt
inside the hall fights, at any tick (there is no seat to keep), and nobody gets in or out. It
fights in three phases by the share of its health left (`BOSS_PHASES`):

| Phase | From | Its fists | Its slam (shown, reach, harm at its middle) | Casing shut, open | Calls |
|---|---|---|---|---|---|
| 1 | all its health | 6, wound 0.8 s, pace 1.4 | every 9 s, shown 1.5 s, 5 blocks, 7 | half, one and a half | none |
| 2 | two thirds | wound 0.67 s, pace 1.6 | every 8 s, shown 1.3 s, 5.5 blocks, 8 | 0.4, one and a half | 2 scuttlers every 14 s |
| 3 | a third | wound 0.53 s, pace 2 | every 6 s, shown 1 s, 6.5 blocks, 9 | 0.35, double | a scuttler every 18 s |

Before a slam its core blazes and its arms rise (the look `charging`); the slam hurts every
fighter within its reach, half as hard at its edge; after it the custodian stands still with
its casing open, venting (3 seconds, 4 in the third phase), when blows get through it best.
At most four scuttlers it called are out at once. Each fighter is shown the fight
(`sandbox.delve`): a line across the top naming it, its phase, its health and whether its
casing is open, the line's foot a bar of its health in the target frame's colours.

The fight is won when the custodian dies: every fighter in the hall has the win
(`sandbox:delve`, its quest's goal, and the win's experience), the seal and the reward vault's
ward fall, and the vault gives each a keeper's key, a restorer and a servo spring beside what
the custodian leaves (its core, coils, servo bundles, power cells) and the vault's caches. It
is lost when no fighter is left in the hall: one who died stands again where any death in the
sandbox does (what it carried lies in the hall), one who left the server or the hall is out.
Lost, the seal falls and the custodian is set down whole at its post again, what it called gone.
Nothing of a fight outlives the session: as a built delve is first loaded in one, anyone
standing in its hall or vault is set down outside the chamber's door, the seal is down, the
vault shut and the custodian whole at its post, so a server stopped mid-fight leaves nobody
sealed in. Won, the vault stays open the rest of the session and the custodian comes again in
the next. There is no music of its own: the engine's music director picks pieces by the world
and the hour, not by a game's fight.

`/delve` lists the home world's delves and `/delve go <n>|last [landing|deep|hall]` takes you
to the n-th's (or the last set down's) stair head, its first or third depth's landing or into
its custodian's hall (the teleport permission); `/delve here [seed] [still]` sets a delve down
with its stair head at your feet for the session (the bulk edit permission; `still`: its
custodian stands still for a picture).

## Its camps and their people

The home world has three survivors' camps (`server/settlement.odin` places and keeps them,
`server/settlement_build.odin` draws them), a journey from the spawn, all from the world's
seed: on 14 rings round the spawn from 300 blocks out, 40 apart, 24 spots on each starting in
a direction of the seed's, the first spots whose ground is dry and level (the land under the
camp and its apron within 6 blocks of even), at least 24 blocks clear of the ruin's apron, the
remains (but the road) and the generator's structures, and 200 blocks from each other; when
fewer are found the land may be more uneven, then wet. They are numbered nearest first, each
one of four layouts (no two alike in a world), named by the seed ("Ember Hollow", "Salt
Crossing"), and built whole on levelled ground, over what stood there, when a player comes
within 192 blocks and its ground is loaded, but never over an outpost's beacon. Over 40 seeds
every camp stood on dry ground, 108 of 120 on level land and the rest at most 11 blocks uneven
before levelling, none nearer the spawn than 300 blocks and the farthest 820; planning one world's
camps samples the land's columns 6 000 times on average (14 150 at most), once, as the remains
are planned (`server/settlement_seeds_test.odin`); a development build's profile on this box put
that at 37 ms, in one tick as the world opens. A player standing in a camp with its four people
thinking every tick moved the game's part of the server's tick from 0.071 to 0.079 ms on average
over 5 200 ticks (`build trace`, its `game` scope); away from players they think once in eight.

| Layout | What it is |
|---|---|
| Ring camp | a fence round two wool tents and a thatched hut of weathered planks, a fire in the middle, four lamp posts |
| Walled yard | a low cobblestone wall round two plank huts under clay roofs, a fire, two lamp posts |
| Scrap hamlet | a grating fence round two shelters of rusted and riveted iron, a lamp mast of dark steel |
| Longhouse | a fence round a long hall of oak logs and planks under slate, a tent and a fire |

Every camp has a fabricator (which hums, `core.world_hum`) with two chests beside it, a market
stall under a wool awning and gaps in its fence or wall on each side. A player who comes within
40 blocks of a built camp has it in its logbook by its name (`core.logbook_place`, a
`settlement`: the journal lists it, the compass marks it, the map shows it, and a quest's
`find` step may ask for one). No creature that fights comes by itself within 48 blocks of a
camp, as round an outpost's beacon (the spawned hook). The world's `sandbox.settlements.txt`
remembers which are built; a world saved before there were camps gets none.

**Its people** (`server/folk.odin`, `pack/data/entities/folk.json`): four to a camp, each an
entity of its role's kind with a mind of the sandbox's, a name made from the camp's seed by a
small generator of our own (two halves of twenty each: "Penna", "Kesh", "Jory") and a look of
its role's (the trader's hat and pack, the mechanic's goggles and tool belt, the medic's white
and red band, the scout's hood, the elder's staff and white beard, the guard's helmet and
spear), and a threat for the target frame (1; the guard 3). By day each keeps to its spot of the layout, standing and now and then walking a few
blocks round it, watching a player who comes within 5 blocks and facing one it talks with; at
night (a fifth of the day either side of midnight) and in the rain it goes into its shelter (a
hut or a tent), and the guard keeps the gate whatever the hour. A guard fights a creature that
fights which comes into the camp. Nobody can hurt them: any harm to one is none (the harming
hook). A camp sets its people down as it is built and again whenever one is missing while a
player is near; they are kept with the world. Where creatures do not come by themselves (the
image scenes, the benchmarks) they stand still at their spots.

| Camp | Its people |
|---|---|
| the nearest | elder, trader, medic, guard |
| the next | mechanic, trader, scout, guard |
| the third | elder, trader, scout, guard |

**Talking** (`server/talk.odin`, `client/talk.odin`): using a person (the right button) opens a
conversation in the game's screen: a name plate ("Penna, Trader of Copper Fold"), the line it
says and the replies the player is offered, numbered; a click, the number's key or the arrows
and Enter answer, Leave or Escape leaves, and the screen shrinks to fit a small window. What
each says is its role's dialogue, pack data (`pack/data/dialogues/<role>.json`, the engine's
dialogues: [docs/packs.md](../../docs/packs.md#dialogues)): a small graph whose replies are
offered by conditions (a quest under way or on a step, a quest done, what the player carries,
a place it found, being hurt, its level, what it can pay) and do their effects (items given and taken
through the item ledger, silver paid either way from the trader's purse, something said that a
quest counts, the sandbox's own actions). The server is the authority: the client sends the
index of the reply chosen, and the server does it only when the dialogue offers it to that
player now; anything else is refused ("You cannot say that now") and nothing of it is done. A
conversation ends with a reply that goes nowhere, when the player leaves it, walks more than 6
blocks off, dies, or the person is gone.

| Role | Services | Gives |
|---|---|---|
| Trader | opens the camp's market (below) | |
| Mechanic | sells wire (3 silver for 4), a charge cell (6), a circuit board (12); trades a flint pick and 8 silver up for a copper pick (there is no durability to repair) | Parts for the Workshop; ends Medicine Run |
| Medic | heals whole for 3 silver (offered while hurt); sells a field dressing (2) | Hides for the Healer, Medicine Run |
| Scout | sells where the nearest remains site not yet found is (5), the ruin (8), the nearest camp not yet found (4), each marked in the logbook (refused, and not paid, when there is none left) | Quiet the Sentries, Eyes on the Ruin |
| Elder | welcomes the survivor the first hour sends; the camp's story | Keep the Fires; ends Smoke on the Horizon |
| Guard | | Duskrunner Trouble |

A place a scout sells is in the logbook as one found is (a `find` step that asks for it is
done, and it earns what finding it earns: a camp found 80 experience, `pack/data/levels`). The sandbox's actions a dialogue may name (`TALK_ACTIONS`): `market`, `heal`,
`mark_remains`, `mark_ruin`, `mark_settlement` and `mark_mechanic` (the mechanic's camp, for
the errand there).

**Their quests** (`pack/data/quests/folk.json`), all opened by Smoke on the Horizon; each is
taken in a conversation (its first step, a `talk` said by the reply that agrees) and handed in
in another (a reply the dialogue opens on while the quest is on its last step, taking what it
asks), its reward the quest's, and silver from the one who asked:

| Quest | Kind | Given by | Steps | Reward | XP |
|---|---|---|---|---|---|
| Hides for the Healer | fetch | medic | agree; carry 4 hides; hand them in | 2 med gel, 6 silver | 120 |
| Medicine Run | deliver | medic, to the mechanic of the next camp | take 2 med gel; hand them to the mechanic | 3 copper ingots | 180 |
| Parts for the Workshop | fetch | mechanic | agree; carry 3 scrap; hand it in | 2 charge cells, 5 silver | 150 |
| Duskrunner Trouble | hunt | guard | agree; kill 3 duskrunners; report | 2 stim patches, 8 silver | 200 |
| Quiet the Sentries | clear | scout | agree; disable 2 sentries (the ruin's posts are kept); report | 2 optics, 8 silver | 250 |
| Eyes on the Ruin | find | scout | agree; find the ruin; report | climbing spikes, 4 silver | 150 |
| Keep the Fires | fetch | elder | agree; carry 8 coal; hand it in | 3 trail rations, 6 silver | 120 |

**Its market.** Each camp's trader keeps a market of its own: five of the goods, each priced
within a quarter of its base price and 6 to 20 units in stock, from the camp's seed, so the
camps differ. It is the towns' market screen (below, "Its peoples and markets"), opened by the
trader's first reply and by the market's action while the player stays in the camp; a unit
bought or sold moves its price by 3% (between the base price's half and four times it). It
works on any world, Earth or not, and is not saved: a session opens with every camp stocked.

`/settlement` says where the camps are; `/settlement <ring|yard|hamlet|longhouse> [1|2|3]`
sets a camp of that layout down at the player's feet with the people of that camp of the plan
(the bulk edit permission, `world.edit.bulk`), for a picture or a test: it is kept for the
session (after a restart its blocks stay and its people stand still).

What it tells its players: `sandbox.talk` (the conversation a player is in: the person, its
name and camp, the dialogue, the node and the replies offered); what they ask: `sandbox.say`
(the reply chosen, or leave).

## The gate worlds' places

Every world of a class (a gate world: not the home world, not Earth) has a landmark of its
class's own kind and two small sites round the gate travellers arrive at
(`server/beyond.odin` plans and keeps them, `server/beyond_build.odin` draws them), all from
the world's address (the rolls) and its land (where they may stand): the landmark 110 to 260
blocks from the arrival gate, the sites 50 to 300, each on land that suits it (dry and not
too uneven; the ocean's platform in sea 2 to 10 blocks deep), 24 blocks clear of the arrival
gate and its platform, of the generator's structures and of the world's spawn, and 40 of each
other. Each is built whole, in one paste, when a player comes within 192 blocks and its
ground is loaded; a landmark on its ground levelled (the class's rock under, its ground on
top), a site following the land. Then it is the world's like any block. It hums (a landmark
0.8, a site 0.4), and a player within 64 blocks of a landmark (32 of a site) has it in its
logbook, by name, the landmark as a `landmark`, the site as `remains`: the journal, the
compass and the map show it, and a quest's `find` step may ask for one. A world's
`sandbox.places.txt` remembers which are built; a world saved before there were places gets
none.

| Class | Landmark | Site | Machines |
|---|---|---|---|
| Temperate | Standing ring: twelve slate stones (two fallen) 9 blocks round a mossy dais, a relic vault in its plinth under a crystal, a cache at a stone's foot | Mossy cairn: a cairn of cobbles and moss over a cache, a standing stone | a mender over the ring |
| Canyon | Cliff dwelling: three stepped storeys of sandstone, banded with red rock, stairs up its side; a relic vault in the lowest room, a cache in the highest | Dry well: a sandstone kerb round a shaft six deep, a cache at its bottom, posts and a beam | |
| Frozen | Ice-bound hall: a long slate hall under a pitched roof, drifts of packed ice against it and over its roof; a relic vault at its far end, a cache by a wall | Iced cache: a mound of packed ice round a cache, a slate marker | a sentry folded inside the door |
| Ocean | Sunken platform: an iron deck on four legs in the shallows, sloping into the sea at one end, a cabin on its high end with a relic vault and a cache | Beached hull: a rusted hull broken open on an island, a cache in its belly | |
| Volcanic | Basalt vault: polished basalt with obsidian corners round a relic vault and two caches, a dark steel door, a ring of magma crossed by one bridge | Obsidian obelisk: on a basalt pad, a crystal near its top, a cache at its foot | a sentry by the bridge |
| Fungal | Spore tower: a crumbling hollow tower of mossy bricks overgrown by three giant fungi, a relic vault and a cache on its floor | Spore shrine: a mossy dais ringed by glowing caps, a cache on it | |
| Moon | Keepers' relay: a dark steel mast on a concrete pad, a dish of grating, a crystal at its tip, screens and vents; a relic vault in its housing, a cache | Fallen probe: a capsule of dark steel half sunk in the dust, a cache inside | two sentries on the pad; one by the probe |
| Jungle | Canopy station: a planked deck on four redwood stilts 15 up, a thatched hut with a relic vault and a cache, a stair winding up round a post | Overgrown altar: three mossy steps to a rune stone, a cache on top, leaves over it | |

The machines are the remains' own (folded until a player comes near; none in a world whose
creatures do not come by themselves). A cache or a vault broken open on a gate world spills
the remains' draws and the class's own (`server/survival.odin`, `CLASS_LOOT`: a cache one
draw more, a vault two):

| Class | What its caches and vaults may spill beside the remains' own |
|---|---|
| Temperate | amber (2-4), thistle horns, med gel, an amber charm |
| Canyon | opal, sail membranes, stim patches, an opal visor |
| Frozen | cryolite, a frost pelt, a charge cell, frost striders |
| Ocean | nacre shards, med gel, coil charges, nacre greaves |
| Volcanic | sulfur (2-4), ember glands, a charge cell, a data shard |
| Fungal | glow spores (2-4), spore sacs, spore tonics, med gel |
| Moon | ilmenite, a power cell, scrap, a lens, a data shard |
| Jungle | jade, fangs, med gel, a jade talisman |

`/places` says where a gate world's places are, built or not; `/places view landmark|site`
takes you (flying; the teleport permission) over the landmark or the first site, looking at
it, for a picture.

Over 16 worlds of each class (`server/beyond_test.odin`) every one had its landmark but one
frozen world, and all but two ocean worlds both sites. Planning one world asks about 200 (a
moon, a canyon) to 1 800 (an ocean world) columns of its land on average, 6 200 at most, once,
as the world opens: 1 to 3 ms in a development build on a 4-core box. What it costs beside is
finding the arrival gate (`worldgen.arrival_gate`, the search the engine makes when a gate
opens onto the world; kept by the plan for a death's respawn): 1 ms on a moon or a volcanic
world, 55 to 130 ms on average on the others, 620 ms at worst over those worlds, in that one
tick. A place is built in one paste of its box (a landmark's up to 19 x 19 x 40 blocks, a
site's 11 x 11 x 12), as a remains site is.

## Its materials

The sandbox has a block of every material of the kit (`sandbox:basalt_bricks`, ...: its pack's
`data/blocks/kit.json`, one line each; [docs/packs.md](../../docs/packs.md#materials)), so a
builder has them all. `/showroom <stone|wood|metal|built|domestic|natural|fantasy> [x y z]`
(the bulk edit permission, `world.edit.bulk`; `showroom.odin`) sets every material of a
family up to look at, at the player's feet or at x y z: each a wall three blocks square, eight
to a row, the rows one above another, on a floor of concrete slabs with a walkway in front.
The kit's pictures in the world are taken from it:

```sh
./build.sh shot materials --game sandbox -- "wait_world; /time set noon; key f1 down; wait 2; key f1 up; /showroom metal 56 10 40; ticks 20; camera at 72 17 64 0 -10; wait_world; screenshot materials_metal; quit"
```

## Its files

What the sandbox keeps of a world beside the engine's files ([docs/saves.md](../../docs/saves.md)),
staged in the same save transaction when it changed, and checked by `voxiverse-server --check`:

- `sandbox.economy.vxe`: what the server computed of a planet world's markets that the
  history does not give back: `"VXEC"`, `u32 version` (1), `u64` key of the placement it was
  made for, `f64` market month, `u32` market count, `u32` memory count, then per detailed town
  its climate cell (`u32`) and each good's stock and inbound goods (`f32`, in the order of
  `sandbox.Good`), per lazy memory its cell, each good's relative gap to the lazy price (`f32`)
  and the month it was left (`f64`), and last the CRC-32 of everything before it (all
  little-endian). Normal prices, the kernel and the settlements are not stored: they come from
  the history. A file made for another placement (the history changed) is read and ignored, so
  the markets are recomputed; one that is cut, has a bad CRC or a number that is negative or
  not finite is moved aside (`.bad`) and the markets are recomputed. News and caravans in
  flight are not saved.
- `sandbox.interventions.vxi`: the interventions log, in time order: `"VXIV"`, `u32 version`
  (1), `u32 count`, then per intervention its day (`f64`), place (3 x `i32`), kind (`u8`,
  append-only: `Founded_Settlement`, `Built`, `Destroyed`, `Taught`, `Traded`), the actor's
  name (`u8` length, bytes) and 16 data bytes, and last the CRC-32 of everything before it (all
  little-endian). A file that is cut, has a bad CRC, an unknown kind or records out of order is
  refused whole: the world moves it aside and starts with an empty log.

- `sandbox.remains.txt`: the home world's remains built, as text: `before` alone (a world
  saved before there were remains: none is built in it), or a line `built <x> <z>` for each
  site built, naming its middle column. A line it does not know moves the file aside, and
  nothing more is built.
- `sandbox.delves.txt`: the home world's delves built, as text: `before` alone (a world saved
  before there were delves: none is built in it), or a line `built <x> <z>` for each delve
  built, naming its stair head's middle column. A line it does not know moves the file aside,
  and nothing more is built.

A character's trader is the sandbox's record on it, in its file's `game` member: `cash`,
`cargo.<i>` (by the order of `sandbox.Good`), `seen.<i>.cell`, `.price`, `.month` (the month the
price was true) and `.good`, `count` (at most 192 prices, the oldest forgotten first) and
`given` (the starting purse was given), and `ruin_mode.<i>` (the bytes of the mode the
character was in before it fought at the ruin, zero-padded: given back with its things; none
when it fights nothing). Universes from before (save format 8) had these as the
engine's files and the character's `trader`: the save migration made them the sandbox's.

A character's quests are the engine's (its file's `quests`, [docs/saves.md](../../docs/saves.md)).

- `sandbox.outposts.vxo`: the world's outposts, in the order placed: `"VXOP"`, `u32 version`
  (1), `u32 count` (at most 32), then per outpost its beacon's place (3 x `i32`) and its
  placer's name (`u8` length, bytes), and last the CRC-32 of everything before it (all
  little-endian). A file that is cut, longer, has a bad CRC or more outposts than a world
  keeps is moved aside (`.bad`) and the world keeps none (its beacons stand, dark, until
  placed again).

- `sandbox.places.txt`: a gate world's places built, as `sandbox.remains.txt` is: `before`
  alone (a world saved before there were places), or a line `built <x> <z>` for each built,
  naming its middle column; a line it does not know moves the file aside.

- `sandbox.settlements.txt`: the home world's camps built, as text: `before` alone (a world
  saved before there were camps: none is built in it), or a line `built <x> <z>` for each camp
  built, naming its middle column. A line it does not know moves the file aside, and nothing
  more is built. A world without one is new (its file is written at its first save).

A character's respawn at an outpost is its record's `home` (`home.set`, `home.world` (the
world's address), `home.at`): absent in older files, so read as none.

## The code

`rules.odin` (its name and description), `genetics.odin` (the sheep's genes), `pack.odin`
(its pack: `pack/data/entities/sheep.json`, the sheep's body, looks, model and spawn rule;
`wildlife.json`, `predators.json` and `machines.json`, the other creatures', with
`block_tags/creatures.json`, the grounds they come on, and `items/creature_drops.json` and
`models/creature_drops.json`, what they leave;
`pack/data/entities/hostile.json`, the nights' spawn rules; `pack/data/blocks/kit.json`, a
block of every material; `pack/data/quests/first_hour.json`, the first hour's quests;
`pack/data/levels/survivor.json` and `pack/data/skills/survivor.json`, a survivor's levels
and skills; `pack/data/entities/folk.json`, `dialogues/*.json` and `quests/folk.json`, the
camps' people, what they say and the quests they give),
the markets' model (above), `records.odin` (what it replicates), `text.odin`
(what its HUD and screen say) and `worlds.odin` (which creatures live on each world class:
`CLASS_CREATURES`, by kind id; [docs/world.md](../../docs/world.md#world-classes)); `server/` chooses the world (`configure`: the Earth generator
and the starter kit), keeps the sheep (`sheep.odin`: their minds, `think`; their shearing and
feeding, `entity_use`; their wild genes, `spawned`, which also turns away a creature of a
kind its world's class has not; their flight, `entity_hurt`), each sheep's
record (`Creature`) kept on its entity, the other creatures' minds (`wild.odin`) and
the remains' machines (`remains_machines.odin`), and runs the markets (`economy.odin`, each world's
economy, its `world_state` and file; `trader.odin`, the character's `Trader_Record` and the
market on the wire; `interventions.odin`), lets the night's creatures hunt
(`danger.odin`) and keeps the ruined site and its fight (`ruin.odin`: the site from the seed,
its template, the altar's use, the lock, the waves, the reward and the giving back), builds
the remains round the home gate (`remains.odin`, `remains_build.odin`) on what the ruin and they
share (`site.odin`: the land under a site, its levelling, the areas kept loaded), places, lays
out and builds the delves and runs their traps, doors and fights (`delve.odin`,
`delve_plan.odin`, `delve_boss.odin`), places, builds and keeps the camps
(`settlement.odin`, `settlement_build.odin`) with their people (`folk.odin`) and talks with
them (`talk.odin`: the conversations, their actions and the camps' markets); `client/`
draws the market's line and screen (`market.odin`), the fight's bar (`ruin.odin`), the
custodian's (`delve.odin`) and the
conversation's screen (`talk.odin`). The pack's
`pack/data/blocks/ruin.json`, `items/ruin.json`, `models/ruin.json` and
`game_modes/encounter.json` are the ruin's altar and ward, its rounds and the fighters' mode;
`entities/delve.json`, `blocks/delve.json`, `items/delve.json`, `models/delve.json` and
`recipes/delve.json` the delves' machines, blocks, finds and what they make.
Everything else the sandbox does (worlds and gates, climate, farming) is the engine's, chosen
through the server's `Config`.
