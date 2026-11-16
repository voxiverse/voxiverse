# @Name@

Every block a player breaks scores a point; the line across the top of the screen says how
many. Stamped out by `./build.sh new-game @id@`: a game's whole shape
([docs/games.md](../../docs/games.md)) with one rule, to grow into a game of its own.

## Playing it

`./build.sh run -- --game @id@` starts a scratch world playing it.

## Its rules

A block broken by a player (one block, air after it) is a point for that player; a block
placed, or one the world or a command changed, is none. Points are the seat's: they start
at zero when a player joins and are not kept.

## Its records

`@id@.points` (each player its own): the player's points.
