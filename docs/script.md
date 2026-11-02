# The script language

Gameplay scripts (`.vxs` files) are written in our own Lua-like language, compiled to
bytecode and run by a register VM in Odin (`common/script/`). If you know Lua 5.4, you know
most of it: this page lists what is kept, what is added, what is dropped and what is
different, then the limits and how errors look. The design is in M51's spec (history.md).

A *script* is a `.vxs` source; compiling one gives a *module*, its top-level function. A
*run* is one call from the host into the VM until it returns, errors, faults or suspends; a
*slice* is the instruction budget a run gets each time it is started or resumed.

## Kept from Lua 5.4

`nil`, booleans, numbers (64-bit integers and 64-bit floats, both of type `number`),
strings, tables, functions with closures and upvalues; varargs (`...`, `select`); multiple
assignment and multiple returns; numeric and generic `for`, `while`, `repeat ... until` (the
body's locals are visible in `until`), `break`; methods (`a:b()`); integer division `//`;
the bitwise operators on integers (`& | ~ << >> ~x`); string escapes including `\z`, `\x`,
`\ddd` and `\u{...}` (at most U+10FFFF); long strings and comments; `pcall`, `xpcall`,
`error` with any value; metatables (below). Operator precedence is Lua's.

## Added (from Luau)

- `continue`, a reserved word: jumps to the loop's next iteration. In `repeat ... until`
  it is refused when a local declared after it is used in the `until` condition.
- Compound assignment: `+= -= *= /= //= %= ^= ..=`. The target's table and key are
  evaluated once (`t[f()] += 1` calls `f` once).
- Optional type annotations, which are parsed and **ignored**: nothing checks them, and they
  never change what code does.

  ```lua
  type Point = {x: number, y: number?}
  local p: Point = {x = 1}
  local function dist(a: Point, b: Point): number ... end
  local f: (number, number) -> number = math.max
  local m: {[string]: integer} = {}
  ```

  Types are `nil`, a name (`any boolean integer float number string table function thread
  handle`, an alias, or `module.Name`), `{T}` (an array), `{[K]: V}` (a map), `{name: T, ...}`
  (a record), `(A, B) -> R` (a function), `T?` (optional) and `A | B` (a union). `type` is a
  keyword only at the start of a statement `type Name = ...`, so `type(x)` still calls the
  function.

## Dropped

Each gives a compile error saying what to write instead:

- `goto` and labels: use `continue`, `break` or a flag variable.
- The attributes `<const>` and `<close>`.
- Hex float literals (`0x1p4`).
- `_ENV` as a name: a module's globals are its environment table, which the host sets.

There is no ambient clock, randomness, I/O or code loading: no `io`, `os`, `package`,
`require`, `load`, `loadstring`, `loadfile`, `dofile`, `string.dump`, `math.random`,
`math.randomseed`; `collectgarbage` only takes `"count"`; `debug` has only `traceback`.
Using one says where to look instead, e.g. `'math.random' is not available in scripts:
randomness comes from the world API`. The world API (M52) gives randomness, time in ticks,
and `require` within a pack.

Metamethods not supported: `__gc`, `__mode` (weak tables), `__close`, `__pairs`, `__name`
and the bitwise ones.

## Different

- **No string-to-number coercion in arithmetic.** `"10" + 1` is an error ("attempt to
  perform arithmetic on a string value (constant '10')", with the hint to use `tonumber()`).
  Concatenation still formats numbers: `"x=" .. 3` is `"x=3"`.
- **Deterministic everywhere**, so the same script gives the same results on every machine:
  - `pairs` and `next` visit the array part in index order, then the other keys in the order
    they were first inserted. Promised: the order is deterministic, and sequences come first
    in index order.
  - `tostring` of a table, function or coroutine prints a number the VM gives each object in
    turn (`table: 0x0000002a`), never an address.
  - String comparison is bytewise (no locale).
  - Every NaN is the same NaN (`0x7FF8_0000_0000_0000`).
  - `^` is our own `pow` (docs/determinism.md), not the system's.
- **`#t`** is the length of the table's array part, which is always a border: setting
  `t[#t + 1]` appends; setting `t[#t] = nil` shrinks it past trailing nils; a `nil` written
  inside it is a hole. `{1, 2, nil, 4}` has `#` 2, and `t[n] = v` with `n > #t + 1` goes to
  the hash part until the gap is filled.
- **Library functions are raw** where Lua's would call a metamethod from native code:
  `ipairs` ignores `__index`. `tostring` and `print` do honour `__tostring`.
- `__eq` is called only when both operands are tables (or handles of one kind) and not
  raw-equal; `__le` is never derived from `__lt`.
- `__index` chains through tables are limited to 100 ("'__index' chain too long; possible
  loop").
- Tail calls are real: they do not grow the call depth (100 000 deep is fine), and the
  traceback does not show the frames they replaced.
- Numbers follow Lua 5.4: integers wrap on `+ - *`; `/` and `^` always give floats; `//` and
  `%` on integers floor (the result of `%` has the divisor's sign) and raise
  "attempt to perform 'n//0'" / "'n%%0'" for an integer zero; integer/float comparisons are
  exact; `1 == 1.0`; `t[1.0]` is `t[1]`. Floats print with 14 significant digits, with `.0`
  added when that looks like an integer (`3.0`, `1e+15`, `inf`, `nan`).

## The base library

`assert, error, getmetatable, ipairs, next, pairs, pcall, print, rawequal, rawget, rawlen,
rawset, select, setmetatable, tonumber, tostring, type, xpcall`, `collectgarbage("count")`
(the heap in use in KiB) and `debug.traceback([msg])`. `print` writes to the script's output
buffer, which the host drains. `tonumber(s [, base])` takes decimal and hex integers, decimal
floats and bases 2 to 36, with surrounding spaces; anything else gives `nil`.

## The other libraries

Only what is listed exists.

- **string**: `byte, char, find, format, gmatch, gsub, len, lower, match, rep, reverse, sub,
  upper` and `split(s, sep)` (Luau's: a plain separator, every field kept, `split("a,,b",
  ",")` is `{"a", "", "b"}`). Strings have it as their metatable's `__index`, so
  `("x"):rep(3)` works. Patterns are Lua 5.4's (classes `%a %c %d %g %l %p %s %u %w %x` and
  their negations, ASCII only; sets, `%b`, `%f`, anchors, up to 32 captures, position
  captures). A match is limited to 1 000 000 steps ("pattern too complex") and 200 levels of
  recursion. `format` takes `%d %i %c %x %X %o %e %E %f %g %G %q %s %%` with the flags
  `- + space # 0`, width and precision up to 99 (no `%a`); `%s` honours `__tostring`. There is
  no `pack`, `unpack`, `packsize` or `dump`.
- **table**: `concat, insert, move, pack, remove, sort, unpack`. They are raw (no `__index`,
  `__newindex` or `__len`). `sort` is a **stable** merge sort, so equal elements keep their
  order, and an inconsistent comparator never raises "invalid order function".
- **math**: `abs, ceil, floor, fmod, modf, sqrt, exp, log (x [, base]), sin, cos, tan, asin,
  acos, atan (y [, x]), max, min, tointeger, type, ult`, and `pi, huge, maxinteger,
  mininteger`. No `random` (randomness comes from the world API). `log(x, 2)` and
  `log(x, 10)` are `log(x) / log(base)`, which may differ from Lua in the last bit.
  `math.tointeger("8")` is `nil` (no string coercion).
- **utf8**: `char, charpattern, codepoint, codes, len, offset`, strict: no surrogates, nothing
  above U+10FFFF (`utf8.char(0x110000)` is an error).
- **coroutine**: `create, resume, yield, status, wrap, isyieldable, running, close`. A
  coroutine can yield from anywhere inside it: through `pcall`, metamethods, `table.sort`'s
  comparator, `string.gsub`'s function. When a run suspends at its slice (or the host's
  native yields) inside a coroutine, the whole chain of coroutines keeps its state and goes
  on when the host resumes. `coroutine.yield` outside a coroutine is an error.

## Memory

Each VM collects its own garbage, incrementally, as the script allocates (a cycle of tables
is freed like anything else; there are no weak tables and no `__gc`). The collector's work is
counted in bytes, never in time, so a script does the same work and gives the same results
on every machine; only `collectgarbage("count")` and whether a run reaches the memory limit
depend on when it runs. When an allocation finds no room, the collector first finishes a
full cycle, and only then is the memory limit a fault.

## Limits

Each VM has its own limits, set by the host:

| Limit | Default | At the limit |
|---|---|---|
| slice (per call or resume) | 100 000 instruction units | the run **suspends**; the host resumes it exactly there |
| instructions in one run (all its slices) | 10 000 000 | **fault**: the run ends |
| memory (the VM's heap) | 16 MiB | **fault**: the run ends |
| call depth (frames in a run) | 1 000 | **fault**: the run ends |
| one string | 1 MiB | the error "string too large" (catchable) |
| print output between drains | 64 KiB | the rest is dropped and counted: `[output truncated: N bytes]` |

An instruction costs one unit; so do each extra probe of a table lookup and each 64 bytes
allocated. A **fault** cannot be caught: it ends the whole run, through every `pcall`. After
an error or a fault the VM stays usable, and its globals keep what the run had stored.

Source limits, each a compile error naming the limit: 1 MiB of source, 200 levels of
nesting, 200 locals and 255 upvalues per function, 255 registers.

## Errors

Every error has a position (the token for a syntax error, the operator, call or index for a
runtime error), the source line with a caret, often a one-line hint, and for a runtime error
the stack traceback:

```
quests/intro.vxs:12:15: syntax error: 'do' expected after the 'while' condition, got 'then'
   12 |   while x < 10 then
      |                ^^^^
  hint: a while loop is written 'while <condition> do ... end'
```

```
quests/intro.vxs:30:13: runtime error: attempt to index a nil value (global 'playr')
   30 |   local h = playr.health
      |             ^^^^^
  hint: no global 'playr' exists; did you mean 'player'?
stack traceback:
  quests/intro.vxs:30: in function 'on_tick'
  quests/intro.vxs:41: in main module
```

Messages are Lua's where Lua has one, naming what failed as Lua does (`local 'x'`,
`global 'x'`, `field 'x'`, `upvalue 'x'`, `method 'x'`, `constant 'x'`). Common mistakes have
hints: `!=`, `&&`, `||` and `!` from other languages, `=` in a condition, `else if` leaving an
`if` unclosed, braces as a block, `then`/`do` missing or swapped, unfinished strings, a
misspelt global, field or method ("did you mean ...?"). Only the first syntax error is
reported. A limit fault reads `limit exceeded: ...` with the limit and the usual fix.

## Tools

`./build.sh script run <file> [--slice N] [--memory N] [--instructions N] [--trace]
[--disasm]` runs a script, resuming it after each slice (`--instructions 0`: no limit on
the run; `--trace` writes every instruction executed, with the register it set, and the
calls of natives, suspensions, errors and collector steps to stderr);
`./build.sh script disasm <file>` lists its bytecode, one block per function.

`./build.sh bench script [-check] [--smoke] [--lua <exe>]` (also `./build.sh script bench`)
runs the benchmark programs of `common/script/testdata/bench` and, with `--lua`, the same
programs under that Lua 5.4, printing the ratios; `./build.sh script conform --lua <exe>`
runs the conformance files marked `--! lua` under both and compares what they print.
