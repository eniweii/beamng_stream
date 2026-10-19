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

## Not validated yet
- Everything inside BeamNG (see the list at the end of `docs/ARCHITECTURE.md`).
- Tkinter on the user's desktop.
- Collision and memory behaviour of created/deleted objects.

## Open
- Measure collision refresh cost in game; Hyperlinked / MW decomp fidelity comparison.
- Depth sections (overpass/tunnel variants) in `sections.json` and the lookup.
- Studio UI restyle.
- `lua/ge/extensions/nfscSectionStreamPrototype.lua` is superseded and can be removed by hand.
