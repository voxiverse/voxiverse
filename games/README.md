# Games

One folder per game, `games/<game>/`, named by the game's id. What a game is and the hooks
the engine calls: [docs/games.md](../docs/games.md). The shape of a game's folder and what may
import a game: [docs/layout.md](../docs/layout.md), rule 6. Adding a game edits nothing
outside its folder, and so does shelving one: a file `games/<game>/SHELVED` keeps it out of
the programs and the test runs while `check` still type-checks it ([docs/games.md](../docs/games.md#shelving-a-game)).
