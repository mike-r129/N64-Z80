# seed/: starting material from the mvs64 session (2026-10-05)

This is temporary. Move things into the real layout (PLAN.md §2) as they're
adopted, then delete this folder.

## reference/
`z80.c`, `z80.h` and `z80.LICENSE` (MIT, superzazu/z80) as of mvs64 commit
54f7973, PR #21 "z80: inline dispatch, gate interrupts on one masked word".
This is the behaviour the asm core must match bit for bit.

mvs64-specific bits the test build has to stub or define:
- **`struct z80_hot`:** placed in section `.rodata.z80_hot`. It holds the
  CPU, the cycle tables, `sz53p`, rmap and 2 KB of RAM. The core reaches
  the tables through `#define cyc_00 z80_hot.cyc_00` and similar.
- **`z80_init` under `#ifdef N64`:** references `z80_rodata_anchor` from
  mvs64's `z80_anchor.c`. Define a dummy, or build without `N64` defined
  for the reference copy.
- **`MVS64_Z80OPHIST`:** a PC-only diagnostic. Leave it undefined.

## harness/zdiff/ (PC differential test, C vs C)
- `run.sh <ref git-ref> <new: git-ref | wt | dir> [cases] [seed]` compiles
  `wrap.c` once per core, with `-DPFX=REF/NEW` and `-fvisibility=hidden`,
  then `objcopy --localize-hidden`, and links both into one binary.
- **The paths are from the old session:** the scratchpad and
  `/mnt/c/Users/Mike/Desktop/mvs64`. Rewrite them for this repo.
- Set `ZD_DIRECT=1` to test direct-write pages. That needs a core with a
  `wdirect[]` bitmap, an experiment kept on mvs64 branch
  `bak/z80-compact-direct`. The reference core doesn't have it.
- `mut.sh` runs the negative controls: two planted bugs that must be caught.
- Last results: main vs PR #21, 900,000 cases, 0 mismatches. Planted bugs
  gave 477 and 872 mismatches per 20,000 cases.

## harness/zextest.c, zex.sh (PC CP/M ZEX harness)
- Get the ROMs with `git clone https://github.com/superzazu/z80` and look in
  `z80/roms/`: `prelim.com`, `zexdoc.cim`, `zexall.cim`.
- Expected through `z80_step`: 67/67 OK and 46,734,978,649 cycles.
- Through `z80_run` the stop flag is only seen between batches, so expect a
  5-instruction overshoot (+33 cycles) and a doubled "Preliminary tests
  complete" line. That's a harness artifact.

## harness/z80bench_old.c
The old in-mvs64 benchmark, appended to `sound_neogeo.c`. It uses
`z80_step_inline`, which has since been removed. Keep it only as a pattern
for the synthetic loop and the "real driver with injected IRQ every 1300
steps" bench.
