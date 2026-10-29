# T1-T7: the test and CI overhaul (issue #66, the owner's priority, before the toys)

The owner is tired of a bloated, flaky suite and a CI that is too complex. Measured when
the issue was written: 653 tests in 174 files, 41,000 lines (half the game's code); 82
`time.sleep` calls in 32 files, 262 polling waits, 155 real-socket uses, 32 files starting a
real threaded server against 16 using the stepped server, 48 timing budgets in unit tests.
All 11 flakes since 2026-10-27 came from three patterns: wall-clock timing, real threads
with sockets and sleeps, and uncontrolled world state (natural spawning). The fix is the
architecture, not single tests.

These rows come **first among the open rows**, ahead of M48k; M49 and M50 stay held and the
party toys (#65) come after. Each row leaves the suite green.

## Decisions (made here; the issue left them open)

- **Order.** Lints first (T1: they need no harness), then the harness (T2), the scenario
  runner (T3), the migration of the 32 threaded-server files (T4), timing out of tests (T5),
  the smoke suite with the new lints and CI (T6), the prune and the numbers (T7). The two new
  lints that forbid sleeps, clocks and `start(&srv…)` in unit tests land in **T6**, when
  nothing violates them: a lint that fails on 187 existing lines cannot be switched on first,
  and an exemption list is not allowed (#62).
- **A lint has no exemption, skip list or allow-list.** The old mode-name test allowed three
  client files; T1 changed the code instead (the universes card compares with `MODE_SURVIVAL`,
  the console's inventory command compares with the tab's own name), then moved the rule.
- **Lints live in `tools/build/lints.odin`** (and `determinism.odin` for the numbers rules),
  each a proc from `(path, text)` to messages naming `file:line`, with a test per rule on
  text, so the lint itself is tested without reading the tree.
- **The smoke suite** is a package `smoke/` of tests, run by `./build.sh smoke` and in CI's
  Linux game job only; `./build.sh test` does not list it.
- **Timing budgets** become `build bench` scenarios with baselines (M19); a test checks
  behaviour only.

## T1: source-scanning tests become lints (done)

`test_no_string_literals_in_ui_calls`, `test_no_colour_literals_in_screens` and
`test_no_code_tests_a_mode_by_name` are deleted; `./build.sh check` runs `source_lint`
(ui text literals, colour literals, mode names), with tests of the rules in
`tools/build/lints_test.odin`.

## T2: the deterministic harness

Full spec: [history.md](../history.md) (T2) (the loss lives on netcode over an in-memory network, not on the
pipe; the fixed world is a flat generator; 23 files start a stepped server, not 16).

The stepped server (M38) behind an in-memory transport: seeded loss, latency, reordering and
duplication, no sockets, no threads. A fixed small test world (flat, a known spawn, natural
spawning, random ticks and weather off unless the test turns them on). `step(n)` and
`step_until(pred, max_ticks)` count ticks, never time. Exit: every file that starts a stepped
server (23) runs on it unchanged in meaning; a transport test shows the same seed gives the same
loss pattern.

## T3: scenarios with invariants (done)

Full spec: [history.md](../history.md) (T3).

## T4: the threaded-server files move onto the harness (done)

Full spec: [history.md](../history.md) (T4).

## T4b: the tests that still sleep or read a clock

T4 moved every test that starts a threaded `Server` and could run on the harness. What is
left sleeps or reads a clock for a reason of its own; each moves onto a simulated form, or to
T6's smoke suite (a package `smoke/`, which can use only the packages' public procs):

- `server/upload_test.odin` and `server/collector/collector_test.odin`: a real UDP collector
  and the server's wall-clock upload interval. The upload test goes to the smoke suite; the
  collector's own logic (batches, forged and refused, the lake's files) is tested without
  sleeping, on `netcode` over a `Simnet`, the collector's passes stepped by the test.
- `server/lock_linux_test.odin`: a lock held by a child process (smoke).
- `common/netcode/host_test.odin`, `conn_test.odin`: real loopback UDP with sleeps; move onto
  `Simnet` (they test the host and link, not the OS), keeping one real-UDP round trip in smoke.
- `common/telemetry/telemetry_test.odin`: the writer thread's drain (smoke) and the rest on a
  stepped writer.
- `client/audio/device_test.odin`, `stream_test.odin`, `client/platform/pad_uinput_test.odin`:
  a real device, a decoder thread, a uinput device (smoke); the stream tests that wait for the
  decoder thread run it inline, as the stepped server runs its chunk jobs.
- `client/stats_test.odin`, `blast_test.odin`, `tour_test.odin`, `menus_test.odin`: the app
  reads `time.tick_now()`/`time.now()` itself (a stats search throttle, the report's overlay
  time, the tour's and the blast's phases): the app takes its time from one injectable clock
  (as `Link` takes `now`), the tests move it.
- `server/harness_test.odin` and `server/server_test.odin` call `start(&srv` on purpose, to
  see it refuse (a simulated network without `stepped`, or with conditions). They call a
  `harness_refused(config) -> bool` in `harness.odin` (not a test file) instead, so T6's lint
  on `start(&srv` needs no exemption. (The second-server-on-one-port test already runs on a
  `Simnet`'s port refusal and is a refusal of the same kind.)

Exit: no `*_test.odin` outside `smoke/` calls `time.sleep`, `time.tick_now`, `time.now`,
`tick_since` or `os.process_start`, or opens a thread or a real socket (a refusal expected
from `start` is not a start); the smoke files are listed and each runs under
`./build.sh smoke` once T6 adds it (until then, `odin test smoke`).

## T5: no timing in tests

Every performance budget asserted in a test moves to `build bench` (M19) with baselines and
tolerances, gated by CI's `Benchmark check`. `budget_applies()` (#55) goes.

## T6: the smoke suite, the new lints, CI

`./build.sh smoke`: one test per subsystem that really runs the thing (networking over real
UDP, the real server thread, the audio device, render frames under the CPU Vulkan driver).
New lints in `check`: no `time.sleep`, `time.now`, `tick_now` or `tick_since` in
`*_test.odin` outside `smoke/`; no `start(&srv…)` in unit tests. CI: unit tests once per OS,
the smoke suite in the Linux game job, benchmarks gated; duplicate steps and the
optimized-test special cases removed. The job layout and times before and after are reported.

## T7: prune

Delete tests made redundant by scenarios and invariants and tests that only test their own
fixtures. Report the counts before and after (tests, test lines, suite time per OS, CI time).

## Done when

`./build.sh test` uses no sockets, threads (beyond the runner's), sleeps or wall clocks,
enforced by the lints; the scenario runner covers the areas above; the 11 historically flaky
tests are deleted or deterministic; CI is green on all OSes; the numbers are reported.
