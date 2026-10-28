# Voxiverse design decisions

The owner's product and UI decisions, from the design interviews of 2026-10-28 (#45, then the second batch, #51), grouped.
The second batch's sections (*Worlds of a universe* to *Economy and culture*, *Creatures in play*) are
**launching points for the Living worlds arc** (plan.md), not schedule: nothing in them is built before the
foundation arc is done.
Planning and milestone sessions read this file and cite it in specs ("design.md, *Camera and
movement*"). It changes only with the owner's word: a session that disagrees asks the owner
and does not edit it. What is decided is marked as such; what is not is under **The owner
decides**, at the end, and is a hard stop (see plan.md, *Undecided gameplay is a hard stop*).

The [glossary](#glossary) fixes the names; code, docs and UI use them.

## Glossary

| Name | Is |
|---|---|
| Title screen | The first screen: Singleplayer, Multiplayer, Options, Quit Game; the splash text, the version lower left, the warp starfield behind |
| Universes screen | Singleplayer's screen: the universes as cards, the last-played first (today's Worlds screen; plan.md's nomenclature renames it) |
| Universe creation | The screen that makes a universe: name, seed (gate glyphs), game mode, the home-world preview, Ignite |
| Multiplayer screen | Saved servers, LAN and direct connection (later: online servers) |
| Options | The settings screen, from the title screen and from the game menu (never "Settings" in the UI; `Settings` stays the code's name for the stored values) |
| Game menu | What Esc opens in a world: Back to Game, Options, Open to LAN, Leave. Not "pause menu": it pauses only in singleplayer, never on LAN or a server |
| Player menu | One menu with sections (Map, Journal, Inventory, Character, Atlas, Statistics); Tab reopens the last section; each section has its own key |
| Section | One page of the player menu |
| Container view | A chest's slots docked above your pockets in the Inventory section (not a tab) |
| HUD | Hotbar, crosshair, health, prompt bar, item-name popup. F1 hides it all |
| Overlay | A layer over the world that takes input: chat, console, quit dialog, gate dial, toasts |
| Toast | A small stacked notice, top right, that slides in and fades |
| Dev panels | Panels for developers (tuning F4, audio inspector F8, the F3 debug screen's extras); never in the player's way, never translated |

## Names
- Game menu (not "pause menu": it doesn't pause on LAN or a server).
- Player menu: one menu with sections; Tab reopens the last section; each section has its own key.
- Container view: a chest's slots docked in the Inventory section (not a tab). Creative's catalog docks in Inventory too.
- HUD: hotbar, crosshair, health, prompt bar, item-name popup. F1 hides it all.

## Title screen
- Splash text from `splashes.txt` (one entry per line); several entries, one chosen by the clock when the game starts ("The Universe, voxelized." is the title's own line)
- Buttons: Singleplayer, Multiplayer, Options, Quit Game; the splash text; the version lower left; the warp starfield behind.
- No "Continue" shortcut: the Universes screen lists the last-played universe first.

## Universes
- Singleplayer leads to the Universes screen; entering a universe puts you in the world you last stood in.
- Creating a universe must feel like crafting one (galaxy from the seed, Roll, the home world shown, Ignite).
- Universe cards: a galaxy thumbnail drawn from the seed, plus the name.
- A universe's seed is shown as gate glyphs: the seed is the home world's gate address. Typing a number or text still works and turns into glyphs.
- At creation the player chooses a name, a seed and the game mode, nothing else.
- Home-world preview: a small rotating planet in the world's palette, its address glyphs, and three facts (climate, sky, terrain).
- Ignite: a 2–3 s big bang (the galaxy collapses to a point, flashes, zooms into the home world) while it loads; skippable.
- Game mode can change later by command (/gamemode) with permission; the save records that it was changed.
- Delete: one confirm dialog for now (development). Later: type the universe's name to confirm, and move it to a trash folder first.
- Universe export and import: in each universe card's menu on the Universes screen.
- World names: every world has a generated name; each player can rename worlds for themselves in the Atlas.

## Modes, death, gates
- Game modes: Creative and Survival only (no Spectator or Adventure planned).
- Death and respawn/home: gameplay, decided later (see The owner decides). The death screen stays a placeholder.
- Gate travel: a short warp-tunnel transition (the title's warp starfield, 1–2 s) while the new world loads; its address glyphs and name fade in on arrival.
- Dialing: keep the dial overlay (symbol by symbol, M18) for now; other ways need more thought (owner decides later).
- Gates stay rare and far from a world's middle; /locate gate for operators.
- Waypoints: map markers only, nothing physical.

## The player menu
- Sections, in order, with keys: Map (M), Journal (J), Inventory (E), Character (C), Atlas (L), Statistics (K). Built now: Inventory, Statistics.
- A section's key toggles it; Tab reopens the last section; Esc closes. The player menu has no Q/E stepping (Options keeps Q/E tab stepping). The gamepad's View opens it, LB and RB switch sections.
- The player menu doesn't pause; only the game menu pauses (in singleplayer).
- Behind in-world menus: the world, dimmed.
- Character: gameplay undecided. No attributes, levels or skills are planned; build none until the owner designs them. (Equipment modifiers exist: speed, jump, air jumps, max health.) The section stays hidden.
- Journal: hidden until M53 brings quests.

### Inventory section
- It contains: the character preview (rotatable, shows armour), an item details panel (the hovered item's name, description, modifiers, tags), a Sort button and a search box for your own items.
- Pockets stay 5x5.
- Tooltips: name and a short description from the item's data (packs give the text), with its modifiers listed ("Speed +10%").
- Container view: the chest above your pockets; the character preview hides while a container is open.
- Creative's catalog docks in Inventory.
- A new character starts with only the rocket launcher, in hotbar slot 1.

### Statistics
- Kept as it is (grouped counters with search), restyled in the new menu look.

### Map, Atlas, Journal
- Map: a top-down render of explored terrain (block colours from above), revealed as you explore, with pan, zoom and markers you place.
- No minimap on the HUD, ever. No coordinates or compass on the HUD: the Map section answers "where am I".
- Atlas: worlds visited (glyph address, kind, last visit), gate addresses found but not visited, and a galaxy view placing your worlds as stars in the universe's galaxy. No dialing from the Atlas.
- Journal: hidden until M53 brings quests.

## HUD
- The hotbar keeps 5 slots.
- The item name appears above the hotbar when you change slots, then fades out.
- Health's look: decided with survival (hearts until then).
- Crosshair: keep the plus; Accessibility has size, colour and shape options; hidden in third person unless aiming.
- No clock: the sky tells the time (F3 shows it).
- Name tags over other players: shown; sneaking hides your tag behind walls.

## Hotkeys and input
- E Inventory, M Map, J Journal, C Character, L Atlas, K Statistics, F1 hide HUD, F2 screenshot, F3 debug screen, F5 camera.
- F: swap the held item with the offhand. Hold P: the player list (names, pings) while held.
- Sprint and sneak: hold by default; Accessibility can switch either to toggle.
- Flying: double-tap Space as now (Space up, Shift down, sprint faster).
- Gamepad: View opens the player menu, Menu opens the game menu; LB and RB switch player-menu sections.
- Every key and button is remappable.
- UI scale: the Options slider only, no hotkey.

## Camera and movement
- F5 cycles: first person → third person behind → third person facing you.
- Third person: centred behind the head; the camera pulls in instead of clipping into blocks.
- FOV: a slider in Options; sprinting widens it slightly; a toggle turns the widening off (comfort).
- First person shows the held item and arm (viewmodel), with swing and place animations; F1 hides it.
- View bobbing: on, subtle, with an Options toggle; Reduce motion turns it off.
- Avatar animation (walk, run, sneak, swim, fly), procedural, soon: needed once F5's third person exists.
- F3: the debug screen for everyone (coordinates, chunk, biome, FPS); a server can hide coordinates from its players.

## Building
- Creative building tools (selection UI, copy and paste, undo): later.
- Placement: a translucent ghost preview of the block at the target, showing its orientation (stairs, slabs).
- Pick block (middle click) copies the exact state (a north-facing top stair stays that).
- Region protection: a refused edit briefly shows the region's outline and a "Protected by X" toast.

## Look and sound of the UI
- UI style: clean retro-futurist panels over the crunchy-pixel world, with thin lines, glyphs and cool accent colours.
- Fonts: keep the current font, plus the glyph set for addresses.
- UI sounds: soft synth clicks and whooshes (made with M57's synth), with their own volume slider.
- Menu music: the title piece on the title and universes screens, continuing into the creation screen; Ignite cues a stinger.

## Loading, notices, screenshots
- Loading screen (entering a world, gate travel): the warp starfield, the world's name and glyphs, and a tip (tips from a data file, like splashes.txt).
- Notifications: one toast system, top right (small stacked notices that slide in and fade): screenshots, joins, achievements later.
- Screenshots (F2): a brief "Screenshot saved" notice (a toast); clicking it opens the folder.
- Chat stays as it is (T opens it, lines fade, / starts a command).

## Online and servers
- Multiplayer screen, later: saved servers (with ping, player count, the server's icon and line) plus LAN and direct connection. Comes with online servers (auth remotes).
- Options › Profile: your name, a skin preview, and sign-in (to a remote, or offline).
- Skins: managed on voxiverse.net; the game shows and uses them, with a preview in Options › Profile.
- Operators: commands now; an admin panel later (the next tier's server operations and moderation tools).
- Open to LAN: the dialog sets guests' game mode and whether commands are allowed.

## Agents, accessibility, language
- Agent-made content is labelled: packs and quests show their author (agent or person).
- Achievements: later, as data with the declarative layer (M53), so packs and agents can author them.
- Accessibility commitments now: every key and button remappable; Reduce motion tames everything (Ignite, warp, FOV kick, view bob…).
- Language: English now, but every UI string goes through a key from now on, so localization (UI v2) is cheap later.

## World feel
- Weather: in the next tier, as planned (with atmosphere and lighting).
- Day length: per world, from its address (its astronomy), defaulting near 20 minutes; the home world's is the default. Gravity, atmosphere and the star also differ per world: see *Worlds of a universe* and *Physics of worlds*.

## Principle: low-fidelity science
- Use low-fidelity scientific classifications and algorithms wherever possible (planet classes, stellar types, climate from the star and atmosphere, ecology as population dynamics, body plans adapted to physics, genetics), always simplified, and always behind "it must stay fun". Simulate the gist, never the detail; when realism and fun conflict, fun wins.

## Worlds of a universe
- World kinds follow actual scientific classifications of planets: most worlds are alien and few are Earth-like. A player who wants an Earth-like world stays on the home world.
- Worlds differ in gravity, day length and atmosphere (thin, none, toxic; the gameplay consequences are the owner's, see *The owner decides*).
- Worlds are infinite and flat (as today), not finite wrapping planets.
- The home world is always gentle and Earth-like: the seed picks among friendly kinds.
- Classification, by mass and composition: rocky (sub-Earth, Earth-like, super-Earth), ocean, ice, desert and hot rocky, lava, and moons. Gas giants appear in the sky only; you visit their moons.
- Stars matter: the star's colour tints daylight (red dwarfs warm and orange, blue stars cold); binary systems have two suns; the star's size sets the heat (climate, with atmosphere).
- Each sky shows the other bodies of the world's system (moons, planets, gas giants) at their positions: the "sky from astronomy" tier item.
- Names: a catalogue designation from the address (e.g. "VX-4471 c") plus a pronounceable generated common name; players can rename worlds for themselves (*Universes*).
- The galaxy: each universe's galaxy is a spiral (arm count, twist and colours from the seed); worlds sit on its stars. An address's glyphs encode its position: nearby addresses are nearby stars, and the Atlas's galaxy view shows real positions.
- The number of worlds is effectively unbounded (the address space is astronomically large); only visited worlds cost disk.

## Physics of worlds
Experimental: "try all of it; may streamline later". Built so it can be simplified.
- Gravity changes jump height and fall speed (physics shared by the server and prediction), fall damage when health is on, projectiles and dropped items, and creatures' movement.
- No atmosphere: a black sky with stars by day, muffled or silent sound, no weather and no fog. Breathing needs gear: a gameplay hook only, the rule is the owner's. Try it and keep what works.
- On arrival in a new world: a card with its name, kind and three facts (gravity, day length, atmosphere), fading after a few seconds.
- A visited world's physical facts are in its Atlas entry.

## Blocks of alien worlds
- Each world kind has a block set in the base pack (rocks, soils, ices, crystals...). Each such block has 8 colour variants as block states (palette-quantized), and worldgen chooses which variants each world uses. The registry stays fixed, a carried block keeps its look, and every world looks distinct. The star's tint colours the light, not the blocks.
- The world-kind block sets are authored by agents as packs, with textures programmatic from recipes, and reviewed by the owner.
- Blocks don't carry their origin world until the economy exists. Everything travels between worlds freely (content is per universe).

## Flora
- A world's plants are procedural: assembled from a grammar of parts (stems, leaves, flowers, colours) per world kind and climate. The base pack defines the grammar; worldgen rolls each world's species.
- Growth, spreading and dying are neighbour rules as data (M49b), driven by light, water, temperature and atmosphere: one engine for every world.
- Trees are built from blocks and grown from rules (L-system-like growth into blocks), so they can be harvested.
- Ecosystems: populations are simulated coarsely, as per-region densities of each species that grow or decline with food and predators; spawning reads them.

## Fauna
Supersedes "creatures: the owner decides" for the systems. Which specific creatures exist is still content, and the owner decides it later (creatures on alien worlds too).
- Creatures are procedural: body plans from parts (legs, segments, wings, fins), sizes and colours per world kind, with procedural animation (like the avatar's cycles); each world's species are rolled by worldgen. Sizes run from insect-like to elephant-like, within block-scale limits; huge, multi-entity bodies later.
- Behaviour is data: utility AI or behaviour trees (needs such as eat, flee, rest, herd, and the actions that meet them) as pack data, on the navigation and AI framework (next tier). Scripts only for special creatures.
- Bodies adapt to their world, by rules in the grammar: low gravity gives tall or gliding bodies, oceans give swimmers, no air gives none or alien forms.
- Genetics in general: M25's inherited traits extended to every species; heritable traits (colour, size, pattern) come from the species' grammar.

## Creatures in play
- Spawning combines both models. The population simulation decides what lives in a region and how many; Minecraft-style local rules (light, biome, the block underneath, space to fit) decide where an individual appears near players. A spawn uses up the region's density and despawning returns it; named and tamed individuals persist.
- The AI framework supports aggression; whether creatures are hostile and how combat works is the owner's (*The owner decides*).
- The Atlas has a species codex: the species you have seen on each world, with a generated scientific-style name and their traits. No gameplay rewards are decided.

## NPCs
- NPCs are persistent entities with identity (name, home, job), needs, memory, relationships and a daily schedule. Behaviour is data, as for fauna. Dialogue comes from the declarative layer (M53). The universe's agent can author or drive important NPCs.
- Each NPC remembers what players did to them, alongside faction reputation; both feed dialogue and prices.
- Dialogue is authored trees in packs, written by the agent (for example between visits), and deterministic in play: no live model conversation. No voice acting: dialogue and quests are text.
- NPCs live only where civilizations exist; most worlds are wild.
- Schedules (sleep, work, gather) follow the world's day length and are caught up on arrival.

## Civilizations
- Rolled from a world's habitability: a low-fidelity Drake-style chance from world kind, star, atmosphere and age, so inhabited worlds are rare and meaningful.
- Development is a low-fidelity scale (Kardashev-ish tiers: tribal, agrarian, industrial, spacefaring). The tier sets a civilization's buildings, its items, and whether it knows gates.
- Settlements are procedural from culture, tech tier and terrain: a settlement grammar (layout, buildings from structure templates (M12), materials from the world's blocks).
- Civilizations change through a coarse simulation, run when a world is visited and caught up (population, resources, relations evolve in steps); players' actions change them.
- Each civilization has a generated naming language (low-fidelity phonology for names of people, places and items) and a few culture traits (values, architecture style, colours) that shape its settlements and dialogue tone.

## Factions
- Groups with goals, territory and relations (ally, neutral, hostile as numbers), within and across civilizations. NPCs belong to them, and each player has a reputation with each faction.
- Spacefaring, gate-knowing factions span several worlds; the others are local to one.
- Players can join NPC factions, which affects their reputation. Player-made groups (guilds, parties) are a separate social system, later.
- Conflict between factions is simulated coarsely in the catch-up simulation (wars, trade) and shows up as events: territory changes, refugees, quests. The combat rules themselves are gameplay, the owner's.

## Economy
- A low-fidelity supply-and-demand simulation per settlement: each produces and consumes goods by its tech tier, biome and population; prices move with stock; trade between settlements and worlds evens them out. Deterministic.
- Currency: the owner decides later.

## The core game and agents
- The core game is classic and complete without any agent. Its systems (ecology, civilizations, factions, the economy) are deterministic rule simulations in the state tier (bit-identical, journalled): simple rules producing emergent, computationally irreducible complexity. Nobody, agent included, reaches in to change their numbers.
- A future platform, like Fortnite's custom experiences, will let people spin up their own custom games. That is a later feature idea, not designed now. The core game dogfoods it: it is built from the same packs, data and scripts a custom experience would use.
- Agents are optional, sandboxed content authors (packs, quests, NPC dialogue). The engine must make it safe for them to write content without breaking the game. They are not a live director over the simulations.
- Only visited worlds simulate; a world is caught up when visited (unvisited worlds are generated fresh from rules and elapsed time). A world nobody is in freezes and catches up on return (crops grow by the elapsed time).
- "Classic, non-procedural" applies to the agent's role only: flora, fauna and settlements stay procedural from grammars.

## Performance and graphics
- Target: 60 fps at 12 chunks' render distance on a "mid" reference PC, described in the docs in relative terms (no one's hardware named); benchmarks guard it.
- Options gets graphics presets (Low, Medium, High, Custom); changing any single option makes it Custom.
- Vsync on by default, plus an fps cap option; unlimited allowed; menus capped low to save power.
- Lower fps when the window is unfocused or minimized; nothing else automatic.

## Packs in the UI
- Each universe card's menu has a Packs list: the universe's packs, versions and authors (labelled agent or person), enabled or disabled for singleplayer.
- Joining a server that sends packs shows a progress bar with the packs' names and sizes in the loading screen; cached packs skip it.
- Later: client-only assets packs, so a player can layer their own textures and sounds over any universe (visuals and sounds only).
- Authoring in the game: hot reload (M47i) plus a pack-errors panel showing file:line.

## Sound of worlds
- Music is chosen by world kind (ice, lava, ocean... each has its own moods); the director (M44) picks by world and biome.
- Atmosphere shapes sound: thin air muffles it and no air silences it. Each world kind also has its own ambience bed: alien fauna and wind (M58b).
- No voice acting.
- Gate travel sounds: a rising warp whoosh, then an arrival stinger (the discovery stinger on a first visit).

## Multiplayer across worlds
- Players spread across many worlds at once: each world runs where people are (one server process per universe, worlds on their own threads), and empty worlds sleep.
- Target: about 100 players per universe, spread over worlds, benchmarked. Beyond that is a later scaling problem (plan.md, *Scale*).
- Servers can limit gate travel with gate rules: allow all, an allow list, or visited-only, enforced when dialing.

## Identity and releases
- In one sentence: "Explore a voxel universe of countless worlds."
- The README and any store page's lead feature: deferred until the end; not updated now.
- Named Alpha builds every Friday: the loop tags the next minor version (vX.Y.0, "Alpha N") on the last green main commit, never a red one, which makes the draft release; the owner reviews and publishes it. Opus drafts player-facing release notes from the week's milestones (like Alpha 1's), plus a short hand-check list from that week's #1 checks for the owner to try before publishing.

## Deferred
- Item icons for non-cube blocks (stairs, slabs, doors, fences) render wrong: noted, deferred (non-essential).
- Emotes: later, with the content waves.
- Onboarding and tutorials: later, as data, once gameplay exists.

## The owner decides

Hard stop: never build, infer or prototype these. A session that needs one asks the owner
(or, unattended, builds around it and says so); it does not pick.

- Survival: its rules, numbers and gathering; health's look on the HUD.
- Death and respawn: what you keep, where "home" is.
- Character: attributes, levels, skills, perks (the Character section stays hidden). Equipment modifiers are not character attributes.
- How gate addresses get "found" for the Atlas; other ways to dial.
- How players meet the agent that authors their universe; when and how players hear about agents at all (unknown until the agent is integrated).
- Currency (the economy's money).
- Hostility and combat: whether creatures are hostile, when, and the combat rules (the AI framework supports aggression; using it is a design call). Faction conflict's combat rules too.
- Which specific creatures exist, on the home world and on alien worlds.
- What breathing gear is, and any rule for a world without air (the hook exists; the rule is not decided).
- The README and the store page (deferred to the end).
- Emotes, onboarding and tutorials (later, as data).
