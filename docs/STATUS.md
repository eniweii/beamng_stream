# Prototype status

## Included

- A standard-library Tkinter desktop UI with file/folder selection, input analysis, section preview, build log and staging output controls.
- A source-safe builder that reads one JSON object per non-empty line, supports one item file or a full folder tree, and never modifies source files.
- The current camera-driven section streamer with on-demand section chunks, bounded create/delete work and cooldown.
- Runtime handling for the sample export's `rotationEuler` array as well as quaternion `rotation` records.
- Synthetic Python tests exercising section extraction, source immutability, multi-section records and raw-line preservation.

## Not validated yet

- Launching Tkinter on the user's Windows desktop.
- Lua execution inside BeamNG.drive.
- Visual orientation for all exported Euler and negative-scale combinations.
- Actual shape/texture memory eviction.
- Collision parity: visual-only mode disables streamed collision and decals.
