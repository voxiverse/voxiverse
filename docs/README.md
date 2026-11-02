# Docs

Cheat sheets for the people and agents working on Voxiverse: each says how a system works
**now**, in a few minutes' reading. When a change makes one wrong, the same commit fixes it.
Plans and history don't live here: git is the history.

| Doc | What it covers |
|---|---|
| [design.md](design.md) | The decisions, the ground rules every change follows, the core designs (main loop, world data, netcode, renderer, UI, input, console, tooling, saves), the audio engine, scripting, packs and the threat model |
| [glossary.md](glossary.md) | The project's terms, each with the code that implements it |
| [layout.md](layout.md) | Where every file goes: every folder and its file-name patterns (`check` enforces it) |
| [platforms.md](platforms.md) | What runs where, and what each platform requires |
| [debugging.md](debugging.md) | What debug builds detect, the switches, the profilers, how to read a crash |
| [determinism.md](determinism.md) | What is bit-identical across machines and the rules that keep it so |
| [journal.md](journal.md) | The edit journal: every block change with its cause; the one way blocks change |
| [saves.md](saves.md) | How a universe is stored on disk |
| [script.md](script.md) | The script language and its VM |
| [fuzzing.md](fuzzing.md) | The fuzz harness and its targets |
| [telemetry.md](telemetry.md) | What telemetry is collected, where it goes, how to examine it |
