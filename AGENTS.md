# Working in this repository

Voxiverse is a voxel engine written in Odin and the games built on it, in one repository.
The code is written by agents and read by a person, so it has to read well.

## How work lands

- There is one branch, `main`. Commit to it directly: there are no pull requests, and no
  commit waits on a remote machine. Every commit passes `./build.sh check` (the hook runs
  it: half a minute from cold, seconds when little changed) and the tests of the packages
  it touched. That is all a change needs.
- The whole gate (`./build.sh gate`, twenty minutes) runs once a day and before a version
  tag, not for every change. Whoever finds it failing fixes it first.
- The one workflow on GitHub (`.github/workflows/release.yml`) builds the three platforms'
  packages: for a version tag, which publishes them, and once a day for `main`, which
  publishes nothing. It tests nothing and gates nothing.
- A worktree or branch exists only while one change is being made. Rebase it onto `main`,
  land it, and delete it the same day. Do not leave a branch behind: the next agent will
  mistake it for something that matters.
- Delete what is no longer used: code, docs, assets, tools. Git remembers it.

## Before you commit

```sh
./build.sh fmt              # format what you changed
./build.sh check            # type checks, lints, layout, formatting, skipping what passed unchanged (the pre-commit hook runs it)
./build.sh test <package>   # every package you touched; all of them for a change in common/
./build.sh check --cross    # also compiles for Windows and macOS: for any change to platform code
./build.sh gate             # the whole gate: once a day and before a version tag, not per change
```

`./build.sh gate` is the whole gate in one command: `check --cross --all`, every test package
then the image baselines on lavapipe (about ten minutes on 8 cores), `bench budgets -check`
and `fuzz --smoke`. It blocks until done, goes on past a failed stage, and ends with a
table and one line, `gate PASSED` or `gate FAILED: <stages>`, with each failed stage's log
(`build/gate/`) and its first error lines above it. Run it in the foreground with a long
timeout (30 minutes) and read its last line. Never write a loop that polls for a build
(`pgrep`, `sleep`): every `./build.sh` command blocks until it is done, a second one waits
for the first, and a gate refuses to start beside another gate or test.

A change to `client/` or `assets/shaders` that changes a picture re-accepts its baseline in
the same commit (`./build.sh images --accept <scene>`), saying why.

`./build.sh help` lists the rest (system tests, benchmarks, fuzzing, visual baselines).

## The rules the code follows

- [`docs/design.md`](docs/design.md): the foundations and the ground rules. They are not
  suggestions. If a task cannot be done within them, say so instead of bending one.
- [`docs/layout.md`](docs/layout.md): where every file goes. `check` enforces it, with no
  exemptions. A new folder needs its row in the same commit.
- Building or changing a game: read [`docs/engine-map.md`](docs/engine-map.md) first. It
  is every hook and every call the engine offers a game, with its signature and doc,
  generated from the source; [`docs/games.md`](docs/games.md) says how they fit together.
  Look there before searching the engine. A new game starts from `./build.sh new-game <id>`.
- A rule worth having is a rule `check` enforces. When you find yourself following a
  convention that nothing checks, add the lint.
- Write the Odin a careful Odin programmer would: the names, shapes and idioms of the
  code around you and of Odin's `core:` library. Readability is the quality bar.
- A doc says what is true of the code now. Change the behaviour, change the doc, in the
  same commit.
- A bug fix comes with a test that fails without it.
- Never weaken a test, a budget or a lint to get past it. If it is wrong, fix it and say
  why in the commit.
- No new dependencies and no vendored code. Ideas may come from other engines; their code
  may not.

## Commits

One logical change per commit, and each commit passes `check` on its own.

The subject is `Category: Imperative description`, at most 72 characters, no trailing
period. The category is the folder the change is about, as `docs/layout.md` lists it
(`server/core`, `tools/build`), or `Docs` for `docs/`, or `Meta` for repository-wide files.
The body, wrapped at 72 columns, says why. The `commit-msg` hook checks the form.

A commit written by a model ends with a trailer naming that exact model:

```
Co-Authored-By: Claude Fable 5.2 <noreply@anthropic.com>
```

## When you are stuck

Say so plainly: what you tried, what you found, what you would need. "Could not
reproduce" is a result. A guess presented as a fix is not.
