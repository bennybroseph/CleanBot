# CleanBot unit tests

Offline unit tests for the addon's **pure logic** (parsing, protocol, state machines) — the
parts that don't need the live WoW client. They run under a bare Lua 5.1 / LuaJIT interpreter
against a minimal mock of the WoW API, so they're fast and CI-friendly.

UI/frame behavior (rendering, layout, real frame methods) is **out of scope** here — that's
verified in-game. The mock only stubs enough of the client API for the logic files to load.

## Running locally

From the addon root, with a Lua 5.1 interpreter. LuaJIT (Lua 5.1-compatible, matches the
client) installs via `winget install DEVCOM.LuaJIT`:

```
"C:\Users\<you>\AppData\Local\Programs\LuaJIT\bin\luajit.exe" spec/run.lua
```

(or `lua spec/run.lua` if a `lua` 5.1 binary is on PATH). A passing run prints
`N passed, 0 failed` and exits 0; any failure exits non-zero.

## Layout

- `wow_mock.lua` — minimal WoW API mock (frame stub, string aliases, namespace seed).
  Extend it as new specs need more of the API.
- `framework.lua` — tiny [busted](https://lunarmodules.github.io/busted/)-style harness
  (`describe` / `it` / `assert.*`). Specs are written busted-style so they can migrate to
  real busted later with no changes.
- `run.lua` — entry point; loads the mock, harness, and each spec. **Register new spec files
  here.**
- `*_spec.lua` — the tests. A spec `dofile`s the addon file under test, then asserts.

## CI

`.github/workflows/test.yml` runs `lua spec/run.lua` on every push/PR that touches `.lua`
files, using PUC Lua 5.1 (the harness is dependency-free, so no LuaRocks/busted install).

## Caveat: load-time side effects

Each addon file creates frames / registers events at load (e.g. `CreateFrame("Frame")`,
dropdown menus). A spec must `dofile` the whole file, so the mock has to be complete enough
for that file to *load*. The cleanest way to widen coverage is to keep pure logic in
side-effect-free helpers that the spec can exercise directly.
