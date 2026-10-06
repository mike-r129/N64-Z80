# Measurements

Append-only log (PLAN.md §11): every performance or layout decision cites a
row here. Add new rows at the bottom; never edit old ones (supersede them
with a note instead).

Conventions:

- **ROM** is the testsuite ROM (`make`) unless noted; **where** is `ares`
  (v148, Windows, `tools/ares-run.ps1`) or `hw` (real console). ares timing
  is close to the console but not RDRAM-exact.
- Times come from COP0 Count (46.875 MHz). "cycles" are VR4300 CPU cycles
  (93.75 MHz = 2 × Count).
- The testsuite's code and data layout is not mvs64's, so its numbers compare
  cores and variants *within this ROM*. In-game numbers come from mvs64
  builds and say so.
- Correctness rows record the differential/ZEX status of the same build.

## Log

| Date | Commit | ROM / build | Where | Metric | Value |
|---|---|---|---|---|---|
| 2026-10-05 | 0dd4aef | testsuite, defaults (`ZDIFF_CASES=20000`, `ZEX_MAX_STEPS=5000000`) | ares | zdiff REF vs NEW (C vs C), 20,000 cases | 0 mismatches |
| 2026-10-05 | 0dd4aef | ″ | ares | zdiff REF vs NEW, direct-write filter, 5,000 cases | 0 mismatches |
| 2026-10-05 | 0dd4aef | ″ | ares | controls MUT1 / MUT2 / MUT3 / MUT4, 20,000 cases each | 507 / 877 / 1279 / 41 mismatches (all caught) |
| 2026-10-05 | 0dd4aef | ″ | ares | zdiff throughput (C vs C) | 2,112 cases/s |
| 2026-10-05 | 0dd4aef | ″ | ares | prelim on the C core | 899 instr, 8,721 cycles (exact) |
| 2026-10-05 | 0dd4aef | ″ | ares | ZEXDOC groups ≤ 5M instr on the C core | 35/35 exact (CRC, steps, cycles) |
| 2026-10-05 | 0dd4aef | ″ | ares | **C core baseline:** ZEXDOC subset (37.8M instr, z80_step) | **1,497 ns/instr** (≈ 140 cycles) |
| 2026-10-05 | 0dd4aef | ″ | ares | C core: scan loop `LD A,(HL); AND A; INC HL; JR`, z80_run batches | 1,080 ns/instr (101.3 cycles) |
| 2026-10-05 | 0dd4aef | ″ | ares | C core: same loop, z80_step | 1,131 ns/instr (106.1 cycles) |
| 2026-10-05 | 0dd4aef | ″ | ares | C core: fill loop `LD (HL),A; INC L; DJNZ` (write_byte callback), z80_run batches | 1,412 ns/instr (132.4 cycles) |
| 2026-10-05 | 0dd4aef | ″ | ares | bank-window memcpy 2 KB, cold / warm dcache (newlib memcpy) | 173 / 65 µs |
| 2026-10-05 | 0dd4aef | ″ | ares | bank-window memcpy 4 KB, cold / warm | 321 / 216 µs |
| 2026-10-05 | 0dd4aef | ″ | ares | bank-window memcpy 8 KB, cold / warm | 748 / 773 µs |
| 2026-10-05 | 0dd4aef | ″ | ares | bank-window memcpy 16 KB, cold / warm | 1,521 / 1,545 µs |
| 2026-10-05 | 0dd4aef | PC build (`make pc`, WSL gcc -O2) | PC | full ZEXDOC through z80_step | 67/67 OK, 5,764,169,747 instr, 46,734,978,649 cycles |
| 2026-10-05 | 0dd4aef | ″ | PC | full ZEXDOC through z80_run | 67/67 OK, +5 instr / +33 cycles (harness overshoot, as documented) |
| 2026-10-05 | 900c996 | testsuite + traces (`test/traces/*.z80t` from mvs64 2da789d / 61d8574) | ares | **C core baseline on real driver code:** replay `mslug_42s_1s` (busiest mission second, 454,792 instr) | **1,633 ns/instr (153 cycles)** |
| 2026-10-05 | 900c996 | ″ | ares | C core: replay `mslug_36s_10s` (4,334,467 instr) | 1,640 ns/instr (153 cycles) |
| 2026-10-05 | 900c996 | ″ | ares | C core: replay `samsho2_30s_5s` (166,202 instr) | 2,053 ns/instr (192 cycles) |
| 2026-10-05 | 900c996 | ″ | ares | trace replay REF / NEW, all three traces | 0 mismatches, every RUN/STEP/IN/OUT/RAM/END check |
| 2026-10-05 | 900c996 | ″ | ares | trace replay control MUT1 (BIT without H) | 2,007 / 19,310 / 1,011 mismatches (= mvs64's z80replay) |
| 2026-10-05 | 900c996 | ″ | ares | zdiff throughput, same harness, new code layout | 1,629 cases/s (was 2,112 at 0dd4aef) |
| 2026-10-05 | 7fbb914 | testsuite, defaults (M1: asm run loop, C fallback for every opcode) | ares | zdiff REF vs ASM, 20,000 cases / direct-write filter, 5,000 cases | 0 / 0 mismatches |
| 2026-10-05 | 7fbb914 | ″ | ares | zdiff controls MUT1–MUT4 vs REF | 507 / 877 / 1,279 / 41 mismatches (unchanged) |
| 2026-10-05 | 7fbb914 | ″ | ares | trace replay ASM, all three traces; MUT1 control | 0 mismatches; 2,007 / 19,310 / 1,011 |
| 2026-10-05 | 7fbb914 | ″ | ares | prelim, ZEXDOC and ZEXALL subsets (35 + 35 groups ≤ 5M instr) on ASM through `z80_run` | exact (steps, cycles, CRC); 0 fetch-pointer mismatches |
| 2026-10-05 | 7fbb914 | ″ | ares | replay `mslug_42s_1s`: REF / ASM (M1) | 1,764 / 3,644 ns/instr (165 / 341 cycles) |
| 2026-10-05 | 7fbb914 | ″ | ares | replay `mslug_36s_10s`: REF / ASM (M1) | 1,771 / 3,648 ns/instr |
| 2026-10-05 | 7fbb914 | ″ | ares | replay `samsho2_30s_5s`: REF / ASM (M1) | 2,324 / 4,416 ns/instr |
| 2026-10-05 | 7fbb914 | ″ | ares | scan loop: REF `z80_run` / ASM `n64z80_run` (M1) / ASM `n64z80_step` (C) | 1,080 / 3,361 / 1,174 ns/instr |
| 2026-10-05 | 7fbb914 | ″ | ares | ASM ZEX subset through `z80_run` (75.7M instr) | 2,978 ns/instr |
| 2026-10-06 | b8d8ce9 | testsuite `ZEX_ONLY=1 ZEX_SETS=2 ZEX_MAX_STEPS=0` (M1) | ares | **full ZEXALL on ASM through `z80_run`**, all 67 groups (5,764,172,722 instr) | **67/67 exact** (steps, cycles, CRC); 18,447,860 ms N64 time (3.2 µs/instr) |
| 2026-10-06 | 62f7839 | testsuite, defaults (M2: an asm handler for every opcode) | ares | zdiff REF vs ASM 20,000 cases / direct-write 5,000; controls; replays; prelim, ZEXDOC and ZEXALL subsets through `z80_run` | 0 / 0 mismatches; MUT1-4 caught; replays clean, 0 C-fallback instructions; ZEX exact |
| 2026-10-06 | 62f7839 | testsuite `ZEX_SETS=0 ZDIFF_CASES=2000` (layout-pinned timing build) | ares | **replay `mslug_36s_10s`: REF / ASM** | **1,630 / 652 ns/instr (152 / 61 cycles), 2.5x** |
| 2026-10-06 | 62f7839 | ″ | ares | replay `mslug_42s_1s`: REF / ASM | 1,627 / 655 ns/instr |
| 2026-10-06 | 62f7839 | ″ | ares | replay `samsho2_30s_5s`: REF / ASM | 1,959 / 985 ns/instr |
| 2026-10-06 | 62f7839 | testsuite, defaults | ares | ASM ZEXDOC + ZEXALL subsets through `z80_run` (75.7M instr) | 891 ns/instr |
| 2026-10-06 | 796c834 | `ZEX_SETS=0 ZDIFF_CASES=4000` (layout not yet pinned) | ares | Metal Slug / samsho2 trace, ASM: inline dispatch tails -> shared `dispatch` | 746 -> 668 / 1,512 -> 1,125 ns/instr |
| 2026-10-06 | 4a71b1b | `ZEX_SETS=0 ZDIFF_CASES=2000`, layout pinned | ares | hot/cold sections, Metal Slug / samsho2 | 681 -> 662 / 1,062 -> 971 ns/instr |
| 2026-10-06 | f86f029 | `ZEX_SETS=0 ZDIFF_CASES=2000`, layout pinned | ares | hot/cold as one section (cold right after hot), port I/O and EI/DI hot; Metal Slug / samsho2 | 652 -> 616 / 985 -> 1,013 ns/instr |
| 2026-10-06 | f86f029 + pad | ″ | ares | core data padded by 1 / 2 / 4 KB: Metal Slug ASM (REF) | 623 (1,659) / 625 (2,026) / 631 (1,596) ns/instr |
| 2026-10-06 | 8aec49d | ″ | ares | R's prefix increment in `$at`; Metal Slug / samsho2 | 616 -> 584 / 1,013 -> 1,001 ns/instr |
| 2026-10-06 | 8aec49d + 32 instr | ″ | ares | ares cost model, 32 instructions added to the run entry, scan loop (4 instr/run): nop / lw / lw+use | +8.0 / +16.0 / +24.0 cycles/instr (1 / 2 / 3 cycles each) |
| 2026-10-06 | 9341700 | ″ | ares | cheaper run entry/exit, delay slots filled: Metal Slug / samsho2 / scan loop | 584 -> **577** / 1,001 -> 1,032 ns/instr / 81.4 -> 73.6 cycles/instr |
| 2026-10-06 | 9341700 | testsuite, defaults (M3) | ares | zdiff REF vs ASM 20,000 / direct-write 5,000; controls; replays; prelim, ZEXDOC and ZEXALL subsets through `z80_run` | 0 / 0 mismatches; MUT1-4 caught; replays clean; ZEX exact |
| 2026-10-06 | b6a6f9c | `ZEX_SETS=0 ZDIFF_CASES=2000` (timing build) | ares | asm interrupt service: Metal Slug / samsho2 | 577 -> 572 / 1,032 -> 943 ns/instr |
| 2026-10-06 | befc6fb | ″ | ares | asm `z80_step`, step-only scan loop | 112.7 -> 226 cycles/instr (C step 106); mvs64 steps 512 times per 93k runs |
| 2026-10-06 | a732df3 | ″ | ares | zdiff split mapping, old core vs bounce buffer | 269 C-fallback instructions in 500 cases -> 0, 0 mismatches |
| 2026-10-06 | 5fdaf57 | ″ | ares | data layout by dcache set, replay data pinned: Metal Slug / samsho2 | 614 -> 529 / 1,154 -> 906 ns/instr (an unlucky table position: 762) |
| 2026-10-06 | 28de7bd..85e6eca | testsuite `ZDIFF_CASES=100000 ZDIFF_SEED=2`, then `200000` seed 3 | ares | zdiff REF vs ASM / direct / split | 0 / 0 / 0 mismatches (after the chain and wrap fixes) |
| 2026-10-06 | 19fd464 | `ZEX_SETS=0 ZDIFF_CASES=2000` | ares | never-run handlers in the rare subsection: Metal Slug / samsho2 | 532 -> 523 / 913 -> 814 ns/instr |
| 2026-10-06 | 153b423 | ″ | ares | INC/DEC/CP flags | 523 -> 517 ns/instr |
| 2026-10-06 | 1614054 | ″ | ares | push fast path: Metal Slug / samsho2 | 517 -> 511 / 810 -> 782 ns/instr |
| 2026-10-06 | 1614054 | `ZEX_SETS=3` vs `0`, same core | ares | Metal Slug, before the harness was pinned | 692 vs 511 ns/instr (the replay's code on the hot block's icache lines) |
| 2026-10-06 | 126ecb2 | `TRACE_SHIFT` 0-7 KB | ares | Metal Slug / samsho2 by trace placement | 531-544 / 892-929 ns/instr |
| 2026-10-06 | e3bc6eb | `ZEX_SETS=0` / `=3` | ares | **save area off the stack: Metal Slug** / samsho2 | **501 / 512** / 790 / 835 ns/instr (REF 1,585) |
| 2026-10-06 | e3bc6eb | `ZEX_ONLY=1 ZEX_SETS=2 ZEX_MAX_STEPS=0`, no C fallback (M4 exit) | ares | **full ZEXALL through `z80_run`** | **67/67 groups exact** (5,764,172,722 instr; steps, cycles, CRC) |
| 2026-10-06 | e3bc6eb | testsuite, defaults (no C fallback) | ares | init vs reference; zdiff 20,000 / direct 5,000 / split 5,000; controls; replays; prelim, ZEXDOC, ZEXALL subsets | all PASS; Metal Slug 512, samsho2 835 ns/instr (REF 1,598 / 1,902) |

## Notes on the rows

- **2026-10-05, C core baseline.** 1.50 µs/instr on ZEXDOC agrees with the
  1.65–1.85 µs measured in-game in mvs64 (PLAN.md §10). The in-cache scan
  loop at 1.08 µs is close to mvs64's 0.94 µs for the same loop. The
  PLAN.md exit metric (µs/instr on a recorded Metal Slug trace) still needs
  the trace dump from mvs64; until then ZEXDOC and the scan loop are the
  baselines the asm core will be compared against.
- **2026-10-05, window copy.** Cold copies cost ≈ 8 cycles/byte (2 KB ≈ 16k
  cycles, 16 KB ≈ 143k cycles), matching the design-notes cost model; at
  ≥ 8 KB "warm" equals cold because source plus destination exceed the 8 KB
  dcache. Against option B's estimated ≈ 5.5M cycles/s overhead, option A
  (flat image) breaks even near ≈ 340 effective switches/s if they are all
  2 KB, ≈ 40/s if they are all 16 KB (see design-notes §6). The warm 2 KB
  figure (3 cycles/byte) suggests newlib's memcpy is not the fastest
  possible copy; a doubleword copy would lower the warm cost but not the
  cold, miss-bound one.
- **2026-10-05, controls.** The PC build gives slightly different control
  counts for the same seed (MUT1 517 vs 507) because `long` is 64-bit on PC:
  random budgets that wrap 2³² cycles stop differently in the reference
  itself. C vs C is clean on both.
- **2026-10-05, trace baseline (M0 exit metric).** 1.63 µs/instr on the
  busiest Metal Slug second agrees with mvs64's in-game 1.65 µs (PR #21
  build), so the replay is a faithful stand-in for the game's Z80 work,
  minus the icache/dcache eviction by the 68k between slices. Metal Slug's
  mission runs 370k–455k instructions per emulated second (mvs64 correction,
  test/traces/README.md), so the C core needs ≈ 0.74 s of N64 time per
  audio second at the 455k peak.
- **2026-10-05, zdiff throughput.** Only the code layout changed between
  0dd4aef and 900c996 (DFS and the replay code linked in), and the C-vs-C
  harness slowed 23%: N64 timings are layout-sensitive, so compare cores
  within one build, never across builds.
- **2026-10-05, M1 cost.** The M1 loop runs every instruction through the
  C fallback (write the registers back, call the reference for one
  instruction, reload, remap): about 2.2 µs per instruction more than the C
  core's own loop (scan loop 3,361 vs 1,174 ns through the same C code via
  `z80_step`). That overhead disappears per opcode as M2 adds handlers. The
  REF trace numbers moved from 1,633 to 1,764 ns with no change to the C
  core (its synthetic loops are unchanged at 1,080 / 1,412 ns): another
  layout effect on the larger replay working set, so speedups are always
  quoted against REF in the same build.
- **2026-10-06, M2.** Timings after this point come from builds with the
  core linked last on a 16 KB boundary; before that, any core edit moved the
  harness code and shifted every timing (REF included) by up to 15%. Only
  compare rows built with the same test knobs.
- **2026-10-06, M4.** From 126ecb2 on, the replay's code, state and traces
  are pinned too (test/icache_pad.S, TRACE_SHIFT): builds with different
  test knobs then agree within ~2% (they differed by up to 35% before).
