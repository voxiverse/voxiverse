# Docs

Cheat sheets for the people and agents working on Voxiverse: each says how a system works
**now**, in a few minutes' reading. When a change makes one wrong, the same commit fixes it.
Plans and history don't live here: git is the history.

| Doc | What it covers |
|---|---|
| [design.md](design.md) | The ground rules every change follows and the core designs: main loop, world data, netcode, renderer, UI, input, console and variables, tooling |
| [audio.md](audio.md) | The audio engine (buses, voices, effects, spatial, streams), the music pipeline, and the capture, inspector and baseline tools |
| [packs.md](packs.md) | Pack layout, the rule language, how packs travel to clients, pack asset limits, and what the engine treats as untrusted |
| [glossary.md](glossary.md) | The project's terms, each with the code that implements it |
| [layout.md](layout.md) | Where every file goes: every folder and its file-name patterns (`check` enforces it) |
| [platforms.md](platforms.md) | What runs where, and what each platform requires |
| [debugging.md](debugging.md) | What debug builds detect, the switches, the log, the console and checks, debuggers, GPU captures, visual baselines, CI |
| [graphics.md](graphics.md) | The renderer's passes, GPU timings, draw counts, culling and chunk light |
| [benchmarking.md](benchmarking.md) | Benchmark scenarios, comparing versions, profiling and Spall traces |
| [network.md](network.md) | Network debugging tools, the state model and bandwidth baselines |
| [server.md](server.md) | Server commands, permissions, accounts, chat and statistics |
| [world.md](world.md) | Worlds and gates, items, liquids, structures and world generation |
| [determinism.md](determinism.md) | What is bit-identical across machines and the rules that keep it so |
| [journal.md](journal.md) | The edit journal: every block change with its cause; the one way blocks change |
| [saves.md](saves.md) | How a universe is stored on disk |
| [script.md](script.md) | The script language and its VM |
| [fuzzing.md](fuzzing.md) | The fuzz harness and its targets |
| [telemetry.md](telemetry.md) | What telemetry is collected, where it goes, how to examine it |
