# Sound zones (nfsc_soundZones)

Builds tunnel, overpass and garage ambience spaces at level load from `levels/nfsc/lua/zones.json`
(next to `sections.json`). Nothing runs per frame: each zone becomes one or more `SFXSpace` boxes and the engine
does the enter / exit detection.

| Zone type | Ambience |
|---|---|
| TUNNEL | `Level_Tunnel_Closed` |
| OVERPASS | `Level_Under_Bridge` |
| OVERPASS_SMALL | `Level_Under_Bridge_A` |
| GARAGE | `Level_Parking_House` |

- Polygon to boxes: smallest oriented rectangle per polygon; a rectangle that is mostly empty is cut across its
  long axis and the halves are fitted again (fill target 0.75, at most 24 boxes per zone).
- Height: a zone has no height of its own. A box spans `zMin..zMax` (-500..2000 in the file's tuning) narrowed by the
  zone's elevation gate (> 0: from that z up, < 0: up to |z|), then raised by `zOffset` (150: every object of the level
  sits 150 higher than in the game; x and y are not offset).
- `lua/sound_zones.json` (optional) changes the mapping: `{"roles": {"TUNNEL": "Level_Tunnel_Open"}, "zones": {"145": false}, "zOffset": 150}`
  (`false` switches a role or one zone off; zone ids are the ids of `zones.json`).
- Not verified in BeamNG yet: the `SFXSpace` fields set through `setField` (`soundAmbience`, `position`,
  `rotationMatrix`, `scale`) and that the ambience names resolve. `getStatus()` reports counts and ambiences not found.
- Test: `python tests/run_sound_zones_lupa.py`.
