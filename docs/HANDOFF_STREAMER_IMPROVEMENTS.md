# Streamer improvements - handoff (2026-11-17)

Work list for `nfsc_sectionStreamer`, from a read of this repo and the BeamNG Lua atlas
(https://github.com/Tim0219800/beamng-lua-atlas, docs for 0.40.5), checked against the settled rules below.
Nothing here is built yet. Plan each item first and confirm it before any code.

## Where things live (after the split)
`lua/ge/extensions/nfsc/sectionStreamer.lua` is the facade (public API, initialize / reset / purge, listeners, `onUpdate`).
Parts in `lua/ge/extensions/nfsc/sectionStreamer/`, loaded with `loadfile` into one shared environment (former file-level
locals are shared names): `stall`, `tuning`, `state`, `sectionIndex`, `objects`, `pool`, `queues`, `camera`, `shapeCache`,
`diagnostics`. Details: `docs/ARCHITECTURE.md`.

## Items, in the order they will be done

### Patch A - small, low risk
1. **Log `pcall` failures** (`objects`, `diagnostics`). Nearly every engine call (`setField`, `postApply`, `registerObject`,
   `delete`) is wrapped in `pcall` and the result dropped, so a failing call is invisible. Add a Debug setting that logs the first
   failure per call site and counts them per site in the stats window.
2. **Streamer `onSerialize` / `onDeserialized`** (facade). `levelHost` and `sectionManager` have them, the streamer does not, and
   `onExtensionUnloaded` deletes all objects, so a Lua reload restarts it cold. Keep the settings and the current section across a
   reload; the warm cursor is rebuilt.
3. **Cheaper section lookup** (`sectionIndex`). `findSection` scans every section; outside all of them it measures the distance to
   every polygon edge. Test the current section and its related list first, then a grid index from the polygon bounds. Use
   `core_camera.getPositionXYZ` instead of `getPosition` (no table allocation).

### Patch B - object pool (`pool`, `objects`)
4. **Shape-aware free shells.** Parked shells are reset to the dot shape, but shells evicted from the dormant pool keep their old
   shape. Index free shells by the shape they wear; `acquireShell` takes one that already wears the needed shape and skips the
   `shapeName` write, otherwise prefers a dot shell so shaped shells stay available. Keep the index in sync on park, evict, acquire,
   purge, reset and when the engine loses an object. Check the existing recycle / retarget stats first: the gain depends on how
   often evicted shells are reused. Reference numbers from `HANDOFF_STREAMER_PERF.md`: about 0.137 ms per warm refill, 5.1 ms cold.
5. **Skip unchanged field writes.** `shellFields` stores field names only. Store the applied text values and call `setField` only
   when the value changed (still reset fields the previous item had and the new one has not). Positions and rotations always
   differ, so the gain is modest; add a "skipped" counter next to the `field-application` timing to see it. Formatting cost stays
   unless the formatted strings are cached per item (a memory trade-off, not planned).
6. **`updateInstanceRenderData` after unhide / retarget**, behind a Debug toggle, default off until tested in game. The game's own
   show/hide flowgraph node and the kit placer call it; the streamer never does, and its objects use `useInstanceRenderData`. May
   relate to the open item "animated objects do not play after a reload".

### Patch C - frame budget (facade, `tuning`)
7. **Adaptive frame budget**, setting "Adaptive frame budget", default off. The fixed 16 ms budget (presets A / B / C) shrinks when
   the measured frame time is over a target and grows with headroom, using `idleFrameMs` and `dtReal` that are already tracked.
   Presets become the ceiling; the Section Manager shows the effective value.

## Waiting
- **Memory provider for the RAM floor.** Nothing calls `M.setMemoryProvider`, so the RAM floor never compares anything. The game's
  memory tracker (atlas: `telemetry_trackers_memory`) reads `Engine.Platform.getMemoryInfo`. Needs the output of
  `dump(Engine.Platform.getMemoryInfo())` (and `dump(Engine.Render.getVRAMUsage())` if VRAM should count) from the in-game console
  before mapping it to `freeGB`, `availableGB`, `processGB`.
- **Direct transform setters** (`setPosRot`, `setTransform`, `setScale`): he decides later. They conflict with the rule that
  transforms are applied exactly as exported (rotationEuler text, negative scales, no conversion).
- **Prediction for TrackPathZones**: zones come in as `zones.json`; prediction / look-ahead becomes a `streamer_prediction`
  component on top of them.

## Looked at and not planned
Precomputed shape index in the pack builder (the prebuilt index was rolled back; shapes are assigned at runtime and nothing extra
is maintained). Native `Sim.deserialize*` loading (the cost is `registerObject` and mesh loading, and it would bypass pooling).
`core_jobsystem` (a coroutine scheduler on the main thread; it only spreads Lua work, it does not make a call asynchronous).
Predictive shape warming now (waits for the prediction component). An idle-frame audit (about 0.08 ms already).

## Rules for this work
- Plan first, he confirms, then code. New code keeps the style of the surrounding code.
- Settings are named by their Section Manager label when he is asked to change one.
- Patches are based on the state he last applied (he names the patch), contain no file deletions, and are delivered with the
  changed files. He applies, builds and tests locally; the camera track is run in game only.
- Atlas lookups: clone the atlas with `git clone --depth 1`; `doc/0.40.5/cpp.md` and `stubs/0.40.5/cpp/` for engine classes,
  `doc/0.40.5/ge/extensions/...` for Lua modules.

## Tests
`python tests/run_lua_tests_lupa.py` with `--stacked`, `--host` and `--env` (needs `pip install lupa`).
Known at this baseline: the default `test_sections.lua` fails its first checks and then stops, because it looks objects up by
name while the streamer creates unnamed pooled shells; the three other runs pass (17, 40 and 45). The split was checked with a
trace comparison: the old single file and the split streamer driven through the same scripted camera path in all creation modes,
with a deterministic `os.clock`, comparing status, counters and created objects every tick (identical), and with deliberately
broken copies to make sure the comparison notices.
