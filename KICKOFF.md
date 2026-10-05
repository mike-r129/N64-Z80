# Kickoff prompt

Paste this as the first message in a new Claude Code session opened in this
folder.

---

We're starting a new project in this folder, **N64-Z80** (library prefix
`n64z80` in the code): a hand-written MIPS
assembly Z80 interpreter for the Nintendo 64 (VR4300, libdragon). It's the
sibling of the m64k 68000 core, and the goal is a drop-in, bit-exact
replacement for the C Z80 core in my Neo Geo emulator, mvs64, about 4× faster.

Read `PLAN.md` fully before doing anything. Then read `seed/README.md` and
skim `seed/reference/z80.h` and `z80.c`; that's the exact behaviour we must
match. For style and structure, look at the m64k core in
`C:\Users\Mike\Desktop\mvs64\m64k\` (`m64k_asm.S`, `Makefile`,
`testsuite.c`, `README.md`), especially its register `#define`s, its
`.sdata` pinning and its testsuite ROM. mvs64's `sound_neogeo.c` shows how
the owner drives the core (`z80_run`, the idle-skip at loop edges, the
NMI/`z80_step` path, the YM IRQ callbacks).

Then start **Milestone M0** from PLAN.md §6:
1. `git init` this folder with `main` as the default branch and add
   `origin` = https://github.com/mike-r129/N64-Z80 (private, currently
   empty). Add:
   - a `.gitignore`: build/, *.z64, *.elf, *.o, and the ZEX ROMs unless
     their license allows committing them
   - a README stub in the m64k style
   - the MIT LICENSE

   Commit that, together with PLAN.md, KICKOFF.md and seed/, as the first
   commit on `main`, and push it. Do the M0 work on a feature branch, then
   PR and merge.
2. Set up the N64 test ROM build (Makefile modeled on `m64k/Makefile`,
   toolchain at `/root/n64inst` in WSL). It should link the reference C core
   (from `seed/reference`, mvs64 coupling stubbed) and run:
   - (a) ZEXDOC with BDOS stubs, printing through ISViewer (`debugf`)
   - (b) the differential harness ported from `seed/harness/zdiff`, C vs C
   - (c) a "done" marker
3. Get it running headless in ares with
   `C:\Users\Mike\Desktop\VSCode Projects\N64-NEOGEO\mvs64\tools\ps-ares-run.ps1`,
   retrying when the first run logs nothing. Confirm C vs C is clean and the
   planted-bug controls are caught.
4. Write `docs/measurements.md` and record the baseline.
5. Bank-switch rates are already measured (PLAN §4.2: Metal Slug about 50
   switches per second on each window), so the read-path choice will be
   decided by the trace bench. For the bench, propose how mvs64 should dump
   a Metal Slug Z80 snapshot (see
   `C:\Users\Mike\Desktop\mvs64\Z80-INTEGRATION-PLAN.md` §1.3). Don't edit
   mvs64 without asking: it's a separate repo with its own branch/PR
   workflow.

Ground rules:
- **Exactness first.** Every asm change is checked by the differential test
  against the reference core. Don't "fix" reference behaviour (IM0, DD/FD
  chains, block-op loop edges, R bit 7), even if it disagrees with a
  datasheet.
- **Measure, don't assume.** Performance decisions (hot/cold sections, flat
  image vs rmap+limit, dcache placement) need a number in
  `docs/measurements.md`. In mvs64, inlining bus checks and growing the hot
  switch past the 16 KB icache both measured slower.
- **Git:** feature branch → PR on GitHub → merge commit. No `Co-Authored-By`
  trailers and no "Generated with Claude Code" lines in commits or PR bodies.
- The repo is private. Pushing branches and opening/merging PRs on it is
  the normal workflow. **Ask before** making it public or changing repo
  settings.
- For low-level design questions (register allocation, pipeline scheduling,
  cache layout), consult a Fable 5.1 advisor subagent when useful.

Start by summarizing your understanding of the plan and the M0 steps in a few
bullets. Flag anything in PLAN.md that looks wrong or underspecified, then
begin.
