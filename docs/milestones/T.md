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

## T4b: the tests that still sleep or read a clock (done)

Full spec: [history.md](../history.md) (T4b).

## T5: no timing in tests

Every performance budget asserted in a test moves to `build bench` (M19) with baselines and
tolerances, gated by CI's `Benchmark check`. `budget_applies()` (#55) goes. T4b dropped two
budgets from `common/telemetry` (an emit's cost, a burst's speed) and the file device's
"faster than real time": T5 gives them bench scenarios.

## T6: the smoke suite, the new lints, CI

`./build.sh smoke` (runs `odin test smoke` single-threaded: the files exist since T4b, see
history.md; add `smoke` to the format and check dirs): one test per subsystem that really runs the thing (networking over real
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
