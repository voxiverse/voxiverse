# Hamlet

A small village builder for one player or several, together. The map is made from the
world's seed: gently rolling grass, a pond, woods and rocks. You have no body in it: the
camera hangs over the village, and everything you do is from the toolbar.

Lay roads, zone land for homes, and place a well, a farm and a storehouse. People move in
when there are homes with water and food in the stock; each takes a job at a workplace with
a free place, walks the roads between home, work and the storehouse carrying what it made
(wood, stone, food), and rests at home. Houses grow by themselves on zoned land by a road
when homes are wanted and the stock has their wood and stone. Every day each citizen eats;
when the farms cannot keep up, people go hungry, unhappy, and leave.

| Control | What it does |
|---|---|
| <kbd>W</kbd> <kbd>A</kbd> <kbd>S</kbd> <kbd>D</kbd>, the window's edges, the middle button dragged | Pan (Ctrl, held: faster) |
| The wheel | Zoom |
| <kbd>F5</kbd>; Shift and the wheel | Turn the camera a quarter; a little |
| Left button | Use the tool: drag a road (an L: across, then along) or a zone, place a building, demolish |
| Right button | Turn the building in hand; with the zone tool, drag to unzone |
| <kbd>F3</kbd> | The seed, the tool, what the pointer is on |

## The buildings

| Building | Cost (wood, stone) | Jobs | What it does |
|---|---|---|---|
| House | 4, 2 | | Grows by itself on zoned land; 5 people, if a well is within 14 tiles |
| Woodcutter | 6, 0 | 3 | A shift brings 2 wood to the storehouse; needs trees within 10 tiles |
| Quarry | 8, 0 | 3 | 2 stone a shift; needs rocks within 10 tiles |
| Farm | 6, 0 | 4 | 3 food a shift |
| Storehouse | 10, 6 | 2 | Where the goods go: without one, a shift's work is lost |
| Well | 2, 6 | | Water for the houses within 14 tiles |
| Market | 12, 8 | 2 | The people of the houses within 16 tiles are happier |

Every building must touch a road, on ground no steeper than a block. Demolishing gives half
its cost back (only the host, or a player with `hamlet.demolish`, may). Roads are free and
cannot cross water, trees or rocks. The stock starts at 60 wood, 30 stone and 40 food.

A citizen's happiness: 40, then +25 fed or -35 hungry, +10 with a job, +20 with a market
near home, -25 without water. One hungry two days running, or below 20, leaves. Nobody
moves in while the village is below 40 or there is no food. The milestones are 25, 50, 100
and 200 people.

The toolbar's speeds (Pause, 1x, 2x, 4x) step the village's life (its citizens, the days,
the houses growing) that many times a tick; only the host, or a player with
`hamlet.speed`, may change it. The camera pans at its own pace whatever the speed. The
overlay button shows the roads' reach (green: within 2 tiles of a road) or each house's
happiness (red to green; grey: empty).

## Playing it

```sh
./build.sh run -- --game hamlet
./build.sh run -- --game hamlet --exec "singleplayer; wait_world; /open_lan"
./build.sh serve -- --game hamlet --universe build/hamlet-universe
```

Server command: `/hamlet` (the village's day, people and stock), and for the host
`/hamlet stock <wood> <stone> <food>`, `/hamlet speed <0..4>` and `/hamlet plan` (a village laid out by the same rules: streets, zones, wells, farms, a storehouse, a market, a woodcutter and a quarry where they fit). The whole village (its tiles, structures, citizens,
stock, day and speed) is kept with the universe (`game.cfg`) and comes back after a
restart; the citizens stand at their homes' doors again.

## The code

`rules.odin` (the map's tiles and ground from the seed, the buildings' table and shapes as
text, the placement rules both sides judge by), `records.odin` (the town, the map's rows,
the structures, the milestone, and the requests), `pack.odin` (the planner's mode, the
citizen); `server/` builds the land and the structures (`town.odin`), runs the citizens
(`citizens.odin`) and judges the requests and keeps the village (`game.odin`); `client/`
draws the toolbar, the town's line, the tools' marks and the overlays.

What the engine gives it: players with no body (`game.Ability.Bodiless`, the planner mode)
and the free camera (`engine.Game_Camera` kind `.Free`); the pointer's tools
(`engine.pointer_tool`, `engine.ground_fill`, `engine.ground_outline`,
`engine.structure_ghost`); a UI over the world that takes its own clicks (`ui.panel`,
`ui.pointer_over`); typed requests from the client part (`Game_Kinds.requests`,
`engine.game_request`, the `request` hook, `core.request_value`); structures as one bulk
edit each (`game.template_build`, `core.structure_fit`, `core.structure_place`,
`core.structure_remove`); cheap walkers (`core.entity_glide`); and the simulation's speed
(`core.sim_speed_set`, `Server.sim_steps`).
