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

`common/game/state_hash.odin` is a reflective walker with two outputs: `hash_value` folds
a value into a `Hasher`; `dump_value` writes a line per leaf,
`entities[3].body.velocity.x = 0x3f8ccccd (1.1)`. Floats are their bits (so -0
is not 0), padding never enters, a map or a pointer panics with its path (keyed
state is hashed by hand, in sorted order). A field added to a struct is hashed
without anyone remembering to.

`server/state_hash.odin` hashes what a tick left, in sections: `Clock`, `Rules`,
`Players`, `Inventories`, `Entities`, `Chunks` (the chunks changed this tick),
`Liquids`, `Containers`, `Gates`, `Random`, `Ledger`, `Journal` (every entry and action of the tick, folded as made: both sides of the side-by-side run journal alike; docs/journal.md). The root chains
(`root(t) = mix(root(t-1), t, sections(t))`), so a divergence stays visible from
its first tick on. Hashing runs only on stepped servers. `Config.perturb` (tests)
puts one ulp into the state a tick leaves, to prove a divergence is named.

## The harness

`server/harness.odin` is what tests run a stepped server on (T2, issue #66): a `Harness`
holds the server, an in-memory network and the parties that play on it, and a test
waits for a **number of ticks**, never for a clock or a sleep.

- **A tick** (`harness_step`): the network's clock moves to the time of the tick about to
  run (`simnet_tick_time(tick)`: `tick * 1 s / TICK_RATE` in integers after a fixed epoch,
  so 30 ticks are exactly a second), every party takes its turn in the order added (the M38
  mirror, a test client, a `client.Session`, a bot), then the server steps. What a party
  sends in a tick is handled in that tick; what the server sends at its end is there for
  the parties at the next. `harness_step_until(until, data, max_ticks)` checks after each
  tick and fails after exactly `max_ticks`.
- **The clock.** `netcode.Simnet` (`common/netcode/simnet.odin`) is datagram ports with an
  inbox each, on a clock only its owner moves. A `Socket` opened with `sim` is a port on it;
  hosts and links (`socket_now`, `host_now`, `link_now`) take their time from it, so
  keepalives, resends, the rate allowance and the timeouts count ticks. `Config.net` puts
  the server's host on it, `Session_Config.net` a client's link. The live tick's pacing and
  the save timings keep the wall clock: they are not state.
- **The network's seed.** Loss, duplication, delay and jitter are drawn from `base.Rng`
  streams, one a socket, seeded `Conditions.seed ~ (port << 32)`: a socket's draws do not
  depend on the others' traffic, and the same seed gives the same losses at the same ticks.
  A simulated network is never seeded from the clock (seed 0 becomes `SIMNET_DEFAULT_SEED`).
  The handshake's crypto randomness (cookies, salts, nonces) is never state (rule 3) and
  draws nothing from these streams.
- **The fixed world.** `harness_world()`: the `Flat` generator (grass at y -1, three layers
  of dirt, stone, a bedrock floor at the world's bottom; the same for every seed), seed 66,
  view radius 2 and height 1 (39 chunks a player), spawn at `{0.5, 0, 0.5}`, cheats on,
  and `harness_rules()`: no random ticks, no daylight cycle, no natural spawning. A test
  turns one on in its config or through `/gamerule`. A test that needs the Earth keeps its
  own config (`harness_start` forces only `stepped`, `workers = 0` and the network).

- **What a test holds across steps.** The server frees the temp allocator at the end of
  each tick; the harness gives it an arena of its own, so the strings a test keeps in its
  own temp (a directory, a name) survive the steps. `step` publishes `Stats` (timings zero:
  a stepped server reads no clock), and `call` on a stepped server runs its procedure at
  once, between two steps; a test that needs the tick that takes a change in steps one.
- **The local player's pipe** reads the harness's clock too (`Pipe.clock`) and draws its
  jitter from a seeded `base.Rng` (`pipe_seed`): `game.pipe_set_conditions(&h.pipe, ...)`
  after `harness_start(local = true)` gives latency in ticks, the same on every run.
- **Waiting in a test.** `net_connect(&c, 0, name, h = &h)` joins a test client to the
  harness; `net_wait`, `net_for` and `net_ticks` pump the clients and step the harness, and
  `wait_until` does the same for the pipe's `Fake_Client`. A wait is `seconds * TICK_RATE`
  ticks at most, never a clock.

## Scenarios

`server/scenario_test.odin` (T3) plays a `Scenario` (steps of a tick, a player and an
operation) on the harness: the mirror (player 0, predicting) and bots on the simulated
network. Whatever the scenario does, the runner checks no desync, item conservation by
`audit`, that every chunk a player holds is the server's, that the scenario played twice
gives the same hash at every tick, and no leak or bad free (counted with a tracking
allocator: the test runner only warns). A new area of play is a new scenario, not a new
test with its own setup.

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
