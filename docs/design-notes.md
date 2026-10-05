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
