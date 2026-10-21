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

