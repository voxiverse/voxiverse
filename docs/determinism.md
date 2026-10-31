# Determinism

This document defines which parts of Voxiverse are bit-identical, and the rules that keep
them so.

The simulation is a function of what reaches it at each tick boundary. Several systems depend
on this property:

- the journal replays onto a snapshot;
- a rollback lands on an exact hash;
- a script's state is snapshotted and restored;
- a client on one operating system predicts what a server on another decides.

Read this document before changing shared code (`common/game/`, `server/`, `common/worldgen/`).
`build check` enforces rules 2 and 3.

## Tiers

| Tier | Scope | Guarantee |
|---|---|---|
| **State** | Server simulation, prediction, world generation, light, rules, RNG | Bit-identical on every operating system and optimization level. |
| **Replayable** | The audio mixer and its capture, client visuals | Bit-identical on one operating system and optimization level. The audio baselines keep a checksum per operating system. |
| **Free** | Rendering, UI, timing | None. |

A live server is not lockstep: inputs and chunk jobs arrive when they arrive. The
reproducible form is the **stepped server** (`Config.stepped`). A stepped server starts no
thread, runs chunk jobs inline, and receives inputs per tick. It is currently used by the tests and the
cross-OS job, and will be used by replay. No map iteration order and no thread
completion order may reach state or the wire.

## Rules

1. **Floats.** Floats in state are IEEE `f32`/`f64` with default rounding. Do not use
   `math.fmuladd` or fast-math. Odin does not contract `a*b + c`; the cross-OS job guards
   against that changing.
2. **Transcendentals.** Transcendental functions in state come from `common/base/numbers.odin`:
   `base.sin`, `base.cos`, `base.sincos` and `base.exp`, each for `f32` (computed in `f64`
   and rounded once) and for `f64`. They are plain Odin code: Cephes' sine and cosine as
   `core:math.sincos_f64` has them, and FreeBSD's `e_exp.c` for `exp`.

   `core:math`'s `sin`, `cos`, `tan`, `pow`, `exp`, `fmuladd` (and `sinh`, `cosh`, `tanh`,
   `gamma`, `lgamma`, `erf`, `erfc`) are LLVM intrinsics. Each operating system's libm
   answers them, and `-o:speed` may fold them at compile time with a different answer.

   The following `core:math` procedures are allowed, because they are correctly rounded or
   plain Odin code: `sqrt`, `abs`, `min`, `max`, `clamp`, `floor`, `ceil`, `trunc`, `round`,
   `mod`, `atan2`, `asin`, `acos`, `ln`, `smoothstep`, `lerp`. Integer powers are written as
   multiplications.
3. **Randomness.** Randomness in state is `base.Rng` (`common/base/rng.odin`): xoshiro256** seeded
   through splitmix64, with 32 bytes of state and a stream the project owns. Never use
   `core:math/rand` (ChaCha8, 1 KiB of state, and a stream the toolchain may change). Each
   stream is seeded from its world's seed XOR a named constant. Cryptographic randomness
   (nonces, keys) is never state.
4. **Map order.** Map iteration order never reaches state or the wire. Walk a pool in slot
   order, or walk the keys sorted (`base.keys_sorted(m, less, allocator)` with
   `game.chunk_pos_less` and `game.block_pos_less`: y, then z, then x). Maps remain in use
   for lookup. Odin seeds each map's hash from the address of its table, so iteration order
   differs between runs and between operating systems.
5. **No wall clock in state.** Time in state is measured in ticks. The wall clock paces the
   live server and times statistics and telemetry. Real-time bans and the damaged-file suffix
   are not state.
6. **Float-to-integer casts.** A float is cast to an integer only when it is known to be in
   range. Out-of-range and NaN casts behave differently on x64 and arm64.
7. **Toolchain updates.** A toolchain bump (`odinup.toml`) can change the Odin code of
   `core:math`. The cross-OS job and the world generation golden test run on every commit,
   so a bump that changes state fails CI on the bump itself.

A line that is not state declares so with a trailing `// numbers: <why>` comment, and the lint
accepts it. Examples are `prediction_decay`'s visual offset and the pipe's simulated jitter.

## The state hash

`common/game/state_hash.odin` is a reflective walker with two outputs:

- `hash_value` folds a value into a `Hasher`;
- `dump_value` writes one line per leaf, for example
  `entities[3].body.velocity.x = 0x3f8ccccd (1.1)`.

Floats are hashed as their bits, so -0 is distinct from 0. Padding never enters the hash. A
map or a pointer causes a panic naming its path; keyed state is hashed by hand, in sorted
order. A field added to a struct is therefore hashed without any further action.

`server/state_hash.odin` hashes what a tick left behind, in sections:
`Clock`, `Rules`, `Players`, `Inventories`, `Entities`, `Chunks`, `Liquids`, `Containers`,
`Gates`, `Random`, `Ledger` and `Journal`. The `Chunks` section covers the chunks changed
this tick. The `Journal` section covers every entry and action of the tick, folded as
made; in the side-by-side run, both sides journal alike (see [journal.md](journal.md)).

The root is chained, `root(t) = mix(root(t-1), t, sections(t))`, so a divergence remains
visible from its first tick onwards. Hashing runs only on stepped servers. `Config.perturb`
(used by tests) introduces one ulp into the state a tick leaves, to prove that a divergence
is reported by name.

## The harness

`server/harness.odin` provides the stepped server that tests run on (T2, issue #66). A
`Harness` holds the server, an in-memory network, and the parties that play on it. A test
waits for a **number of ticks**, never for a clock or a sleep.

### Ticks

`harness_step` performs one tick:

1. The network's clock moves to the time of the tick about to run
   (`simnet_tick_time(tick)`: `tick * 1 s / TICK_RATE` in integers after a fixed epoch, so
   30 ticks are exactly one second).
2. Every party takes its turn, in the order added: the M38 mirror, a test client, a
   `client.Session`, a bot.
3. The server steps.

What a party sends during a tick is handled in that tick. What the server sends at the end of
a tick is available to the parties at the next. `harness_step_until(until, data, max_ticks)`
checks its condition after each tick and fails after exactly `max_ticks`.

### The clock

`netcode.Simnet` (`common/netcode/simnet.odin`) is a set of datagram ports, each with an
inbox, on a clock that only its owner advances. A `Socket` opened with `sim` is a port on it.
Hosts and links (`socket_now`, `host_now`, `link_now`) take their time from it, so
keepalives, resends, the rate allowance and the timeouts all count ticks. `Config.net` places
the server's host on the simulated network, and `Session_Config.net` places a client's link
on it. The live tick's pacing and the save timings keep the wall clock, because they are not
state.

### The network seed

Loss, duplication, delay and jitter are drawn from `base.Rng` streams, one per socket, seeded
with `Conditions.seed ~ (port << 32)`. A socket's draws therefore do not depend on other
sockets' traffic, and the same seed produces the same losses at the same ticks. A simulated
network is never seeded from the clock; seed 0 becomes `SIMNET_DEFAULT_SEED`. The
handshake's cryptographic randomness (cookies, salts, nonces) is never state (rule 3) and
draws nothing from these streams.

### The fixed world

`harness_world()` returns the fixed test world:

- the `Flat` generator: grass at y -1, three layers of dirt, stone, and a bedrock floor at
  the world's bottom, identical for every seed;
- seed 66;
- view radius 2 and height 1 (39 chunks per player);
- spawn at `{0.5, 0, 0.5}`;
- cheats on.

`harness_rules()` disables random ticks, the daylight cycle and natural spawning. A test
enables one in its config or through `/gamerule`. A test that needs the Earth generator keeps
its own config; `harness_start` forces only `stepped`, `workers = 0` and the network.

### State held across steps

The server frees the temp allocator at the end of each tick. The harness gives it an arena of
its own, so strings a test keeps in its own temp allocator (a directory, a name) survive the
steps. `step` publishes `Stats`; its timings are zero, because a stepped server reads no
clock. `call` on a stepped server runs its procedure immediately, between two steps; a test
that needs the tick that applies a change must step once.

### The local player's pipe

The local player's pipe also reads the harness's clock (`Pipe.clock`) and draws its jitter
from a seeded `base.Rng` (`pipe_seed`). Calling `game.pipe_set_conditions(&h.pipe, ...)`
after `harness_start(local = true)` gives latency in ticks, identical on every run.

### Waiting in a test

`net_connect(&c, 0, name, h = &h)` joins a test client to the harness. `net_wait`, `net_for`
and `net_ticks` pump the clients and step the harness, and `wait_until` does the same for the
pipe's `Fake_Client`. A wait lasts at most `seconds * TICK_RATE` ticks; it never reads a clock.

## Scenarios

`server/scenario_test.odin` (T3) plays a `Scenario` on the harness. A scenario is a sequence
of steps, each consisting of a tick, a player and an operation, played by the mirror
(player 0, predicting) and bots on the simulated network. Whatever the scenario does, the
runner checks that:

- no desync occurs;
- items are conserved, by `audit`;
- every chunk a player holds matches the server's;
- the scenario played twice produces the same hash at every tick;
- there is no leak or bad free, counted with a tracking allocator (the test runner itself only
  warns).

A new area of play is covered by a new scenario, not by a new test with its own setup.

## The cross-OS job

`build determinism` runs `server.test_determinism_session`, a scripted 10 000-tick session
on a stepped server with seed 38 and a mirror client on the pipe. It runs at `-o:minimal`
and at `-o:speed`, each writing `build/determinism/<os>.<opt>.txt` (one line per tick with
every section's hash, and a full dump at each checkpoint), and compares the logs.

In CI, every Test job runs it and uploads its logs. The `determinism` job compares all six
(`build determinism --compare <dir>`) and names the first differing tick, its sections, and
the first differing line of the next checkpoint's dump.

The test itself runs a session twice, side by side, with the two servers' maps at different
addresses, and compares every tick's root. A difference is reported as:

```
diverged at tick 5000: Entities: entities[0].yaw = 0x3f8ccccd (1.1) vs ...
```

The everyday suite runs 2 000 ticks (`-define:VX_DETERMINISM_TICKS=n`).

## The desync detector

Every 30 inputs, the client sends a `Prediction_Check`: a 32-bit hash per field of the state
it predicted after that input. The server hashes its own state after the same input.

The server judges a check only if the player has been **quiet** for 60 ticks. `disturb`
marks a player as disturbed on a teleport, a landing, knockback, saved state, a rules change,
a refused input, or a changed block within 4 blocks of the player's box. When a judged check
differs, the server names the differing fields:

```
server desync player=<name> sequence=<n> fields=velocity,position
```

Desyncs are counted in `Stats.desyncs`, `checks_judged`, `checks_skipped`, and the minute's
tick summary line. A check never changes state.

The following are not implemented: sending a desync dump back to the client, showing desyncs
in F3, and lockstep determinism of the live server.
