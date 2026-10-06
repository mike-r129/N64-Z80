# n64z80: an optimized Z80 core for Nintendo 64: project plan

> **Names.** The repo/folder is **`N64-Z80`** (matching `N64-NEOGEO`).
> Inside the code, the library uses the **`n64z80`** prefix (files, symbols,
> sections; `N64Z80_` for macros), matching the repo name. It is not
> `m64z80`: "M64" is now ModRetro's N64-compatible console.

## 1. Goal

A hand-written MIPS assembly Zilog Z80 interpreter for the N64 (VR4300,
libdragon toolchain). It is a sibling to **m64k**, the 68000 core that mvs64
already uses (`mvs64/m64k/`). It must be:

- **Exact:** bit-for-bit identical to the reference C core (`reference/`,
  mvs64's tuned copy of superzazu/z80). That covers registers, all flags
  including undocumented Y/X, MEMPTR/WZ, R, cycle counts, and bus accesses
  with their cycle stamps.
- **Fast:** the design target is **≤ 0.45 µs per Z80 instruction** (about 42
  VR4300 cycles) on the Metal Slug sound driver, 3.6× faster than the C core
  (1.63 µs on the same trace). It is the budget for **30 fps in Metal Slug's
  mission with real-time sound**; 0.81 µs is enough for 20 fps (see "Why").
- **A drop-in for mvs64:** the same API as mvs64's `z80.h`, chosen at build
  time with a flag (`Z80_CORE=asm|c`).
- **Generic:** no Neo Geo-specific code in the core, so other N64 emulators
  with a Z80 (Master System, Game Gear, ColecoVision, MSX) can use it.

### Why (measured in mvs64, Oct 2026; corrected 2026-10-05)
- In Metal Slug's first mission the Z80 runs **370k–455k instructions per
  emulated second** (peak 455k: trace `mslug_42s_1s`). An earlier "about 1M"
  read mvs64's N64 `[SNDRMS]` intervals as 1 s; they cover about 2.3 s of
  audio (`test/traces/README.md`).
- The C core costs **1.65–1.85 µs per instruction** in game, and 1.63 µs
  replaying the busiest Metal Slug second in our testsuite ROM
  (`docs/measurements.md`). So the Z80 alone needs about **0.74 s of N64
  time per second of audio** at the peak.
- In release builds sound can't keep up with the 68k and video on top: the
  overload governor mutes it and the mission runs at about 10 fps.
- **Measured budget** (mvs64 `main` d04c08f, ares, DET_AUDIO fixed in mvs64
  PR #23; details in `test/traces/mvs64-budget.md`). Per second of mission
  audio, sound costs about 1,040 ms of N64 time: Z80 673 ms (418k
  instructions × 1.61 µs), YM2610 166 ms, other sound overhead ~200 ms. Each
  guest frame also costs ~14.8 ms outside sound (68k 72%, video 13%,
  DMA/other 4% of 16.7 ms). With real-time sound at guest frame rate F:
  `F × 14.8 ms + Z80 + 367 ms ≤ 1,000 ms`, at 418k instructions/s:

  | Mission fps | Z80 may use | Z80 µs/instruction | vs C core (1.61 µs) |
  |---|---|---|---|
  | 20 | 337 ms/s | **0.81** | 2.0× |
  | 25 | 263 ms/s | **0.63** | 2.6× |
  | 30 | 189 ms/s | **0.45** | 3.6× |
  | 35 | 115 ms/s | 0.28 | 5.8× |

  - At the 455k peak second the budgets are about 8% tighter.
  - Above about 35 fps the Z80 can't close the gap alone: the YM2610, the
    sound overhead and the 68k are the limits (mvs64-side work).
  - These are warm-cache replay-equivalent rates; in game the asm core also
    pays icache/dcache warm-up after each 68k slice, so measure in mvs64
    (M5), not only on the trace.
- C-level tuning got about 10–15% per round (mvs64 PRs #19 and #21). The rest
  needs an asm core.
- Profile of the C core: about half of each instruction was loop and dispatch
  overhead (`z80_run` 15.3% of all CPU samples vs `exec_opcode` 14.5%).

### Not goals
- A dynarec. Leave room for a later pre-decoded micro-op phase (§9), but don't
  build it now.
- Cycle accuracy *within* an instruction. Cycle counts per instruction must
  match the reference exactly.
- Non-N64 builds of the asm core. The C reference core stays the portable
  path.

## 2. Repository layout (target)

```
<repo root>/
  README.md            # m64k-style: what it is, features, how to use, config
  LICENSE              # MIT for the asm core; reference/ keeps its own MIT notice
  n64z80.h             # public API (mirrors mvs64 z80.h, see §3)
  n64z80_asm.S         # the core
  n64z80_tables.S      # generated: dispatch tables, cycle tables (do not edit)
  n64z80.c             # C glue: init, z80_step, slow paths, callback trampolines
  reference/           # the C reference core (from seed/reference), MIT
  tools/gen_tables.py  # makes n64z80_tables.S; checks cycle tables == reference
  test/
    testsuite.c        # N64 test ROM: ZEXDOC/ZEXALL + differential + bench
    zcore.c, zdiff.c   # core wrappers + differential harness (from seed/harness/zdiff)
    zex.c, bench.c     # ZEX harness, benchmarks
    mutants/           # planted-bug controls (sed scripts on reference/z80.c)
    pc/                # host build of the same harness
    traces/            # recorded Neo Geo driver traces (generated, gitignored)
  Makefile             # builds n64z80_testsuite.z64 (like m64k/Makefile)
  docs/                # design notes, measurements log
```

`seed/` held the starting material copied from the mvs64 session (§12). It
was adopted into the layout above in M0 and deleted; it is in the first
commit's history.

## 3. API contract (must match mvs64's `z80.h` behavior)

The reference is `reference/z80.h` (mvs64 commit 54f7973, PR #21; identical
to mvs64 `main` d04c08f, where PR #21 is merged). Keep
the struct field names, because mvs64's `sound_neogeo.c` reads and writes
them directly: `pc, sp, a, f, b, c, ..., iff1, iff2, halted, int_pending,
nmi_pending, irq_line, iff_delay, cyc, r, wrote, wrote_any, irq_redeliver,
rmap, read_byte, write_byte, port_in, port_out, userdata, events, ev_mask`.

- `unsigned z80_run(z80* z, unsigned long until, uint16_t* last_pc)` runs at
  least one instruction, then continues while `(long)(until - cyc) > 0`.
  - It stops early after any instruction whose new PC is ≤ that
    instruction's own address. That covers loop edges: backward branches,
    self-jumps, repeating block ops, and interrupt entry to a lower vector.
  - It also stops after an instruction that leaves the CPU halted.
  - It returns the instruction count. `*last_pc` gets the address of the last
    instruction.
  - It is exactly equivalent to this loop:
    `{ irq_line re-assert; step; interrupt service; stop test }`.
- **Order inside one iteration, exactly as in the reference:**
  1. If `irq_line && iff1 && !int_pending`: `z80_gen_int(int_data)` and
     `irq_redeliver++`.
  2. Record `pc0`. Fetch: HALT executes a NOP in place. Execute.
  3. If `iff_delay | nmi_pending | (int_pending & iff1)`: process interrupts
     (EI delay countdown, NMI, IM0/1/2 accept). This can move PC.
  4. Stop if out of cycles, if `pc <= pc0` (using the PC after step 3), or
     if halted.
- **`wrote` / `wrote_any`:** whether the *last* / *any* instruction of the run
  wrote memory or executed OUT. Interrupt-accept pushes count.
- **Callbacks** (`write_byte`, `port_in`, `port_out`) may read `z->cyc` and
  other struct fields, and may change `irq_line` / `int_pending` / the rmap
  (bank switches happen inside `port_in`). Before every callback, write back
  everything a callback might read (at least `cyc`). After every callback,
  reload events and PC mapping.
- **`z80_step(z)`:** one instruction plus interrupt service, with no irq_line
  re-assert. mvs64 still uses it on the NMI/sound-command path.
  `z80_gen_int`, `z80_gen_nmi` and `z80_init` work as in the reference.
- **Field coherence:** owner code reads `cpu.pc`, `cpu.cyc`, `cpu.iff1`,
  `cpu.halted`, `cpu.r` and the rest between runs, and its idle-skip writes
  `cpu.cyc` and `cpu.r`. After `z80_run` returns, the struct must be the
  complete, coherent state.

## 4. Architecture: starting decisions

These came out of a design review (Fable 5.1 advisor plus the mvs64
measurements). They are starting points: each one is revisited only with a
measurement.

### 4.1 Registers (o64 ABI: s0–s8, gp and sp survive C calls)
| MIPS | Z80 state |
|---|---|
| s0 | A (zero-extended) |
| s1 | F (byte, Z80 layout) |
| s2 | HL (16-bit) |
| s3 | DE |
| s4 | BC |
| s5 | PC as a host pointer |
| s6 | cycles left (signed, counts down) |
| s7 | SP (16-bit) |
| s8 | instructions executed (return value, lazy R, `wrote`) |
| t8 | host PC of the current instruction's start (loop-edge test) |
| t9 | index register during a DD/FD-prefixed instruction |

- **Context:** IX, IY, WZ, R, the alternate set, IFF and the event state stay
  in a fixed `.sdata` context block, addressed `%gp_rel` like m64k. The
  `z80*` argument must be that block (assert in debug builds).
- **Flags:** keep F as one byte plus the 256-byte `sz53p` table (S, Z, Y, X,
  even parity), and the carry-vector math for H/V/C (`c = r ^ a ^ b`). That's
  the same math as the reference, so differential mismatches map 1:1.
- No lazy flags: `AND A; JR Z` is the hottest pair and consumes the flags
  immediately.

### 4.2 PC and memory reads: decide by measurement first (M0)
- **Option A, flat 64 KB image (not chosen, see the decision below):** the owner keeps one
  contiguous host image of the Z80 address space.
  - Bank switches (IN 0x08–0x0B on Neo Geo) memcpy the 2/4/8/16 KB window.
  - Every read is then `addu + lbu`, with no page-crossing problem.
  - Self-modifying code in RAM stays coherent automatically.
  - Viable only if bank switches are rare enough. **Measured (mvs64 PC
    build, 2026-10-05):** Metal Slug switches *each* of the four windows
    about 50 times per second (2,995 value changes in 60 s per window).
    samsho2 switches about 0.3 times per second.
    - For Metal Slug that's about 1.5 MB/s of copying (16+8+4+2 KB at
      50/s), roughly 15–30 ms of N64 time per second.
    - Option B's cost is about the same: about 2 instructions × 1M
      instructions/s, about 21 ms/s.
    - So it's a close call. Benchmark both on the Metal Slug trace, or
      consider a **hybrid**: flat image for fixed ROM (0x0000–0x7FFF) and
      RAM, page table plus limit for the banked windows.
- **Decision (M0, 2026-10-05): option B, rmap plus limit.** The window
  copies were measured on N64 (testsuite `[BENCH] window copy`, ares): cold
  178 / 331 / 767 / 1,559 µs for 2 / 4 / 8 / 16 KB, about 8 cycles per byte,
  and ≥ 8 KB copies flush the whole dcache. At 50 switches/s per window
  that's about **140 ms of N64 time per second** for option A, against
  roughly 10–30 ms/s for option B (2–6 extra cycles × 455k instructions/s).
  The hybrid still needs B's checks for the windows, so it is not worth its
  complexity now. A TLB-aliased image (design-notes §6, "A2") is the one
  variant that avoids the copy; revisit it only with a measurement after M3.
  - Needs an owner-side API, e.g. `z80_map_window(base, size, src)`, plus a
    fallback.
- **Option B, rmap plus a limit:** per 256-byte page, `{bias, limit}`, where
  `limit` is the end of the contiguous host region minus 3 (the maximum
  operand length).
  - Each instruction does `sltu; beqz slow_fetch`, and the slow path fetches
  byte-wise.
  - It's exact for any layout, including 2 KB windows and instructions that
  straddle a page boundary.
- **TLB mapping (as in m64k): no.** The 2 KB windows are smaller than the
  4 KB minimum TLB page, rebanking happens inside callbacks, and trapping
  writes through TLB exceptions costs hundreds of cycles.

### 4.3 Dispatch
- A jump table (`lw; jr`), with handlers 32-byte aligned and variable size,
  as in m64k.
- Hot handlers inline the dispatch tail
  (`lbu op; sll; addu; lw; jr` with the cycle adjust in the delay slot).
  Cold handlers `j dispatch_common`.
- **Icache budget:** the hot set lives in `.text.n64z80hot`, ordered by
  frequency, and stays at or below about 4 KB. It covers the top ~60
  opcodes, the prefix entries, the write stub and dispatch. Everything else
  goes in `.text.n64z80cold`.
- The 68k runs between Z80 slices and evicts the icache. Warm-up per slice is
  real, so long slices (owner-controlled `until`) matter.
- **Prefixes:** CB, ED and DDCB/FDCB each get a table (16-bit offset tables to
  save dcache).
  - DD/FD loads IX/IY into t9 and dispatches through one DDFD table whose
    non-index entries point at the *base* handlers. The prefix has already
    charged its cycles and R, so DD/FD fallthrough comes out exact for free.
    Copy the reference's tables, not the datasheet.
- **FD CB d `BIT b,(IY+d)`** alone is 3.7% of Metal Slug's instructions: give
  it dedicated macro-generated handlers that compute IY+d once and update
  MEMPTR.

### 4.4 Cycles, events, stop test
- **Cycles:** `addiu s6, s6, -N`, with an immediate per handler. Taken
  branches subtract their extra cycles. Before callbacks and at exit,
  `cyc = until - s6`.
- **Counter poisoning for events:** when `events & ev_mask` may have become
  non-zero, save the real s6 in the context and set `s6 = -1`. The trigger
  points are: after any callback returns, after EI (iff_delay), after
  HALT/DI/RETN/interrupt accept.
  - One `bltz s6, slow_exit` per instruction then catches both "out of
    cycles" and "event pending" (2 instructions).
  - `slow_exit` restores s6, then follows §3's order exactly: service
    interrupts (step 3), then the stop test (step 4), then the irq_line
    re-assert (step 1) for the next iteration.
- **Loop edge:** only control-transfer handlers can produce new PC ≤ old PC:
  JR, JP, CALL, RET, RST, DJNZ, JP (HL)/(IX)/(IY), repeating block ops, and
  interrupt entry. Only they compare against t8. Other handlers skip the
  test.
- **R is lazy:** `R = (R & 0x80) | ((R0 + s8 + r_extra) & 0x7F)`. Prefix
  handlers bump `r_extra`. Materialise it at exit, on `LD A,R`, on
  `LD R,A` (rebase it), and on interrupt accept.
- **`wrote` costs nothing per instruction:** the write stub and OUT store
  `last_write_n = s8`. At exit, `wrote = (last_write_n == s8)` and
  `wrote_any = (last_write_n != sentinel)`.

### 4.5 Writes
- One shared out-of-line stub, `n64z80_wr` (t0 = address, t1 = value,
  `bal`). Never inline it: mvs64 measured inlined bus checks as 6–10%
  slower because of icache growth.
- A `wmap[256]` write page table: non-null means store directly, null means
  the C callback. On Neo Geo only pages 0xF8–0xFF are direct.
- After the callback path, run the post-callback sequence: poison check, PC
  remap.

### 4.6 Data placement
- One `.sdata` block, 8 KB-aligned with an anchor plus pad, like
  `m64k_asm.S`. It holds the context, `sz53p`, the main optable (1 KB), the
  prefix tables, and rmap/wmap (or the flat-image base). Total about 5 KB.
- Coordinate its dcache sets with m64k's pinned `.sdata` (m64k pins its
  context at set 140, page offset 0x8C0) so the two hot sets don't alias.
  Document the constant in both repos.

### 4.7 Code organisation
- GAS macros for opcode families: LD r,r'; ALU A,r / A,(HL) / A,n;
  INC/DEC r; CB rotates/BIT/RES/SET; the (IX/IY+d) variants. Write the bodies
  by hand, as m64k does.
- `tools/gen_tables.py` generates only the tables, and fails the build if
  the cycle tables differ from the reference's `cyc_00/cyc_ed/cyc_ddfd`.

## 5. Testing: everything runs on N64 (in ares)

The asm can't run in an x86 harness. Don't rely on qemu-user either: Linux
mips64 toolchains are n32/n64 ABI, not libdragon's o64.

**`make test`** builds `n64z80_testsuite.z64`: one ROM linking the asm core
**and** the reference C core.

1. **Differential test:** this is the port of `seed/harness/zdiff` to N64.
   - Seeded random states: registers, flags, interrupt/halt state, a random
     64 KB image with a prefix-heavy opcode stream at PC, and budgets of
     1 cycle (exactly one instruction) or up to 400 cycles.
   - Both cores run each case. Compare:
     - the full state
     - every bus event (kind, address, value, cycle stamp)
     - the memory image
     - the step count, `last_pc`, `wrote` and `wrote_any`
   - On the first mismatch, print the full state of both cores plus the
     event log, then stop.
   - Validate the harness first: C vs C must pass, and planted bugs must be
     caught. `seed/harness/zdiff/mut.sh` has two examples.
   - Also cover a **direct-write mode** (wmap pages), where write events to
     direct pages are filtered from both logs. The test's fake IN port must
     not depend on the number of logged events (a lesson from the seed
     harness).
2. **ZEXDOC/ZEXALL:** load `zexdoc.cim`/`zexall.cim` with CP/M BDOS stubs,
   using the logic in `seed/harness/zextest.c`. Expected: 67/67 OK and
   46,734,978,649 cycles, when driven through `z80_step`. Through `z80_run`
   the harness overshoots the stop by a few instructions, so compare the
   output text, not the cycle total.
   - Get the ROMs from https://github.com/superzazu/z80/tree/master/roms.
     Check their license before committing them; otherwise fetch them in the
     Makefile.
   - ZEXALL is 5.7G Z80 instructions, slow in ares: run single groups or a
     small budget in the normal loop, and the full suite occasionally.
3. **Benchmark:**
   - COP0 Count (46.875 MHz) around `z80_run`.
   - Synthetic loops per handler family, to check each one's instruction
     budget.
   - **Recorded traces:** dump a Metal Slug sound-driver snapshot (Z80
     state, 64 KB image, bank registers, the IRQ/NMI schedule) from mvs64,
     replay it in the bench ROM, and report µs/instruction for both cores
     plus per-opcode cost.
   - mvs64's `MVS64_Z80OPHIST` PC build gives the opcode mix to compare
     against (table in §10).
4. **Driving ares headless:** mvs64 has
   `C:\Users\Mike\Desktop\VSCode Projects\N64-NEOGEO\mvs64\tools\ps-ares-run.ps1`,
   which launches ares, captures the ISViewer log, and kills it after N
   seconds. Print a "done" marker and stop early when you see it.
   - Known flake: the first run after a build often logs nothing or stalls,
     so retry automatically when fewer than ~100 lines are logged. See the
     mvs64 session's `arun.sh` pattern.
5. **Real hardware:** run the testsuite ROM on the console occasionally.
   ares timing is close but not RDRAM-exact.

## 6. Milestones (each ends with the differential test clean and a measured
number in `docs/measurements.md`)

- **M0: harness and decisions.** *Done 2026-10-05: C vs C clean, controls
  caught, trace replay clean, option B chosen, C core 1.63 µs/instr on the
  Metal Slug trace (`docs/measurements.md`).*
  - The test ROM runs the reference core against itself (C vs C) with the
    differential and ZEX tests; planted bugs are caught.
  - Bench ROM with trace replay working.
  - Pick §4.2 option A, B or the hybrid. The bank-switch rates are already
    measured (§4.2), so decide with the trace bench.
  - Exit: baseline µs/instruction of the C core on the trace, inside the
    bench ROM.
- **M1: asm skeleton, everything through the C fallback.**
  - Asm `z80_run` with register load/store, counter poisoning, the stop test
    and lazy R.
  - Every opcode calls the C reference for exactly one instruction
    (`z80_c_step_one`: sync registers to the struct, call, reload).
  - For a prefixed instruction whose target isn't implemented yet, rewind to
    the prefix byte and fall back for the whole instruction.
  - Exit: differential clean; ZEXALL clean through `z80_run`.
- **M2: top 20 opcodes in asm** (~70% of the Metal Slug mix).
  - Exit: differential clean; measurable speedup on the trace.
- **M3: top ~60 opcodes plus FD CB `BIT`** (~95%), with the hot set inside
  the §4.3 icache budget.
  - Exit: µs/instruction on the trace ≤ 0.6.
- **M4: full asm coverage.** The C fallback becomes a debug option
  (`N64Z80_C_FALLBACK=1`).
  - Exit: ZEXALL plus differential clean with the fallback disabled; ≤ 0.45
    µs/instruction.
- **M5: mvs64 integration** (on a branch in mvs64).
  - Vendor the core into mvs64 as `n64z80/` (like `m64k/`), add a
    `Z80_CORE=asm|c` build switch, add the owner-side window/wmap setup, and
    check the `z80_anchor.c` / m64k dcache pins.
  - Exit: the mvs64 two-game PC gate stays C (unchanged). The N64 build with
    the asm core gives the same WAV hash under DET_AUDIO and INPUT replay as
    the C core, so add an N64 audio-hash gate.
  - mvs64's side of this milestone, including its entry criteria and prep
    work, is in `C:\Users\Mike\Desktop\mvs64\Z80-INTEGRATION-PLAN.md`.
  - Measure ares fps and sound % on Metal Slug and samsho2.
- **M6 (optional): pre-decoded micro-op pages** (§9), only if M5 falls short.

## 7. Traps to handle exactly (copy the reference's behaviour, don't "fix" it)

- **HALT:** stops the run after the instruction that halts. While halted,
  each step is a 4-cycle NOP in place.
- **EI delay:** interrupts are not accepted until after the instruction
  following EI. Handle it through poisoning.
- **Interrupt accept:** increments R and sets MEMPTR. On IM0, execute
  `int_data` as an opcode, as the reference does (Neo Geo uses IM1 plus
  NMI).
- **Block ops:** LDIR/LDDR/CPIR/CPDR/INIR/OTIR and the rest run one iteration
  per step with PC−2. The loop edge fires on every iteration (existing
  behaviour; keep it).
- **DD/FD chains:** DD FD, DD DD, and DD ED (ED cancels the index). Follow
  the reference exactly, including R and cycles.
- **R:** bit 7 is preserved; `LD R,A` sets all 8 bits.
- **OUT counts as a write** for `wrote`.
- **Port address is 16 bits:** high byte = A for `IN/OUT (n)`, B for `(C)`.
- **SMC in work RAM** is safe only because there is no decode cache.
  Document this invariant; it changes in M6.
- **Wrap-safe cycle compares:** `cyc` is 32-bit on N64 and wraps after about
  18 minutes of audio. Always use signed-distance compares.

## 8. Risks (top 5)

1. **Icache:** the hot set outgrowing about 4 KB, or cold warm-up after each
   68k slice eating the gain. Measure continuously; keep hot/cold sections.
2. **Bank switching:** Metal Slug rebanks all four windows about 50 times per
   second. Measured window copies make the flat image about 5–14× costlier
   than rmap plus limit, so the read path is option B (§4.2).
3. **Stop semantics** (loop edge, HALT, event order): mvs64's idle skip
   depends on them. A drift here shows up as audio glitches, not as test
   failures, unless the differential test also compares stop points (it
   does: step count and `last_pc`).
4. **Callbacks:** register-save discipline around C callbacks (o64), and the
   post-callback re-sync (poison, remap). Bugs show only under YM2610 IRQ
   timing, so the differential test must include IRQ-line changes made from
   inside callbacks.
5. **Dcache aliasing** with m64k's pinned data, and slow iteration on an
   N64-only harness.

## 9. Realistic expectations

Budget per instruction with warm caches:

| Component | Cycles |
|---|---|
| Dispatch | 7–8 |
| Cycle/event check | 2 |
| Count | 1 |
| Body | 3–12 |

- Weighted over the Metal Slug mix, that's about **25–32 cycles with the flat
  image and 33–40 with rmap+limit**, before cache misses.
- A realistic first full version is 40–55 cycles (0.45–0.6 µs, 3–4×).
- If that's not enough, the next step is **pre-decoded micro-op pages**, not
  a dynarec:
  - Store handler address plus operand word per 256-byte page.
  - Dispatch becomes `lw; lw; jr`.
  - Invalidate a page on bank switch and on writes to it.
- Reserve for it now:
  - add `z80_invalidate(addr, len)` to the API (a no-op until M6)
  - keep `z80_run`'s contract unchanged

## 10. Reference data

**Metal Slug Z80 opcode mix** (mvs64 PC build, 13.76M instructions; prefixes
counted as their own entries):

| Opcode | Share | | Opcode | Share |
|---|---|---|---|---|
| FD prefix | 8.35% | | JR Z (28) | 7.37% |
| AND A (A7) | 7.35% | | LD HL,nn (21) | 6.01% |
| LD A,(HL) (7E) | 6.00% | | JP Z (CA) | 5.07% |
| INC HL (23) | 4.76% | | LD A,(nn) (3A) | 3.54% |
| LD (HL),A (77) | 3.08% | | AND n (E6) | 2.31% |
| LD L,A (6F) | 2.18% | | ED prefix | 2.12% |
| CALL NZ (C4) | 2.04% | | EX AF,AF' (08) | 1.70% |
| CALL (CD) | 1.63% | | JR NZ (20) | 1.48% |
| RET (C9) | 1.44% | | CP (HL) (BE) | 1.38% |
| DD prefix | 1.27% | | CB prefix | 1.16% |

- Inside FD: `FD CB` is 3.67%, `LD IY,nn` 1.22%, `LD IY,(nn)` 0.76%,
  `LD D,(IY+d)` 0.75%.
- Inside ED: `LD DE,(nn)` 0.75%, SBC/ADC HL 0.28% each.
- The top ~60 opcodes cover 95%.

**Measured costs:**
- C core: 1.85 µs/instruction on mvs64 main (PR #19), 1.65 µs after PR #21.
- C core replaying the Metal Slug traces in the testsuite ROM (ares):
  1.63 µs (busiest second) and 1.64 µs (10 s); samsho2 2.05 µs.
- C core synthetic in-cache loop (`LD A,(HL); AND A; INC HL; JR`): 0.94 µs.
- C core real driver, isolated: 1.87 µs.

**The game workload:**
- Metal Slug mission: 370k–455k Z80 instructions per emulated second
  (corrected; not 1M), with the YM2610 timer A firing about 400×/s and
  about 1,300 instructions per tick.
- Recorded traces (mvs64 `MVS64_Z80TRACE`, in gitignored `test/traces/`):
  Metal Slug 42–43 s (454,792 instructions), 36–46 s (4.33M), samsho2
  30–35 s (166,202).
- samsho2: about 1.74M instructions per 50 s.

**VR4300:**
- 16 KB direct-mapped icache (32 B lines); 8 KB direct-mapped dcache
  (16 B lines).
- One branch delay slot, a 1-cycle load-use interlock, no branch predictor.
- Count register at 46.875 MHz.

## 11. Workflow

- Work in feature branches, open a PR on the GitHub repo
  (https://github.com/mike-r129/N64-Z80, private), and merge
  it with a merge commit.
- No `Co-Authored-By` trailers and no "Generated with Claude Code" lines in
  commits or PR bodies (the owner's global rule).
- Each milestone's PR body includes the differential count, ZEX status, and
  before/after µs/instruction.
- Keep `docs/measurements.md` as an append-only log: date, commit, ROM, metric,
  value.
- The toolchain is the libdragon toolchain in WSL at `/root/n64inst`, with
  `N64_INST=/root/n64inst`. mvs64's README documents the setup; its libdragon
  fork is `mike-r129/libdragon`.

## 12. Seed material (`seed/`, adopted in M0 and removed)

- **`seed/reference/`:** `z80.c`, `z80.h` and `z80.LICENSE` from mvs64 commit
  54f7973 (PR #21). This is the exact behaviour to match. Note its mvs64
  coupling, which the test build must stub:
  - `z80_hot` (pinned to `.rodata.z80_hot`)
  - the `z80_anchor` reference under `#ifdef N64`
  - `MVS64_Z80OPHIST`
- **`seed/harness/zdiff/`:** the PC differential harness (`main.c`, `wrap.c`,
  `zdiff.h`, `run.sh`, `mut.sh`). It compiles two cores side by side with
  hidden visibility and `objcopy --localize-hidden`. The paths in the
  scripts point at the old session's scratchpad: fix them. Port the logic
  to the N64 test ROM, and keep the PC version for C-vs-C checks of the
  reference.
- **`seed/harness/zextest.c` and `zex.sh`:** the CP/M ZEX harness (PC).
- **`seed/harness/z80bench_old.c`:** the old in-mvs64 synthetic and
  real-driver benchmark (for reference only; it uses a removed API).
