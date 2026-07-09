# macOS Port Bugfix Traceability

This note documents four macOS/runtime bugs found while testing the Red Alert
port with the original campaign assets. It is intended as PR context for
maintainers and as a future debugging breadcrumb.

## 1. Animation Pool Exhaustion Crash

### Symptom

The game crashed during early gameplay after enough animations were created.

### Traceability

- Allocation path: `CODE/ANIM.CPP`, `AnimClass::operator new`
- Declaration path: `CODE/ANIM.H`, `AnimClass::operator new`
- Pool allocator: `Anims.Allocate()`
- Regression check: `tests/run_script_tests.sh`

### Root Cause

`AnimClass::operator new(size_t)` can return `NULL` when the fixed animation
pool is exhausted. With the modern Clang C++ ABI, a custom `operator new`
without a non-throwing exception specification still allows construction to
proceed after a null return. That means the `AnimClass` constructor can run with
`this == NULL`, which crashes instead of gracefully skipping the animation.

### Fix

Declare and define `AnimClass::operator new(size_t) throw()` so null returns
preserve the original non-throwing allocation behavior and skip construction.

Changed files:

- `CODE/ANIM.H`
- `CODE/ANIM.CPP`
- `tests/run_script_tests.sh`

## 2. Invalid Speech ID Crash

### Symptom

The game later crashed in speech playback. The macOS crash report showed the
failure path reaching `_makepath()` from `Speak_AI()`, with an invalid speech
table entry being used to construct the speech filename.

### Traceability

- Queue entry path: `CODE/AUDIO.CPP`, `Speak(VoxType voice)`
- Playback path: `CODE/AUDIO.CPP`, `Speak_AI()`
- Name lookup path: `CODE/AUDIO.CPP`, `Speech_Name(VoxType speech)`
- Data table: `CODE/AUDIO.CPP`, `Speech[VOX_COUNT]`
- Regression check: `tests/run_script_tests.sh`

### Root Cause

`SpeakQueue` could contain an invalid `VoxType`. `Speak_AI()` then indexed
`Speech[SpeakQueue]` without proving the value was in range. Once the invalid
value reached `_makepath()`, the filename pointer was not valid.

### Fix

Add a single speech ID validator and use it at all speech table boundaries:

- `Speech_Name()` returns `"none"` for invalid IDs.
- `Speak()` rejects invalid speech IDs before queueing them.
- `Speak_AI()` clears invalid queued IDs before indexing `Speech[]`.

Changed files:

- `CODE/AUDIO.CPP`
- `tests/run_script_tests.sh`

## 3. First Campaign Mission Reports Failure On Victory

### Symptom

Completing the first Allied campaign mission or first Soviet campaign mission
reported "mission failed" instead of mission completed.

### Traceability

- Scenario player setup: `CODE/SCENARIO.CPP`, `Read_Scenario_INI()`
- House enum values: `CODE/DEFINES.H`, `HousesType`
- Trigger action parsing: `CODE/TACTION.CPP`, `TActionClass::Read_INI()`
- Trigger event parsing: `CODE/TEVENT.CPP`, `TEventClass::Read_INI()`
- Win/loss decision path: `CODE/TACTION.CPP`, `TACTION_WIN` and `TACTION_LOSE`
- Regression check: `tests/run_script_tests.sh`

### Asset Evidence

The installed campaign data in `assets/redalert/*/MAIN.MIX` stores the first
mission trigger data using legacy low-byte house IDs with stale high bytes:

- Allied mission 1 has `Player=Greece`. The win trigger action stores house
  data as `-255`, whose low byte is `1`, matching `HOUSE_GREECE`.
- Soviet mission 1 has `Player=USSR`. The win trigger action stores house data
  as `-254`, whose low byte is `2`, matching `HOUSE_USSR`.

The same legacy representation appears across many house-typed campaign trigger
actions such as production, autocreate, fire sale, and all-to-hunt.

### Root Cause

The original trigger data relies on the house value occupying the low byte of a
union field. In this port, `TActionClass::Read_INI()` and
`TEventClass::Read_INI()` read the raw numeric field into `Data.Value`, then the
game later reads the same union as `Data.House`.

On modern builds, `HousesType` is read as a full enum value rather than just the
low byte. As a result, the first Allied win action compared `-255` against
`HOUSE_GREECE`, and the first Soviet win action compared `-254` against
`HOUSE_USSR`. Both comparisons failed, so `TACTION_WIN` incorrectly flagged the
player to lose.

### Fix

Normalize house-typed trigger data immediately after parsing:

- If a parsed house value is below `HOUSE_NONE`, recover its low byte.
- Accept the recovered value only when it maps to a valid `HousesType`.
- Apply this to house-typed trigger actions and trigger events.

Changed files:

- `CODE/TACTION.CPP`
- `CODE/TEVENT.CPP`
- `tests/run_script_tests.sh`

## 4. Map Selection WSA Animation Crash

### Symptom

After winning a campaign mission, the game crashed while entering the next-map
selection animation. The macOS crash report showed this path:

`Do_Win()` -> `Map_Selection()` -> `Animate_Frame()` -> `Apply_Delta()` ->
`Mem_Copy()` -> `_platform_memmove`

The register dump showed impossible patterned source, destination, and length
values for the copy.

### Traceability

- Win flow: `CODE/SCENARIO.CPP`, `Do_Win()`
- Map selection animation flow: `CODE/MAPSEL.CPP`, `Map_Selection()`
- WSA loader and decoder: `WIN32LIB/WSA/WSA.CPP`
- Crash site: `WIN32LIB/WSA/WSA.CPP`, `Apply_Delta()`
- Regression check: `tests/run_script_tests.sh`

### Root Cause

The WSA file format stores frame offsets as 32-bit little-endian values. The
port read those offsets through `unsigned long` fields and `unsigned long *`
resident-table casts. On macOS ARM64, `unsigned long` is 64-bit, so adjacent
32-bit frame offsets were combined into bogus 64-bit values. `Apply_Delta()`
then computed a huge unsigned frame size and passed it to `Mem_Copy()`.

The same loader also used native `unsigned long` width in the WSA file-header
layout and in the historical delta-buffer size adjustment. Those are file-format
values and must not change with the host ABI.

### Fix

Make the WSA on-disk layout explicit and validate deltas before copying:

- Use fixed-width `uint16_t`, `int16_t`, and `uint32_t` fields for the WSA file
  header.
- Size the WSA file header using `sizeof(uint32_t)`, not host
  `sizeof(unsigned long)`.
- Read resident frame offsets through an unaligned-safe 32-bit helper.
- Use the fixed legacy 37-byte ANIMATE header adjustment when converting the
  file's delta buffer size to this native in-memory layout.
- Preserve zero frame-offset sentinels when applying palette offsets in the
  disk-backed WSA path.
- Reject invalid offset order and frame data larger than the delta buffer before
  calling `Mem_Copy()`.
- Return failure for null animation handles before dereferencing them.

Changed files:

- `WIN32LIB/WSA/WSA.CPP`
- `tests/run_script_tests.sh`

## Verification

Automated checks:

```sh
tests/run_script_tests.sh
cmake --build build --target redalert_mac -j 8
scripts/run_mac_dev.sh --prepare-only --no-build
```

Manual checks:

- User replayed the campaign completion path after the parser fix and confirmed
  the mission no longer reports failure on victory.

Expected warnings:

- The current macOS build emits existing warnings around deprecated `sprintf`,
  non-portable include casing, and legacy template declarations. These warnings
  are not introduced by the fixes above.
