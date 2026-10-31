# Fuzzing

Every parser of untrusted input is a **target** of one harness of ours, written in Odin
(`common/base/fuzz`, the driver `tools/fuzz`, the command `build fuzz`). Ground rule 6 says
untrusted input is validated at the edge; this is how that is a checked claim anyone can rerun.

## Why our own harness, guided by outcome signatures

Odin's pinned compiler has no coverage instrumentation (`odin build -help`: `-sanitize` offers
address, memory and thread only; no SanitizerCoverage, no libFuzzer). Building the targets as
LLVM IR and linking them with clang's `-fsanitize=fuzzer` would add clang and libFuzzer (C++)
to the build, work on Linux only, and depend on an unsupported output path with Odin's
runtime. So the harness is guided by **outcome signatures**, not edge coverage: each target
returns a `u64` that says what the input made the decoder do (the error or refusal, the stage
reached, a bucket of bytes consumed), and an input whose signature the run has not seen joins
the run's corpus. That finds the decoder's distinct paths through its errors, which is where a
hostile file goes. When Odin gains coverage instrumentation the harness adds edge coverage as a
second signature source; nothing else changes.

## Running it

```
./build.sh fuzz --list                                   the targets
./build.sh fuzz --smoke                                  every target, 2 000 cases at seed 84, then its regression files (CI's push step)
./build.sh fuzz [<target>...] --seed N --cases N         N cases each
./build.sh fuzz [<target>...] --seed N --seconds N       N seconds each
./build.sh fuzz --sanitize --seconds 60                  the same under AddressSanitizer (Linux)
./build.sh fuzz <target> --case <file>                   one input: its signature and result
./build.sh fuzz <target> --minimize <file>               shrink a failing input to <file>.min
./build.sh fuzz <target> --keep <dir>                    write the run's corpus out (by hand, to grow seeds)
./build.sh fuzz <target> -- <options>                    options for a target that has its own (none yet)
```

Each target runs in a process of its own. If it crashes the supervisor records it and starts
the target again at the next seed, so one crash does not end the run. The exit code is 1 on any
failure, with the files' paths.

## The contract of every target

No panic, no failed assert, no bounds failure, no read outside the input (AddressSanitizer, in
the nightly run), no leak (each case runs under a tracking allocator that must be empty
afterwards: a leak is a failure naming the allocation's line), no allocation past the target's
cap (`max_len * 64` bytes unless the table says otherwise), and no case over 2 s of the
thread's CPU time (a watchdog ends the process after 20 s of wall time with the input saved).
An `Error` or a refusal is a pass. A target may also check what a decoder promised and call
`fuzz.fail` (a refused import leaves no files behind).

Mutations come from `base.Rng`: a bit, a byte or a 2-, 4- or 8-byte integer set to an
interesting value, a run inserted, deleted or copied, a splice with another corpus input, a
dictionary token, a truncation; one to eight a case. A target may give a *generator* (a
structured input: valid JSON, a valid region file) and a *fixup* (rewrites checksums after a
mutation, half the cases, so a damaged body reaches the decoder behind its checksum).

## A crash found

The harness copies each input into a preallocated buffer before the case; the crash hook (a
failed assert, a fatal signal, the watchdog, AddressSanitizer's death callback) writes it to
`build/fuzz/<target>/crash-<XXH64>.bin` with the target, seed and reason in `crash-<XXH64>.txt`.
Then:

1. `./build.sh fuzz <target> --case build/fuzz/<target>/crash-<hash>.bin` reproduces it.
2. `./build.sh fuzz <target> --minimize <that file>` writes `<file>.min`.
3. Fix the decoder **at its cause** (a missing length check, an unchecked enum, a count trusted
   before allocation): never by catching it in the target.
4. Commit the minimized input as `testdata/fuzz/<target>/regress/<what it caught>.bin`
   (e.g. `region-palette-count-past-4096.bin`) in the same commit as the fix. The suite replays
   every regression file of every target on the three OSes (the target's
   `test_fuzz_<target>_smoke`); for `pack.ogg` the directory is
   `common/ogg/testdata/edge/regress/`.

A failure inside `core:` (for example `core:image/png`) is fixed in our layer, by checking what
we hand it, and is written below with the input, for the owner to report upstream.

## The targets

| Target | Entry | Generator | Notes |
|---|---|---|---|
| `pack.json` | `json_parse` | random JSON to depth 45 (past the depth cap), long strings, escapes, numbers at the edges | |
| `pack.registry` | `registry_build` over the base pack with one file replaced | the base pack's JSON files with one to four values replaced (a number by a string, an array by a 10 000-element one, ...) | errors carry a line inside the input |
| `pack.png` | `png_texture` | a valid 16x16 PNG with IHDR sizes at the edges | CRCs repaired by the fixup |
| `pack.ogg` | `ogg.fuzz_one` | the edge-case files as seeds (`common/ogg/testdata/edge/`) | moved from `build ogg fuzz`; page CRCs repaired |
| `pack.archive` | `pack_archive_read` | a valid archive of three files | refusals of bad paths and sizes |
| `save.region` | `region_open`, then every chunk by `region_next_chunk` | a region of four chunks written by the save code | header checksum repaired |
| `save.journal` | `journal_read_segment` | a segment of 64 records of every kind | header and record checksums repaired |
| `save.tx` | `tx_decode` | a transaction of three files and a deletion | unsafe paths are failures |
| `save.player` | `player_parse` and `kit_parse` on the same bytes | a player file written by `player_json` | |
| `save.structure` | `template_decode` | a template written by `template_encode` | |
| `save.import` | `universe_import` of the bytes as an export file, under `build/tmp/fuzz/` | an export of a two-world universe | a refused import leaves nothing in `dest` |
| `save.config` | the first byte picks `permissions_parse`, `grants_parse`, `packs_parse` or `counters_read` | each file as the server writes it | |

Seeds are the generators; a committed corpus (`testdata/fuzz/<target>/`) is grown by hand with
`--keep`. Where a decoder needs a file the target writes it under `build/tmp/fuzz/` and removes
it after the case.

## CI

- "Fuzz (smoke)" in "Test · Linux x64", after Test: `./build.sh fuzz --smoke`.
- The suite on all three OSes: each target's `test_fuzz_<target>_smoke` (200 cases at seed 84
  and its regression files), the harness's own tests (`common/base/fuzz/fuzz_test.odin`).
- `.github/workflows/nightly.yml` ("Fuzz · nightly", 03:17 UTC and by hand): every target four
  minutes under AddressSanitizer at the run number's seed; `build/fuzz/` is uploaded when
  anything failed. A failed nightly run is a bug like any failed run.

## Found so far

- `pack_archive_read` leaked the file table and the files read so far when it refused an
  archive (found by the first smoke run; fixed, the refusal frees them).
