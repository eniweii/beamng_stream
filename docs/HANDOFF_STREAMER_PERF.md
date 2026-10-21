# Handoff: section streamer performance work (patches 0007 - 0012)

State of the repo after patch 0012. Everything below was measured in game by the maintainer
(free camera, no collision, game locked at 30 fps, Section Manager lights and emitters off).
Nothing here was run in BeamNG by the assistant; offline it only runs the Lua tests
(`python tests/run_lua_tests_lupa.py`, 220 passing, needs `pip install lupa`).

## How the work is organised
- Code: `lua/ge/extensions/nfsc/sectionStreamer.lua` (queues, budget, timing, probe) and
  `sectionManager.lua` (UI, scene switches). Tests: `tests/lua/test_sections.lua`, `harness.lua`.
- The maintainer applies patches, builds and tests locally. Patches are based on the state he last
  applied (he names it), never contain file deletions, and he wants changed files presented as
  cards plus a git patch. Plan first, confirm, then code. Concise answers, cause and effect.

## Patch history
| Patch | What it does |
|---|---|
| 0007 | create timing counters (average, first use vs repeat, max, section read) |
| 0008 | one frame budget (deletes first, creates get the rest), one new shape per frame, per-change timing and the three-line settled log |
| 0009 | creates split into first use / reload / warm (live instance count per shape), top 5 shapes per change, new-shape deferral uses a moving average of recent first-use cost |
| 0010 / b / c | name check timed separately, `scene:` line (live count trend, idle frame), `skipNameLookup`, `probeRegister()` console probe, probe logs every call, probe runs by itself after each settle, refused registers flagged |
| 0011 | `maxFirstUsePerFrame` default 3, a refused `registerObject` counts as a failure, `probe real` pass (real fields and position), warm creates by camera distance, lights/emitters state in the log, `getTuning()` |
| 0012 | skip-ahead: urgent queue lane for the camera's section and the streamed one, promotion on section change |

Defaults now: `frameBudgetMs 16`, `maxCreatesPerFrame 16`, `maxDeletesPerFrame 256`,
`deleteBudgetShare 0.25`, `maxFirstUsePerFrame 3`, `firstUseGuessMs 6`, `currentSectionFirst true`,
`probeOnSettle true`, `probeCount 20`, `skipNameLookup false`. `setTuning` values are not saved
across restarts.

## Reading the log
A settled change prints: a header (objects, seconds, objects/s, frames, fps while loading, worst
frame, streaming ms per frame); `creates:` (total, average, max; first use / reload / warm counts and
averages; how often a new shape was deferred); five `top N:` shapes; `per create:` split; `scene:`
(live objects, `registerObject` trend per 1000 live, idle frame); warm creates by distance with the
lights/emitters state; then the probe lines. A "section N: x queued objects ... moved ahead" line is
written at a section change when skip-ahead promoted queued objects. Settled blocks only print when
both queues are empty, so a change the camera leaves early prints nothing (its counters are reset).

## Findings
Settled (with evidence):
- Loading is not limited by the budget any more. With cap 3, 613 first uses in section 309 took
  304 frames. First use is 94-97% of create time in a fast session (section 1430: 505 x 4.75 ms of
  2481 ms; section 309: 613 x 3.72 ms of 2421 ms).
- Not the cause of slow creates: name lookup (0.00 ms), group add (0.00-0.01 ms), `createObject` and
  `setField` (0.01-0.05 ms), live object count (the trend flips sign between -42 and +21 ms per 1000),
  distance to the camera (buckets within 0.1-0.4 ms of each other), lights and emitters (off the
  whole time), reloads (4-10% of creates, 3-7 ms each).
- The same shape costs very different amounts at different moments: `XBU_AUTOZONE_1A_00` first use
  14-19 ms in fast states against 90 ms in a slow one; `XOU_FENCE4LONDONA_1A_00.001` warm 0.08-0.10
  ms against 1.47 ms.
- Two states: fast (warm 0.06-0.3 ms, first use 3-5 ms) and slow (warm 1.0-3.0 ms, first use 13-23
  ms). Sessions start fast about two thirds of the time (first warm averages 0.06-0.27 ms in
  six sessions, 1.05-1.33 ms in three). A session can flip either way. Sections do not decide it:
  section 309 was 0.07 ms in one session and 2.19 ms in another.
- The probe is cheap in every state: bare named 0.01-0.5 ms, `probe real` (same fields, position and
  create path as a real object) 0.00-0.05 ms, e.g. section 109 (slow state): real avg 2.51 ms,
  `probe real` 0.04 ms, same shape, taken at settle. So object, position and shape are not the cost.
  The difference is the moment: creates that run during streaming are expensive in the slow state,
  the same create when idle is not.

Open:
- Why the state flips. Best current guess (not verified): `registerObject` waits on something the
  render side or loader is busy with while streaming runs. Cheap tests below.
- Single hitches: first use of large building shapes (`XBU_*`, 30-140 ms) and `_anim` shapes
  (`XOU_TOWERCRANEARMA_1A_00.006_anim` 1782 ms once, 356 ms another time). Worst frames of the first
  load after every restart were 169-185 ms; steady loads 34-46 ms.
- The unnamed bare probe pass reads 0.00 ms with no FAILED flag; unexplained, treat as unreliable.

## 0012 run (skip-ahead, roaming)
- First load, section 309: 2735 objects in 14.55 s (188/s), 304 frames, 20.8 fps, worst frame 177
  ms, 8.4 ms streaming per frame; warm 0.07 ms, distance buckets 0.06-0.07 ms; probe real 0.01 ms.
- Roaming (50 s): 20 "moved ahead" lines for 11 sections, 3 to 476 queued objects each, 2712
  in total. Sections 103, 102, 138, 120, 108 and 124 were entered two to four times within seconds
  (124 four times in 3 s): the current section flips back and forth, and each flip re-sorts the queue.
- No failures. Only section 109 settled: 1071 objects in 6.87 s (156/s), 29.0 fps, worst frame 39
  ms, streaming 16.8 ms per frame; slow state again (warm 2.66 ms, first use 13.45 ms, 42 reloads at
  5.27 ms); probe real 0.04 ms.
- Not measurable from this log: whether the section the camera ended up in loaded faster, and what
  the re-sort costs (no frame spike is visible in section 109, worst frame 39 ms).

## Suggested next steps (none built)
1. Cheap tests, no patch: load a slow-state section twice, once looking at the sky and once at a
   dense street, and compare warm averages (render contention). Try `maxCreatesPerFrame` 2-4 and
   `frameBudgetMs` 8 against 16 in a slow state.
2. Probe during streaming: run the `probe real` pass in the middle of a load (a few objects, right
   after real creates) to see whether the same create gets expensive only under streaming load.
3. Log a line at every section change (objects created since the last change, both queue sizes) and the
   time until the camera section's objects are all live, so skip-ahead can be judged in roaming.
4. Section flip-flop: log whether a change came from the camera or from the prediction; consider
   hysteresis if the flips are prediction.
5. Export side: find and prune or replace `_anim` shapes with multi-hundred ms first use; the
   heaviest building shapes are the remaining frame hitches.

## Preloading shapes (assessment, not measured)
The maintainer tried preloading and saw little change. The numbers say that is expected:
- First use is the dominant create cost (94-97% in fast sessions), but the shape load is synchronous
  inside `createObject`, so preloading moves the cost, it does not remove it. It only helps if it
  runs when the game is idle, one shape per frame, and the shape stays loaded until needed.
- Shapes do get freed (reloads cost 3-7 ms against 0.1-2 ms warm), so a preload needs a held
  instance per shape, otherwise the work is thrown away.
- Roaming leaves almost no idle time, and the game is locked at 30 fps: steady-load worst frames are
  36-46 ms against a 33 ms floor, so the possible gain is a few ms per hitch.
- The slow state's warm cost (1-3 ms) is not shape loading at all (the probe is cheap), so preloading
  cannot touch it.
Verdict: hold off. If frame hitches become the priority, preload only heavy shapes (first use over
about 10 ms, taken from the `top N:` lines), one per frame, during idle frames, with a held instance.
A lookup table of shape names would add little: the section data already lists them, the cost is the
engine load.
