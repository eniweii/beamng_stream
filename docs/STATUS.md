# Status

## Built
- Prep tool (Python): reads line-delimited `items.level.json` files, moves streamable `TSStatic`
  records into whole-section files, writes patched items copies without them, verifies the
  accounting, never modifies the source. Tkinter studio over the same builder (restyle pending).
- Manager: all 32 instance flags parsed, draw-gate flags applied, emitters/lights with On/Off radios (legacy scene streamer retired). Fidelity notes: `docs/FIDELITY.md`.
- Collision policy extension (off / settled, timed refreshes) kept apart from rendering.
- Streamer, manager and panel as engine extensions in `lua/ge/extensions/nfsc/`; offline Lua tests
  run against the builder's real output (`tests/test_lua_modules.py`).
- Architecture, interface and diagnostics: `docs/ARCHITECTURE.md`.

- Queue: bounded feeding from pending lists, stale purge on section change, terrain-first and
  shapeName-grouped load order, create filter used by the manager for override objects.
- Look-ahead switch to the predicted section, heading-based load order and timing counters
  (see ARCHITECTURE). Not validated in BeamNG: read the `settled` log lines and `getStatus()` timings
  first to see whether queue order or TSStatic creation is the bottleneck.
- Builder: objects named or shaped SKYDOME / SKYDOME_XENON / SKY_SPECULAR are written with `isRenderEnabled`
  false.

## Not validated yet
- Everything inside BeamNG (see the list at the end of `docs/ARCHITECTURE.md`).
- Tkinter on the user's desktop.
- Collision and memory behaviour of created/deleted objects.

## Open
- Measure collision refresh cost in game; Hyperlinked / MW decomp fidelity comparison.
- Depth sections (overpass/tunnel variants) in `sections.json` and the lookup.
- Studio UI restyle.
- `lua/ge/extensions/nfscSectionStreamPrototype.lua` is superseded and can be removed by hand.
- Animated objects (`_anim.dae`, sections 2400/2600): the invisible cause was the manager hiding
  `ExcludeDisableRendering` objects (fixed). If they still vanish in game, the next candidate is
  frustum culling of a small bounding box: export a material-less box spanning the animation.
- `ExcludeGroupDisable` still starts hidden; its meaning is unconfirmed.
- 0008: shared frame budget (deletes first, creates get the rest), one new shape per frame, per-change
  timing and per-create cost split in the settled log. Defaults now `frameBudgetMs = 16`,
  `maxCreatesPerFrame = 16`, `maxDeletesPerFrame = 256` (the values tested in game). Shape warming one
  boundary ahead is NOT built: it needs the cost split and a check that BeamNG keeps a shape loaded
  after its last instance is deleted.
- 0009: creates classified as first use / reload / warm (live-instance count per shape), top 5 shapes
  per settled change, new-shape deferral based on recent first-use cost. Instrumentation to decide
  between "heavy shapes" and "shape freed on last delete" as the cause of the 5-8 ms registerObject
  cost seen in the tunnel transition (section 128). No behaviour change besides the deferral estimate.
- 0010: finds what makes registerObject slow (3-10 ms per object in game). Separate name-check timing,
  scene trend and idle frame time in the settled log, `skipNameLookup` switch, `probeRegister()` console
  probe. Instrumentation only; defaults unchanged. Findings so far: reloads are rare (not the cause),
  cost is per instance and varies by shape and section.
- 0010c: the registerObject probe runs by itself at the end of every settled change (`probeOnSettle`),
  compares itself with the real cost of the most-created shape, and flags refused registers.
- 0011: first-use cap 3, refused registers count as failures, probe with real fields and position,
  warm-create cost by camera distance, lights/emitters state in the settled block. Open question it
  answers: why real objects cost 0.5-2 ms (sometimes 4 ms) while a bare probe costs 0.01-0.1 ms.
- 0012: skip-ahead in the load queue (urgent lane for the camera's section and the streamed one,
  promotion on section change). Neighbour-section terrain no longer goes before the current section's
  rest; `currentSectionFirst = false` restores the old order for comparison.
- 0014: first use split into import (no `.cdae` yet) / cached / unknown, a log line for any single
  create over `stallLogMs`, peak frame work in the settled header, no settled block for changes that
  created nothing (`logEmptySettles`), and the idle shape cache warm-up lane (`cacheWarm`, builder
  writes `shapes.json`). Last streamer patch: what is left is tuning `frameBudgetMs` and the warm-up
  settings in game.
- 0015: creation methods. `creationMode = "current"` (create and delete every object, unchanged) or
  `"shells"`: a released object is parked (tiny `shellShape`, hidden, free list) and the next load
  fills a parked shell in (shapeName, all item fields, one `postApply`, unhide; fields the previous item
  set and the new one lacks go back to the engine default). With no parked shell left the object is
  created the current way and joins the pool when released. `shellTarget` builds parked shells ahead in
  the background (only while the urgent queue is empty). Switch in the manager panel or with
  `setCreationMode`. Probe results (console probe, not in the repo): a registered TSStatic needs a
  shape (empty ones are refused); retarget of a parked shell about 0.005-0.04 ms against 0.5 ms (idle)
  to 2.6 ms (spread over frames) for a fresh create; 20000 hidden shells cost about 1.7-2.5 ms per
  frame in one idle sample, so keep `shellTarget` near the real peak of live objects. Not validated in
  a long drive: compare the two modes on the same camera track (settled log has a `shells:` line).
  Level asset: `examples/NFSC_DOT.dae` goes to `levels/nfsc/Assets/Meshes/`.
- 0016: third creation method `"resident"` (shells plus a resting state, like the game's LOADED section): an
  unwanted object is deactivated at once (hidden, still bound to its key with shape and fields, no field
  writes), wanting it again revives it (unhide only), and only when the pool is at `residentMax` the oldest
  resting object is evicted and its shell reused; `residentReserve` keeps free shells ready by evicting in idle
  frames. Live tuning: sliders and checkboxes in the manager panel (applied at once through `setTuning`),
  presets (`startup`, A, B, C) saved in `lua/carbon_stream/tuning_presets.json` (`startup` is applied at
  initialize), `resetTuning`, `printTuning`. Dropped sections: a section change that happens before the
  previous one settled is logged (`dropped section <id>: left after ...`), counted in the panel and in
  `getStatus` (`droppedSections`, `droppedObjects`, `droppedLast`). Not validated in game. Still pending:
  the camera track and the comparison of the three modes (see HANDOFF_STREAMER_PERF.md, "Next conversation").
- 0016b: fix for 0016. `sectionStreamer.lua` did not load in the game ("function at line 1420 has more than
  60 upvalues": LuaJIT's limit, `resetState` had 68). The pool, resting and dropped-section state is now reset in
  its own function (`resetPoolState`, resetState is at 52). The tests now run under LuaJIT 2.1 by default
  (`tests/run_lua_tests_lupa.py`, `--lua54` for the other one), a Python test compiles every Lua file under
  LuaJIT, and a Lua test fails when any function gets above 56 upvalues. New module-level state belongs in a
  table or in a helper function, not in more locals read by the big functions.
