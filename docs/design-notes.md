# Design notes

Decisions and open questions that refine [PLAN.md](../PLAN.md). Entries are
dated; a later entry can supersede an earlier one. Nothing here overrides the
exactness rule: the reference core (`reference/z80.c`) defines behaviour.

## 2026-10-05: M0 review of PLAN.md

A review of PLAN.md §3–§7 against `reference/z80.c` and mvs64's
`sound_neogeo.c`, with a Fable 5.1 advisor pass on the low-level items.
These are proposals to settle in M1, not yet changes to PLAN.md.

### 1. Loop edge: compare Z80 addresses, not host pointers (§4.1 t8)

The reference stops after any instruction whose new 16-bit PC is ≤ its own
address, after interrupt service. Two consequences:

- Host pointers are not monotonic across rmap pages (fixed ROM, bank windows
  and work RAM are separate host buffers), so comparing host PCs is wrong
  for any transfer between mapping regions.
- Sequential execution that wraps 0xFFFF → 0x0000 is also a loop edge, so
  "only control-transfer handlers can produce PC ≤ PC0" is false. The random-PC
  differential test will hit this.

Proposed representation (works for both §4.2 options):

- `s5` = host pointer to the next byte (fetch stays `lbu op, 0(s5)`), plus a
  `bias` register = `s5 − Z80 PC`, which is exactly the rmap page entry.
  The Z80 PC is `s5 − bias`; an instruction's PC0 is that minus its static
  length so far (1; 2 for CB/ED/DD/FD; 4 for DDCB). No per-instruction `t8`.
- Control transfers compute the 16-bit target, compare it with PC0 (`sltu`,
  exact across pages and wrap), and remap on every taken transfer (under
  option B a same-page test costs as much as the remap).
- The page-limit / image-end check folds into the per-instruction cycle check
  (see 3): option B keeps a per-page limit (end of the contiguous host region
  minus 3); the slow path copies the ≤ 4 straddling bytes with 16-bit wrap.
  Option A needs the 4 bytes after the image to read as Z80 0x0000–0x0003
  (a mirrored tail kept coherent by the write stub, or a TLB alias).

### 2. `wrote` / `wrote_any` become core-managed

The reference core never sets `wrote`: `z80_run` clears it before each
instruction and mvs64's `z80_write` / `z80_out` callbacks set it. The asm
core must track it itself, because direct (wmap) stores call no callback.
Match mvs64's semantics exactly: set on every memory write (including writes
the owner ignores, such as ROM addresses, and direct-page stores) and every
OUT, never on IN; interrupt-accept pushes count. `z80_step` sets `wrote` if
the instruction wrote and never clears it. The core overwrites `wrote` /
`wrote_any` at exit, so owner callbacks that still set `cpu.wrote` are
harmless. Document this in the API.

### 3. Cycle counter: off by one in §4.4

The reference continues while `(long)(until − cyc) > 0`. With
`s6 = until − cyc` the stop test is `blez`, not `bltz`; `bltz` runs one
extra instruction exactly when a budget lands on a YM timer deadline, which
is constantly. Recommended: count up, `s6 = cyc − until`, charge with
`addiu s6, +N`, stop on `bgez s6` (poison = any value ≥ 0 after saving the
real s6), and `cyc = until + s6`. The first instruction runs unconditionally.

### 4. Bus-event cycle stamps: charge where the reference charges

Callbacks see `cyc` mid-instruction, and the reference adds cycles at
different points relative to the bus access, so a single per-handler charge
gives wrong stamps. Place each `addiu s6` exactly where the reference adds:

| Instruction | Reference order |
|---|---|
| everything | base (`cyc_00` / `cyc_ed` / `cyc_ddfd`) before the body |
| CALL cc taken | push at base, then +7 |
| RET cc taken | +6 (no bus access after it) |
| interrupt accept | +11 / +13 / +19 before the push |
| CB | +8 on entry; (HL) rotates/RES/SET +7 before the write-back; BIT (HL) +4 |
| DDCB / FDCB | entry charge 0 (`cyc_00[DD]` = `cyc_ddfd[CB]` = 0): write stamped at base, then +20 / +23 |
| block repeat | bus at base, +5 after; **OTDR adds no +5** (reference quirk) |

The write stub never touches `s6`; it computes `cyc = until + s6` only on the
callback path. IM0 (executes `int_data` as an opcode) can stay on the C
fallback permanently; Neo Geo uses IM1.

### 5. What callbacks can see and change

- Before `port_in` / `port_out`: write back the full state (registers,
  materialised R, WZ, PC, `cyc`, IFFs). ZEX's BDOS reads C/D/E; mvs64's YM
  timer start reads `cpu.cyc` inside `port_out`.
- Before `write_byte`: `cyc` (PC undefined).
- After any callback, including `write_byte` (SMS/MSX mappers bank-switch on
  memory writes): reload events / `ev_mask` / IFF1, re-derive the PC mapping
  from rmap, poison if `events & ev_mask`.
- Callbacks may change only `irq_line`, `int_pending`, `nmi_pending`,
  `int_data`, the rmap and the wmap. Register writes from callbacks are lost.

### 6. §4.2 cost model: the 500/s threshold is size-blind

Advisor model: cached memcpy ≈ 3 RDRAM line transfers per 16 B (source fill,
destination write-allocate, later write-back) ≈ 7–8 CPU cycles/byte, so
2 KB ≈ 15k, 16 KB ≈ 120k cycles; ≥ 8 KB also flushes the whole dcache
(the Z80 block and m64k's pinned set reload). Option B's extra cost is about
5–6 cycles × ~1M instructions/s ≈ 5.5M cycles/s, so option A breaks even at
roughly 300 switches/s for 2 KB windows but only ~40/s for 16 KB windows.

Decision rule: measure the per-window rate of switches that actually change
the bank, in both games, and take option A iff
Σ rate_w × cost_w < 0.5 × 5.5M cycles/s, with cost_w measured by the
testsuite's `[BENCH] window copy` lines. Note the copy would run inside
`port_in`, which mvs64 sometimes enters from the 68k MMIO exception handler.

Option A2 (advisor): TLB-map the 64 KB image so ROM and windows 0–2 alias
`M_ROM` directly (a bank switch is a `tlbwi`, no copy, no flush), with only
the 0xF000 page (2 KB window 3 + work RAM) as real memory. Writes still go
through the wmap, so the plan's objections to TLB mapping (write trapping)
don't apply; needs a check of m64k's TLB budget.

### 7. Other reference quirks to keep (§7 additions)

- WZ: only LDIR / LDDR / CPIR set it on a repeat; CPDR, INIR, INDR, OTIR, OTDR
  don't. `JR e` (0x18) and `JP (HL)` don't set it; DD/FD E9, JR cc and DJNZ
  do. `IN A,(n)`: `(A_old << 8) | (A_new + 1)`; `OUT (n),A`:
  `(port + 1) | (A << 8)`, both with the carry unmasked. Only `IN A,(C)` /
  `OUT (C),A` of the (C) forms set it. `BIT n,(HL)` reads WZ's high byte,
  so WZ must be exact after every instruction (no lazy WZ).
- R: DD-fallthrough +2, DD DD op +3, halted NOP +1, interrupt accept +1
  (IM0 +2: the accept plus the executed opcode).
- `INC rr` / `DEC rr` need a 16-bit mask; never rely on a wrap alias.
- Poison triggers include every `ev_mask` change: DI, RETN, interrupt accept,
  EI's delayed IFF1. `slow_exit` re-checks `events & ev_mask` after its own
  interrupt push.
- The rmap lives in the owner's block (mvs64: `z80_hot`, pinned at page
  offset 0xF0): include it in the §4.6 dcache-set plan.

### 8. Testing notes from M0

- ZEXDOC is 5.76G instructions (46,734,978,649 cycles); on the N64 C core
  that is hours. The normal ROM run checks every group of at most
  `ZEX_MAX_STEPS` instructions (default 5M: 35 of 67 groups) against exact
  per-group steps/cycles from the PC build (`test/zex_expect.h`);
  `ZEX_MAX_STEPS=0` runs all 67.
- `long` is 32 bits under o64, so the harness folds `cyc` into 64 bits.
- The trace-replay bench needs a Z80 snapshot dump from mvs64 (a separate
  mvs64 change); until then the bench is synthetic.

## 2026-10-05 (late): traces, corrected rate, §4.2 decided

- **Traces.** mvs64 PR #22 added `MVS64_Z80TRACE`, a recording of every
  owner action (runs, steps, IRQ/NMI, idle-skip writes, bank switches, IN/OUT
  with cycle stamps). `test/replay.c` ports mvs64's reference replay; the
  testsuite replays every `test/traces/*.z80t` on REF (timed), NEW (must be
  clean) and MUT1 (must be caught). This is both the speed benchmark on real
  driver code and a correctness test that covers IRQ changes made inside
  port callbacks (PLAN.md §8 risk 4).
- **Rate correction.** Metal Slug runs 370k–455k instructions per emulated
  second, not 1M. Root cause on the mvs64 side, as far as I can tell from
  `platform_n64.c`: under `MVS64_DET_AUDIO` the pump loop stops when
  `filled * n >= det_samples`, but `n` is the AI buffer length (libdragon:
  `freq / 25` rounded down to 8 = 1,760 samples) and `det_samples` is 735,
  so each emulated frame generates 1,760 samples, about 2.4 frames of audio.
  That makes N64 `[SNDRMS]` intervals about 2.3 s long and DET `snd%`
  figures about 2.4× too high. Release builds fill by ring level and are not
  affected. To be confirmed in mvs64 (not edited from here).
- **Target.** Requirement `t ≤ B / 455k`; the plan's implied B = 0.4 s/s
  gives 0.88 µs. The design target stays ≤ 0.45 µs (PLAN.md §1).
- **§4.2: option B.** Measured copy costs make the flat image cost about
  140 ms/s at Metal Slug's switch rate, against 10–30 ms/s for rmap plus
  limit (PLAN.md §4.2).
- **History note.** Commit 58b1194 ("use the n64z80 code prefix") also
  contains outside edits to PLAN.md and KICKOFF.md made while it was being
  prepared (the measured bank-switch rates, the hybrid option, the pointer to
  mvs64's `Z80-INTEGRATION-PLAN.md`). The content is intended; only the
  commit message under-describes it.

## 2026-10-05 (later): measured Z80 budget

- mvs64 confirmed and fixed the DET_AUDIO pump (mvs64 PR #23): DET builds
  now generate exactly one guest frame of audio per pump, and the N64 build
  matches the PC build's Z80 instructions per second interval by interval.
  Correction to the previous entry: N64 audio runs at 11,025 Hz, so the bug
  was a 440-sample AI buffer per 184-sample frame, not 1,760 per 735; the
  ~2.4× ratio and the conclusion are unchanged.
- The real budget is measured (`test/traces/mvs64-budget.md`, now in
  PLAN.md §1): sound ≈ 1,040 ms per audio second in the mission (Z80 673,
  YM2610 166, other ~200), non-sound ≈ 14.8 ms per guest frame. The Z80
  needs ≤ 0.81 µs/instr for 20 fps, ≤ 0.63 for 25, ≤ 0.45 for 30. The design
  target (≤ 0.45 µs, M4 exit) is the 30 fps point; the M3 exit (≤ 0.6 µs)
  is already past the 25 fps point.
- mvs64 PR #21 is merged, so `reference/` equals mvs64 `main` (d04c08f).

## 2026-10-05 (M1): the asm run loop

M1 puts `n64z80_run` in asm (`n64z80_asm.S`) with every instruction still
executed by the C fallback, so the loop, register file, PC mapping, event
handling, lazy R and `wrote` tracking are tested before any handler exists.
A Fable 5.1 advisor reviewed the design; its corrections are folded in.

- **Registers.** s0 A, s1 F, s2 HL, s3 DE, s4 BC, s7 SP; s5 host pointer
  to the next byte; s6 cycles; s8 instruction count; a0 the owner's `z80*`
  (any struct, so mvs64's `z80_hot.cpu` works unchanged); v1 PC bias; a3
  fetch limit; a2 `z->rmap`; t8 the Z80 PC of the current instruction.
  WZ stays in the struct (`sh` truncates for free). The caller-saved ones
  are reloaded after every C call.
- **pc0 is computed in the dispatch** (`subu t8, s5, v1` fills the lw→jr
  interlock, so it is free). This supersedes item 1's "no per-instruction
  t8"; t8 gives the loop-edge test, `last_pc` and the fallback's PC.
- **PC mapping.** Z80 PC = s5 − v1 with v1 = rmap[page]. The fast fetch
  runs while s5 < a3 = host end of the page − 4 (−4, not −3: the opcode
  byte is read before the check, and on page 0xFF it keeps every fast
  instruction's next PC ≤ 0xFFFF, so a sequential wrap only happens in the
  fallback). Past it, `refetch` extends a3 by 256 when the next page has
  the same rmap entry (same host region; never past page 0xFF), otherwise
  the instruction runs in the C fallback.
- **Cycles and poisoning** (item 3 plus a better poison). s6 = cyc − cbase
  counts up and the tail stops on `bgez s6`; cyc = cbase + s6 holds
  everywhere, so callbacks always see the exact `cyc`. cbase is `until`,
  except that poisoning (events & ev_mask may be nonzero) does
  `cbase += s6; s6 = 0`. `slow_exit` restores cbase = until and follows the
  reference order: interrupt service (C), HALT stop, cycle and loop-edge
  stop, then the next iteration's IRQ re-assertion and HALT NOP. Dispatches
  out of `slow_exit` and at entry skip the cycle test (the first
  instruction always runs).
- **s8 is 1-based**: dispatch increments it, so during instruction k and
  its interrupt service s8 == k. Lazy R is `rhi | ((rbase + s8) & 0x7F)`;
  the fallback re-executes the instruction's R increments, so it gets
  `rbase − 1` first. `wrote`: the write/OUT hooks store s8 in `lastw`;
  wrote = lastw == s8, wrote_any = lastw != 0.
- **C fallback.** `build/n64z80_ref.c` is reference/z80.c with its
  `write_byte` / `port_out` calls rewritten (sed, checked) to hooks that set
  `wrote` and `lastw` before calling the owner. The library's symbols are
  `n64z80_*` (`n64z80.h`); the struct is the reference's, layout
  static-asserted against `n64z80_offsets.h`.
- **ZEX through z80_run.** `zex_expect.h` now also holds each group's
  instruction and cycle counts when driven by `z80_run` (the stop after the
  final OUT overshoots differently from `z80_step`); the testsuite runs the
  asm core's prelim, ZEXDOC and ZEXALL subsets in that mode.

For M2 (from the advisor's review):

- **DD/FD chains** consume any number of prefix bytes in one instruction
  (the reference recurses), so "≤ 4 bytes per instruction" fails. A prefix
  handler must repeat the limit check before it changes any state (R,
  cycles), so a refetch mid-chain can rewind to t8 and hand the whole
  instruction to C.
- **Loop-edge transfers** store `z->pc` and enter `slow_exit` without
  remapping: interrupt service can still continue the run (JR back from
  0x20, then an IM1 accept to 0x38 > 0x20).
- With the fallback disabled (M4), a straddling instruction needs a bounce
  buffer: copy ≤ 4 bytes with 16-bit wrap into .sdata and point s5/v1 at it.

## 2026-10-06 (M2): an asm handler for every opcode

M2 went further than its "top 20" scope: every unprefixed, CB, DD/FD,
DD/FD CB and ED opcode now has an asm handler, so the C fallback only runs
prefix chains (DD DD, FD ED, ...) and instructions that straddle a mapping
boundary; on the three traces it runs 0 instructions. Interrupt service and
`z80_step` are still the reference's C (M4).

- **Prefixes change no state.** CB/DD/ED/FD handlers only read the next
  byte and jump through that prefix's table; the target handler charges the
  whole instruction's cycles and the second R increment, so any table entry
  can be `pfx_fallback` (rewind to pc0, whole instruction in C). One prefix
  plus operands is at most 4 bytes, which the dispatch's limit check already
  guarantees. DD/FD before an opcode exec_opcode_ddfd doesn't handle runs
  the unprefixed handler after `cyc_ddfd[op]` (`ddfd_base`). The tables are
  built by GAS from the handlers that exist and from case lists that
  `tools/gen_tables.py` extracts from the reference (which DD/FD opcodes are
  index forms, which ED opcodes exist), together with the cycle tables and
  sz53p, so nothing is transcribed by hand.
- **Reference quirk found by the differential test:** `BIT n,(HL)` writes
  the (unchanged) byte back after its +4 cycles (`exec_opcode_cb` writes
  whenever the operand is (HL)). It is a bus event and sets `wrote`; the asm
  does the same. DD/FD CB `BIT` does not write.
- **Write page map.** `n64z80_set_wmap()` lets the owner mark pages whose
  writes are plain stores (work RAM): `wr8` stores directly instead of
  calling `write_byte`. The trace replay maps 0xF800-0xFFFF this way, as
  mvs64 will; zdiff's direct-write mode uses it on the asm core.
- **Tools.** zdiff bisects a reported mismatch to its first divergent
  instruction (it found the BIT write in one run); `make PROF=1` builds a
  sampling per-opcode cycle profile of the asm core on the traces.

Performance findings (all A/B measured, see measurements.md):

- **The core is icache-bound.** Inlining the 10-instruction dispatch in
  every handler made the core ~55 KB; replacing it with one shared
  `dispatch` (each handler ends `b dispatch` with its last instruction in
  the delay slot) was -10% on Metal Slug, -26% on samsho2. Code size beats
  instruction count here.
- **Measure with the layout pinned.** Every core edit moved the harness's
  code in the direct-mapped icache and changed timings by up to +-15%
  (the C core's own trace time moved too). The testsuite now links the core
  last, in its own sections, on a 16 KB boundary (`N64Z80_ICACHE_ALIGN`),
  so the harness stays put and only the core's own layout varies; compare
  timings only between builds with the same test knobs (they change the
  harness's size).
- **Hot/cold sections** (the Metal Slug profile's top ~60 opcodes, the
  dispatch, the run loop and the shared tails in `.text.n64z80hot`, about
  6.6 KB) gain 3% / 9% once the layout is pinned; before pinning, the same
  change measured as a loss.
- Remaining cost: ~61 cycles per instruction on Metal Slug (C core 152),
  against ~20 instructions for a simple op: the rest is cache misses. Port
  instructions cost 500-900 cycles each (full state sync around the owner
  callback). M3's exit (<= 0.6 us) and M4's (<= 0.45 us) are not reached
  yet.

## 2026-10-06 (M3): layout, R in a register, run overhead

M3's exit (<= 0.6 us/instr on the Metal Slug trace) is reached: 0.577 us,
2.9x the C core in the same build. A Fable advisor review of the M2 core
(cycle budget, map files, pipeline hazards) set the order of the work.

- **One code section.** GAS rounds a MIPS section's size up to its
  alignment, so the 16 KB-aligned hot section was 16 KB long and the cold
  code started on the hot block's icache lines. Hot and cold are now
  subsections 0 and 1 of `.text.n64z80`, so the cold code follows the hot
  block directly. Port I/O and EI/DI joined the hot list (few, but each
  costs hundreds of cycles).
- **R's prefix increment in `$at`.** `$at` is free under `.set noat`. The
  prefix handler counts R's second increment in its `jr` delay slot
  (pfx_fallback takes it back), instead of a load/add/store in every
  prefixed handler: 9 KB less code, -5% on the trace. C clobbers `$at`, so
  it lives in the struct's R across call_c (save_state/load_state) and on
  the stack across the write callback; libdragon's exception handler saves
  it.
- **Run entry and exit.** BC/DE load and store as one unaligned word
  (lwl/lwr), and a loop edge whose rCYC is still negative stops at once:
  not poisoned means cbase == until and nothing to service. The scan-loop
  bench (a z80_run call every 4 instructions) went 81.4 -> 73.6 cycles per
  instruction; per-run overhead matters because mvs64 runs to the next loop
  edge (Metal Slug: 46 instructions per run).
- **What ares charges** (calibrated by inserting 32 instructions in the run
  entry): 1 cycle per instruction, 2 per load or store even on a cache hit,
  and no load-use interlock. Pipeline-hazard fixes therefore only show on
  hardware; fewer loads show in both.
- **Data layout is a small lever.** Padding the core's data by 1/2/4 KB
  moved the asm core's trace time by at most 2.4% (the C core's by up to
  27%), so the advisor's proposed 8 KB-aligned table block was not done.
- samsho2's short trace (11 instructions per run, dominated by EI/OUT/DI
  and run overhead) moves +-3% with any layout change; Metal Slug is the
  metric.

## 2026-10-06 (M4): no C left, and the layout is the performance

The core no longer needs the reference: `N64Z80_C_FALLBACK=0` (the default)
builds without it, and a table entry without an asm handler is a build
error. What moved to asm:

- **Interrupt service** (EI delay, NMI, IM 1, IM 2, IM 0). IM 0 executes
  `int_data` from the bounce buffer as the opcode at PC - 1 followed by the
  bytes at PC, without counting an instruction; the run is poisoned so its
  tail returns through `slow_exit`, which sees `n64z80_im0` and resumes at the
  stop test (the reference services once per instruction). Every EI used to
  call C: samsho2 -9%.
- **`z80_step`**: a run with `until = cyc` and no `last_pc`. It costs more
  than the C step on a step-only loop (226 vs 106 cycles), but mvs64 steps
  rarely (512 steps per 93k runs on Metal Slug).
- **Prefix chains** (DD DD, FD ED, ...): a further prefix runs as a new
  prefix after `cyc_ddfd[op]`, as in the reference. Two reference behaviours
  the 20k/100k-case differential test then found: a block instruction in a
  chain repeats from the ED byte, not the first prefix (PC - 2), and LD A,R /
  LD R,A inside a chain see R one higher per prefix (the reference takes one
  increment back after each `exec_opcode_ddfd` level).
- **Straddling instructions** run from a 4-byte bounce buffer (`rLIM = 0`,
  so the next dispatch maps the PC again: `unbounce`). Wrapping past 0xFFFF
  is the only sequential pc <= pc0, so bounce and unbounce run the stop
  test; callbacks inside a bounced instruction keep the bounce (load_state's
  16-bit PC would hide the wrap). zdiff has a split-mapping mode (odd pages
  read from a mirror) that makes every page boundary a straddle.

Performance (Metal Slug trace, ares; 577 at M3):

- **Data layout by dcache set is worth more than any instruction trim.** An
  unlucky position of the dispatch tables against the replay's rmap/RAM cost
  29% (762 vs 593 ns); now the core's data is an 8 KB-aligned block with the
  hot part (optab, fdtab, sz53p, cycdd, variables, the save area) in sets
  0x000-0xAEF, and the owner's per-instruction data belongs in 0xB00-0x1FFF.
  The callee-saved registers and callback slots moved off the stack into
  that block (the core is not reentrant), so the caller's stack depth no
  longer moves them: -2%.
- **The icache holds only the code the traces run.** Hot (6.5 KB) plus the
  cold handlers seen in a full profile of the three traces end below 16 KB;
  everything never seen goes to a third subsection after them, so only it
  shares lines with the hot block: -2% / samsho2 -11%.
- **The harness is part of the measurement.** The same core measured 511 or
  692 ns depending on the testsuite's size, because the replay's code landed
  on the hot block's lines. The replay's code, state and trace buffer are now
  pinned (test/icache_pad.S, TRACE_SHIFT); the trace's own placement moves
  the result by 1-2%. In the game the 68k core evicts far more between
  slices: the trace bench is the core's cost with a light owner, and M5 must
  measure in-game.
- Instruction trims: INC/DEC r and CP flags without the generic add (-1%), a
  push with one wmap lookup (-1%). Tried and dropped: a fast path for
  forward JR (no gain), reordering the prefix tables against the owner data
  (Metal Slug -0.6%, samsho2 +11%).
- **ares's cost model** (measured): 1 cycle per instruction, 2 per load or
  store even on a hit, no load-use interlock; a second Fable advisor review
  put the remaining ~48 cycles at ~37 of instructions (29 in handlers, 5
  per-run entry/exit, 3.5 port I/O) plus ~12 of cache misses.

Result: **0.501 us/instr** on Metal Slug (C core 1.585 in the same build,
3.2x), samsho2 0.79. M4's speed exit (<= 0.45) is not reached. PLAN §9
expected 40-55 cycles for this design (we are at 47); the remaining levers
are a computed-goto dispatch (~1-2 cycles; needs a free register), a lighter
port callback (a contract question), and the pre-decoded pages of M6.

## 2026-10-07 (M5): in mvs64

mvs64 PR #24 (merged) adds `MVS64_ACRC`, a CRC of every generated audio
buffer under DET_AUDIO, validated as the plan asked: two builds differing in
unrelated code print the same stream, a Z80 mutant (AND never sets Z)
diverges at once. A first mutant (BIT without H) never changed Metal Slug's
sound: its driver doesn't look at H after BIT.

mvs64 PR #25 (tested on real hardware 2026-10-07) vendors the core as
`n64z80/` with `Z80_CORE=asm|c` (default `asm`):

- **Placement.** m64k pins its context at dcache page offset 0x8C0-0xEBF, so
  the core's block starts at 0xEC0 (new knob `N64Z80_DCACHE_OFFSET`; hot part
  0xEC0-0x198F) and sound_neogeo.c pins the owner's struct and read map from
  0x1990, the work RAM wrapping to 0x5E8. Only the prefix tables and the
  write map's live line share sets with anything.
- **Gates:** C vs asm in ares with DET_AUDIO + INPUT + ACRC + TRCRC: audio,
  Z80 steps per interval and the 68k state identical over 7,793 frames of
  samsho2 and 9,344 of Metal Slug; the PC gate is unchanged.
- **In game:** the Z80 costs 0.69 us/instruction (C: 1.61), not the bench's
  0.50: the 68k evicts the caches between slices, as expected. Metal Slug's
  mission in a release build goes from ~14 fps with starved sound to ~38 fps
  with sound in real time (no underruns); attract ~36 -> ~48 fps.
