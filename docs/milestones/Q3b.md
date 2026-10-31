# Q3b: crash bundles, the rest (the dialog, the Windows stacks, the recorded state)

**Why.** Q3 (history.md) wrote the bundle: the rings, the writer, thread registration, every
thread's stack on POSIX, the CI check. What it left out is what a player sees and what only a
Windows machine can do. Read Q3's spec in history.md first; its decisions stand.

**What Q3 built (so this row starts from the code as it is):** `common/base/crash_bundle.odin`
(`crash_bundle_init(root, app)`, `crash_bundle_write(what)`, `crash_bundle_log` (fed by the
logger), `crash_bundle_action(kind, detail)`, `crash_bundle_set_gpu`, `crash_bundle_set_state`,
`thread_register(name)` / `thread_unregister()`), `crash_bundle_posix.odin` (SIGUSR2 and a
per-thread alternate stack), `crash_bundle_windows.odin` (files only; other threads are listed
"did not answer"). The client calls `crash_bundle_init(crashes_dir(), "game")` in `main`; the
dedicated server `<universe>/crashes` when it serves. Actions recorded so far: pad and key
action presses and releases (`actions_update`) and console command names (`console_execute`).
`tests/crash_bundle_test.odin` and `tests/crash_fixture` are the smoke test (the spec's
`smoke/` is the `tests` package).

**To build:**

1. **Windows: every thread's stack** (`crash_bundle_windows.odin`). The crashing thread suspends
   each registered thread (`Thread_Handle` is the thread id: `OpenThread` with
   `THREAD_SUSPEND_RESUME | THREAD_GET_CONTEXT`), reads its context (`GetThreadContext`), walks
   its stack with `RtlLookupFunctionEntry` and `RtlVirtualUnwind` (x64) into the slot's
   `frames`, sets `done`, resumes nothing. No minidump. The smoke test then requires all five
   threads on Windows too (drop its `when ODIN_OS == .Windows` skip of the other three modes);
   the stack-overflow label needs `EXCEPTION_STACK_OVERFLOW` (0xC00000FD) in the exception
   filter's `what` ("(stack overflow)"), as POSIX's.
2. **The state and the other records.** `crash_bundle_set_state` at the title ("title"), while
   loading ("loading"), in a world ("world <address>"; "singleplayer", "LAN" or "remote", never
   the address typed); `crash_bundle_action` for a screen or overlay opening and closing
   (`screen`, the screen's name) and a world joined or left (`world`, "join"/"leave"); the
   dedicated server's records (joins and leaves as counts, saves, command names).
3. **The offer** (`client/overlay_crash.odin`), as Q3's spec describes: the dialog on the title
   when it first shows and a bundle without a `seen` file exists; "Open folder" (`xdg-open`,
   `explorer`, `open` as a child process; a failure toasts the path) and "Close"; each writes
   `seen`; "and N earlier" for several; focus on "Close"; Escape and B close; the strings in the
   string table; the existing dialog style (`overlay_quit.odin`). The dedicated server prints
   `crash report from the last run: <path>` at start for an unseen bundle and writes `seen`.
4. **`client/overlay_crash_test.odin`** (headless UI tests): an unseen bundle opens the dialog on
   the title; "Close" writes `seen` and a second start shows nothing; three unseen bundles name
   the newest "and 2 earlier"; the dialog is reachable and closable by pad only.

**Decided after CI (2026-10-31):** the first macOS smoke run of Q3's crash test hung for 50 minutes
and the runner was lost. The writer is now bounded: `bundle_watchdog` arms `alarm(20)` (SIGALRM's
default action ends the process) around `crash_bundle_write`; `threads.txt` is written with raw
addresses first and again with resolved frames last, because resolving on macOS (CoreSymbolication)
takes locks and talks to other processes; `limited.run_limited` waits at most 30 s for a killed
child; the macOS Smoke CI step has `timeout-minutes: 15`. Windows has no watchdog yet.

**Left out:** as Q3's (uploading, symbol files, GPU-driver crashes, a crash in the writer).

**Exit check:** the UI tests and the smoke test (all five threads on the three OSes in CI) pass;
the suite and `build check` green.

**Check by hand:** on macOS, if CI's Smoke step still fails or times out: run `./build.sh smoke` and note which of the four fixture modes (`build/tmp/crash_fixture build/tmp/x <mode>`) hangs or lacks `  at ` frames in `threads.txt`.  on Windows, run `voxiverse.exe --exec crash` from the package, start the game
again: the dialog opens on the title, "Open folder" opens Explorer on a folder holding the four
files, and `threads.txt` lists the main thread and the audio decoder threads with frames. On
macOS, the same with the `.app` (Finder opens the folder).
