# Handoff: section streamer performance (state after patch 0020)

Written for the next session (the assistant that continues this work). Everything measured here was measured in game by the
maintainer; the assistant only runs the offline tests (`python tests/run_lua_tests_lupa.py`, LuaJIT 2.1 through `pip install lupa`,
553 checks) and `python -m unittest discover -s tests`. Nothing has been run in BeamNG by the assistant.

## Working rules (from the maintainer)
- Plan first, confirm, then code. Concise answers, cause and effect, no long walls of text.
- Patches are based on the state he last applied (he names it), never contain file deletions, and every code task ends with the
  changed files presented as cards plus a git patch. No diffs in chat.
- When asking him to change a setting, use the name shown in the Section Manager UI (the label), not the internal variable name.
  Labels live in the `SCHEMA` table of `sectionStreamer.lua`.
- Pasted research from other AIs is input only: cross-check it against the decisions below.
- Lua limits that bit before: 60 upvalues per function (a test fails above 56) and 200 local variables in the main chunk (about
  197 are used: keep new state and helpers in tables, like `run` and `hold`).
- Patch trail: 0015 shell pool, 0016 resident mode, 0017 tuning/purge, 0018 same-shape reuse, 0019 run statistics and cost
  classes, 0020 everything-is-warm mode. 0018 was the last one he named as applied; his logs show 0019.

## Architecture in one screen
`lua/ge/extensions/nfsc/sectionStreamer.lua` (queues, budget, pools, tuning schema), `sectionManager.lua` (+ `sectionManagerUi.lua`,
the panel), `sectionCollision.lua`. Tests: `tests/lua/test_sections.lua` + `harness.lua`.
Creation modes: `current` (create/delete), `shells` (recycled shell pool, shells wear the tiny dot shape), `resident` (shells plus a
resting state). The camera track is run in game only and is not in the repo.

### Object lifecycle in resident mode
| State | Hidden | Key | Shape worn | Leaving cost |
|---|---|---|---|---|
| Live | no | yes | own | deactivate = hide, ~0.01 ms |
| Dormant | yes | yes (old key) | own, fields kept | revive same key ~0.006 ms; same-shape reuse for another key ~0.03 ms |
| Free, parked | yes | no | the dot | refill = `shapeName` retarget (cost depends on whether the mesh is held) |
| Free, evicted | yes | no | OLD shape kept | same refill path; NOT indexed by shape yet |
| Fresh | | | | `createObject` + `registerObject`, 0.5-2.6 ms (pool empty only) |
Dormants are evicted to the free list only when the pool is over `Pool size` (the setting; `residentMax` in code) and the idle trim keeps
`Free reserve` shells free. With a 30000-shell pool and a smaller `Pool size` the pool total is always above the cap, so the trim
evicts every dormant.

### Shape residency (separate axis)
The engine frees a mesh once nothing wears it (his observation, confirmed by lap 3). A shell on the dot holds nothing; a shell
that still wears its old shape (dormant, or evicted-free) holds it. Mesh loads: held ~0 ms, reload from `.cdae` ~1.3 ms, first
ever import ~5 ms or more (up to 400 ms for big shapes).

## Camera-track method and run summary
Purge (full wipe; Release pool and Hold as he sets them), let the section settle, run the track until it loops, press
**Log run summary** (or `nfsc_sectionStreamer.logRunSummary()`), send only that block (the full log is ~500k characters).
The block gives creates per path (revive, same-shape reuse, refill, fresh, plain), busy and idle streamer frames and the share of
frames asleep, time to idle per section, dropped sections, per-frame cap hits, and whether everything-warm was on.

### Results so far (same track, ~44-46k creates, resident mode)
| Lap | Refills | Time to idle avg / longest | Asleep | Dropped sections |
|---|---|---|---|---|
| 1 cold (Release pool + Hold) | 16737 x 5.1 ms | 1.65 s / 25.6 s | 87% | 13 (7545 objects) |
| 2 warm pool, no purge | 257 x 5.3 ms | 0.03 s / 0.62 s | 98% | 2 |
| 3 Release pool | 10448 x 1.27 ms (+6509 fresh x 2.44 ms) | 0.38 s / 8.06 s | 0% (pool rebuilt) | 4 |
| 4 `Pool size` 4200, pool 30000, meshes warm | 30550 x 0.137 ms | 0.06 s / 2.75 s | 48% | 1 (0 objects) |
Reading: cheap paths (revive, same-shape reuse) cost 0.6 s in total over a lap; nearly all create time is shape changes. Lap 4 was
cheap because 26856 free shells still wore their old shapes, so most retargets hit a held mesh. The highway was evicted first and
its recreation cost a reload spike (max 24 ms, 2.75 s settle). Memory is not the constraint: more than 6 GB stayed free on his
32 GB machine in all runs (all 29,534 meshes are about 1.8 GB).

## Roadmap (nothing below is built unless stated)
1. DONE 0019: per-transition counters, run summary, separate caps for cheap reuses (`Max cheap reuses per frame`) and refills
   (`Max refills per frame`); the queue stays in order, a capped class stops the frame's creates at the head.
2. DONE 0020: Everything is warm (below), to compare all modes on object cost only.
3. Index evicted-free shells by shape, so a refill first looks for a free shell already wearing the requested shape (no shape
   change, ~0.03 ms), and count them as shape holders in the bookkeeping.
4. Choose which free shell to retarget: now last-in-first-out, i.e. the newest evicted (recently used, e.g. the highway) goes first;
   prefer a shell whose old shape has other holders, or the one free longest.
5. Diff-based field writes on same-shape reuse (keep applied values, not only field names): most fields repeat between instances.
6. Idle audit: when nothing is queued `onUpdate` should do almost nothing; the measured idle frame is ~0.08 ms.
7. True small-pool lap: Purge with Release pool, then `Shells built ahead` and `Pool size` both near 1.2 x peak live (~4200), pool
   built first. Lap 4 did not test that (see the lifecycle note).
8. Pool ready before play: the build-ahead lane keeps every frame busy while the pool fills (0% asleep in lap 3).
Look-ahead/prediction waits until the zones are moved to BeamNG. Collision stays deferred.

## Everything is warm (patch 0020)
Purpose: a test mode. All meshes (not objects) are loaded and stay loaded, so a run of any creation mode (`current`, `shells`,
`resident`) measures only object work: `registerObject`, field writes, hide/unhide, shell retargets, with no mesh loads or imports.
How it works: the lane holds every shape of `shapes.json` (the builder output, ~30k) with one hidden TSStatic each (collision none,
no decal, below the camera), in its own group `NFSC_WarmMeshes`, outside the shell pool, the live counts and the purge check.
It runs while nothing is queued (after `Idle before it starts (s)`), `Meshes held per frame` shapes per frame within
`Frame share for holding` of the frame budget; a first import can stall longer. Holding imports shapes without a `.cdae`, so the
cache warm lane stands down while the mode is on. Held shapes count as warm in the settled log (no first use, no reload).
- On/off: the Tuning option **Everything is warm** (group of the same name). Off releases the holders in batches of 512 per frame.
- Panel line: `Everything is warm: filling/ON/releasing, N of M meshes held (avg, max ms)`. Console: `getWarmAllStatus()`,
  `setWarmAll(true|false)`.
- Survives: Purge (with or without Release pool), Reload streamed scenery, creation-mode switches, Reset statistics. Dropped by
  initialize and extension unload.
- Run summary line: `everything warm: ON, N of M meshes held` (or `(NOT complete)`, or `off`): a lap run before it completed is
  not a warm lap.
- Cost to remember: ~30k extra hidden objects cost the engine a little every frame (earlier probe: 20k about +1.7-2.5 ms), the same in
  every mode, so compare modes against each other, not against a run without the mode. Registering them costs about 30k x 1-2 ms
  of main-thread time once.
How to use it: start the mode standing still, wait for the panel line to say ON, then run the camera track per mode:
`current`, `shells` (`Shells built ahead` 0 and near peak live), `resident` (`Pool size` 30000 and ~4200), each after Purge, and compare the run
summaries (creates per path, time to idle, dropped sections). Same track, same settings except the one under test.
Open question for the first run: whether `shapeName` retargets onto a held mesh really cost ~0.03-0.14 ms (lap 4 suggests it).

## Earlier findings still valid (patches 0007-0014, shells era)
- First use of a shape dominated create time (94-97% in fast sessions); the shape load is synchronous inside `registerObject`.
- The probe is cheap in every state (0.01-0.5 ms), so object, position and shape are not the cost; the moment is (during streaming).
- Fast and slow session states existed (warm 0.06-0.3 ms vs 1-3 ms); the cause was never found.
- Heavy hitches: `_anim` shapes and the big `XBU_*` buildings (30-4500 ms first use, a `.cdae` build then cache reads).
- The cache warm lane (idle imports of shapes without `.cdae`, `shapes.json` from the builder) is unverified for `FS:fileExists` on
  the `.cdae` path; the first-use split in the settled log shows `unknown` if it is not usable.
- Preloading by create-and-delete only moves the cost; a mesh stays loaded only while some object wears it (the reason for the
  holders in 0020).

## Async / C++ hook (future)
The maintainer may bring research on an asynchronous path through a C++ hook. Collada import and `registerObject` are
synchronous on the main thread today; no async path was found. Cross-check any research against the decisions above before
building on it.
