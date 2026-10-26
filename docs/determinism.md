# Determinism: what is bit-identical, and the rules that keep it so

The simulation is a function of what reaches it at each tick boundary. Everything
later stands on that: the journal replays onto a snapshot, a rollback lands on an
exact hash, a script's state is snapshotted and restored, and a client on one OS
predicts what a server on another decides. Read this before touching shared code
(`game/`, `server/`, `worldgen/`). `build check` enforces rules 2 and 3.

## Three tiers

| Tier | What | Promise |
|---|---|---|
| **State** | server simulation, prediction, worldgen, light, rules, RNG | bit-identical on every OS and optimization level |
| **Replayable** | the audio mixer and its capture, client visuals | bit-identical on one OS and optimization level (the audio baselines keep a checksum per OS) |
| **Free** | rendering, UI, timing | none |

A live server is not lockstep: inputs and chunk jobs arrive when they arrive. The
reproducible form is the **stepped server** (`Config.stepped`: no thread, chunk
jobs run inline, inputs handed over per tick), used by tests and the cross-OS job
now, and by replay later. No map iteration order and no thread completion order
may reach state or the wire.

## The rules

1. **Floats** in state are IEEE `f32`/`f64` with default rounding. No
   `math.fmuladd`, no fast-math. Odin does not contract `a*b + c`; the cross-OS
   job is what guards that.
2. **Transcendentals** in state come from `base/numbers.odin`: `base.sin`,
   `base.cos`, `base.sincos` and `base.exp`, each for `f32` (computed in `f64`,
   rounded once) and `f64`. They are plain Odin code (Cephes' sine and cosine as
   `core:math.sincos_f64` has them, FreeBSD's `e_exp.c` for `exp`). `core:math`'s
   `sin`, `cos`, `tan`, `pow`, `exp`, `fmuladd` (and `sinh`, `cosh`, `tanh`,
   `gamma`, `lgamma`, `erf`, `erfc`) are LLVM intrinsics: each OS's libm answers
   them, and `-o:speed` may fold them at compile time with another answer. Allowed
   from `core:math`: `sqrt`, `abs`, `min`, `max`, `clamp`, `floor`, `ceil`,
   `trunc`, `round`, `mod`, `atan2`, `asin`, `acos`, `ln`, `smoothstep`, `lerp`
   (correctly rounded, or plain Odin code). Integer powers are multiplications.
3. **Randomness** in state is `base.Rng` (`base/rng.odin`): xoshiro256** seeded
   through splitmix64, 32 bytes of state, a stream that is ours. Never
   `core:math/rand` (ChaCha8, 1 KiB of state, a stream the toolchain may change).
   Each stream is seeded from its world's seed XOR a named constant. Crypto
   randomness (nonces, keys) is never state.
4. **Map order** never reaches state or the wire: walk a pool in slot order, or
   the keys sorted (`base.keys_sorted(m, less, allocator)` with
   `game.chunk_pos_less` and `game.block_pos_less`: y, then z, then x). Maps stay
   for lookup. Odin seeds each map's hash from the address of its table, so
   iteration order differs between runs and between OSes.
5. **No wall clock in state**: time is ticks. The wall clock paces the live server
   and times stats and telemetry. Real-time bans and the damaged-file suffix are
   not state.
6. **A float is cast to an integer only when known to be in range.** Out-of-range
   and NaN casts differ between x64 and arm64.
7. **A toolchain bump** (`odinup.toml`) can change `core:math`'s Odin code. The
   cross-OS job and worldgen's golden run on every commit, so a bump that changes
   state fails CI on the bump itself.

A line that is not state says so with a trailing `// numbers: <why>` and the lint
lets it be (`prediction_decay`'s visual offset, the pipe's simulated jitter).

## The state hash

`game/state_hash.odin` is a reflective walker with two outputs: `hash_value` folds
a value into a `Hasher`; `dump_value` writes a line per leaf,
`entities[3].body.velocity.x = 0x3f8ccccd (1.1)`. Floats are their bits (so -0
is not 0), padding never enters, a map or a pointer panics with its path (keyed
state is hashed by hand, in sorted order). A field added to a struct is hashed
without anyone remembering to.

`server/state_hash.odin` hashes what a tick left, in sections: `Clock`, `Rules`,
`Players`, `Inventories`, `Entities`, `Chunks` (the chunks changed this tick),
`Liquids`, `Containers`, `Gates`, `Random`, `Ledger`. The root chains
(`root(t) = mix(root(t-1), t, sections(t))`), so a divergence stays visible from
its first tick on. Hashing runs only on stepped servers. `Config.perturb` (tests)
puts one ulp into the state a tick leaves, to prove a divergence is named.

## The cross-OS job

`build determinism` runs `server.test_determinism_session` (a scripted 10 000-tick
session on a stepped server, seed 38, with a mirror client on the pipe) at
`-o:minimal` and `-o:speed`, each writing `build/determinism/<os>.<opt>.txt` (a
line per tick with every section's hash, and a full dump at each checkpoint), and
compares the logs. In CI every Test job runs it and uploads its logs; the
`determinism` job compares all six (`build determinism --compare <dir>`) and names
the first differing tick, its sections, and the first differing line of the next
checkpoint's dump.

The test itself runs a session twice, side by side, with the two servers' maps at
different addresses, and compares every tick's root; a difference is reported as
`diverged at tick 5000: Entities: entities[0].yaw = 0x3f8ccccd (1.1) vs ...`.
The everyday suite runs 2 000 ticks (`-define:VX_DETERMINISM_TICKS=n`).

## The desync detector

Every 30 inputs the client sends a `Prediction_Check`: a 32-bit hash per field of
the state it predicted after that input. The server hashes its own state after the
same input. It judges the check only if the player has been **quiet** for 60 ticks
(`disturb` marks a teleport, landing, knockback, saved state, rules change, an input
refused, a changed block within 4 blocks of the box), and names what differs:
`server desync player=<name> sequence=<n> fields=velocity,position`. Counted in
`Stats.desyncs`, `checks_judged`, `checks_skipped` and the minute's tick summary
line. A check never changes state. Not done: sending a desync dump back to the
client, showing desyncs in F3, lockstep determinism of the live server.
