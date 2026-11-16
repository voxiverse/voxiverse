# Foundry

A factory built together. One or more builders arrive on a seeded square of flat ground with
three ores in patches (ember ore, tide ore and peat), cobblestone rocks, trees and a pond, and
nothing but a few planks. They mine by hand, craft their first machines by hand, then let the
machines do it: miners on the ore, conveyors, arms between the belts and the furnaces and
assemblers, generators and poles to power them, labs to learn what comes next. The goal is a
**lodestar**, at the end of a chain four steps deep (ore, bars, parts, rotors and circuits and
lenses, the lodestar); the clock stops when it is made, and the factory keeps running.

```sh
./build.sh run -- --game foundry
```

## How it plays

- **By hand.** Break ore, cobblestone and logs to carry them (the builder's mode takes no
  harm). The game's first action (`Craft`, Z by default, rebindable under Foundry in the
  controls) opens the hand-crafting list: every hand recipe with what it needs, those not yet
  researched greyed with the research that unlocks them. Hand recipes make the machines and,
  slowly, the first parts.
- **Placing.** A machine in hand shows where it would go, outlined, and the way it would face
  (the way you look). Its second action (`Turn`, X) turns the machine or belt you aim at a
  quarter turn clockwise. Breaking one gives it back, spilling what it held.
- **Machines.** Each thinks three times a second at the speed its power allows. A label over
  the one you aim at says what it is making, how far, and why it stands (no input, output
  full, no power, no ore). Using one (right button) opens its panel: what it holds, its
  output taken, what you carry that it takes put in, an assembler's recipe or a lab's
  research chosen.
  - **Miner**: on an ore patch, digs an ore every 2 s into what it faces (a belt, a machine) or
    holds it.
  - **Furnace**: smelts what it is given by its recipe (ores to bars, sand to lenses).
  - **Assembler**: makes the recipe chosen in its panel from its inputs.
  - **Crate**: twelve slots; arms take from it and put into it.
  - **Arm**: takes an item from what is behind it (a belt's front, a machine's output, any of
    a crate's) and gives it to what is ahead, if that takes it.
  - **Belt**: the engine's conveyor (four items a block, 1.5 blocks a second, round corners,
    waiting when blocked); its items are drawn riding it.
  - **Splitter**: takes from the belt behind it and gives in turn to the belts on its sides.
  - **Generator**: burns peat (12 s each at full load) for 900 kW on its part of the grid.
  - **Pole**: joins machines and poles within 5 blocks into one part of the power grid.
  - **Lab**: studies the research under way, a unit every 3 s for an insight (and a theory
    for the last two).
- **Power.** Each part of the grid balances once a second: its burning generators' supply
  against what its machines ask (a miner or a furnace 90 kW, an assembler 150, a lab 60, an
  arm 15). A part short of power runs its machines slower in proportion; one without any stops
  them. The line across the top says the whole factory's supply and demand, and warns when it
  is short.
- **Research** (about eight unlocks, in a tree): Assembly (the assembler), Circuits, Frames,
  Splitting (the splitter), Optics (lenses), Theory, Rotors and Lodestar.
- **Away.** A factory works wherever its builders are: the chunks holding machines and belts
  stay loaded with nobody near (the engine's working chunks, up to 512 a world) and load again
  as the world opens.

The recipes, items and machines are the pack's data (`pack/data`); what each recipe takes
and how long is there.

## Its commands

`/foundry demo` builds a working line by the spawn (a miner, a belt, an arm, a furnace, a
crate; a crate of bars feeding an assembler making gears; a lab; a generator and a pole);
`/foundry give <item>` gives fifty of an item; `/foundry research <n>` marks the first n
researches done; `/foundry set goal <1..20>` sets how many lodestars the goal is (the
`foundry.admin` permission, which the host holds).

## What it keeps

With the universe (`game.cfg`): the settings, whether the map is built, the factory's clock,
the lodestars made, the research done and under way, and each builder's counts by name. The
factory itself is the world's: its blocks, and the machines' records, slots and belts' items
saved with their chunks. Statistics: `foundry.crafted` and `foundry.placed`.

## Its records

`foundry.status` (everyone: the goal, the clock, the research, the power), `foundry.panel`
(the player with a panel open), `foundry.builder` (each player's counts), the events
`foundry.panel_open` and `foundry.goal_reached`, and the requests `foundry.choose`,
`foundry.take`, `foundry.put`, `foundry.craft`, `foundry.turn` and `foundry.close`. What a
machine shows (`foundry.Shown`) is the engine's machine record.
