# Voxiverse design decisions

The owner's product and UI decisions, from the design interview of 2026-10-28 (#45), grouped.
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
- Day length: per world, from its address (its astronomy), defaulting near 20 minutes.

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
- How players meet the agent that authors their universe.
- Emotes, onboarding and tutorials (later, as data).
