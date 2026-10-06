# N64-Z80: an optimized Zilog Z80 core for Nintendo 64

N64-Z80 (library prefix `n64z80`) is a hand-written MIPS assembly Z80
interpreter for the Nintendo 64 (VR4300). It is the sibling of [m64k](https://github.com/mike-r129/mvs64/tree/main/m64k),
the 68000 core used by the mvs64 Neo Geo emulator, and is meant to replace
mvs64's C Z80 core (the sound CPU) as a drop-in, bit-exact alternative that
runs about 4x faster.

The emulator is meant to run within a [libdragon](https://github.com/DragonMinded/libdragon)
application. It is not compatible with other Nintendo 64 development
environments.

> **Status:** milestones M1-M3 are done and M4's coverage: the core is all
> asm (no C fallback in the default build) and bit-exact (differential test,
> ZEXDOC/ZEXALL, recorded Metal Slug traces), at 0.50 µs per instruction on
> the Metal Slug trace, 3.2x the C core; M4's 0.45 µs target is not reached
> yet. mvs64 integration (M5) is next. See [PLAN.md](PLAN.md).

## Features

The goal is a very fast core that is exact, not just accurate: it must match
the reference C core (superzazu/z80 as tuned in mvs64) bit for bit. In
particular:

* All Z80 opcodes, including the undocumented ones and the undocumented
  Y/X flags, MEMPTR (WZ) and the R register.
* Exact per-instruction cycle counts, and exact cycle stamps on every bus
  access (memory writes, IN, OUT). Cycle accuracy *within* an instruction is
  not a goal.
* The same API and struct layout as mvs64's `z80.h` (`z80_run`, `z80_step`,
  `z80_gen_int`, `z80_gen_nmi`), selectable at build time.
* No Neo Geo-specific code, so other N64 emulators with a Z80 (Master System,
  Game Gear, ColecoVision, MSX) can use it.

## How to use n64z80 in your emulator

**Files.** `n64z80.h`, `n64z80_offsets.h`, `n64z80.c` and `n64z80_asm.S`,
plus `n64z80_tables.h`, which `tools/gen_tables.py` generates from the
reference core's cycle and flag tables (`python3 tools/gen_tables.py
reference/z80.c > n64z80_tables.h`; ship the generated file if you don't
vendor the reference). Assemble `n64z80_asm.S` with the directory of the
generated header on the include path. The core's private data is
gp-relative (`.sdata`) and it uses `$at` internally; it is not reentrant
(one CPU per program).

**API.** The struct and the functions are mvs64's `z80.h` with an `n64z80_`
prefix: `n64z80_init`, `n64z80_run(z, until, &last_pc)`, `n64z80_step`,
`n64z80_gen_int`, `n64z80_gen_nmi`, with the same behaviour down to the cycle
stamps of bus accesses and `z80_run`'s stop points ([PLAN.md §3](PLAN.md)).
One difference: the core sets `wrote` / `wrote_any` itself, so callbacks
don't need to.

**Memory.** Reads and instruction fetches go through `z->rmap` (`byte at
addr = *(uint8_t*)(rmap[addr >> 8] + addr)`), writes through `write_byte`.
`n64z80_set_wmap(wmap)` lets pages whose writes are plain stores (work RAM)
skip `write_byte`. Callbacks may bank-switch (change the rmap or wmap
entries), raise or lower interrupts and change `int_data`; the core remaps
the PC and checks for events after every callback. Before `port_in` /
`port_out` the whole struct is current; before `write_byte` only `cyc`.

**Speed.** On the Metal Slug sound-driver trace the core runs 0.50 µs per
Z80 instruction on an N64 (the reference C core 1.59). Most of the
remaining cost is cache misses, so placement matters as much as code:

* the core's data is one block; with `-DN64Z80_DCACHE_ALIGN` it starts on
  an 8 KB boundary and its hot part uses dcache sets 0x000-0xAEF. Keep the
  data your emulator touches on every Z80 instruction (the rmap, the wmap,
  the Z80 work RAM, the `z80` struct) in sets 0xB00-0x1FFF;
* the first ~6.5 KB of `.text.n64z80` is the hot code, followed by the
  handlers real drivers use and then the rest; with `-DN64Z80_ICACHE_ALIGN`
  the block starts on a 16 KB boundary. Code your emulator runs between and
  inside `z80_run` calls (the scheduler, port handlers) is best kept off the
  hot block's icache lines;
* `n64z80_step` costs about twice a C step: call `z80_run` where you can.

`-DN64Z80_C_FALLBACK=1` links the reference as a fallback for table entries
without an asm handler (there are none; it is a debugging aid).

## Testing

Everything runs on N64 (in ares, or on real hardware). `make` builds
`n64z80_testsuite.z64`, a single ROM that links every core under test and
runs:

* a differential test: random CPU states and memory, both cores run the same
  case, and the full state, every bus event (with its cycle stamp), the
  memory image and the stop point must match. Planted-bug mutants of the
  reference (`test/mutants/`) must each be caught;
* the prelim, ZEXDOC and ZEXALL instruction exercisers with CP/M BDOS stubs,
  driven through `z80_run` and checked per test group against the
  reference's exact instruction and cycle counts;
* replays of recorded mvs64 sound-driver traces (`test/traces/*.z80t`,
  gitignored because they contain game ROM; packed into the ROM when
  present): every recorded step count, state hash, IN/OUT and RAM checkpoint
  must match, and the replay time is the speed benchmark on real driver code;
* benchmarks (COP0 Count around `z80_run`).

Every verdict line starts with `>>> PASS` or `>>> FAIL`. The candidate is
the asm core; the PC build (`make pc`) also runs the reference against an
unmodified copy of itself, to validate the harness.

```sh
# in WSL, with the libdragon toolchain
export N64_INST=/root/n64inst
make                    # fetches the ZEX ROMs once, builds the ROM
make ares               # runs it headless in ares, stops at the done marker
make pc                 # host build of the same harness (build/pc/zpc)
make ZEX_MAX_STEPS=0    # all 67 groups of both exercisers (many hours on N64)
make ZEX_ONLY=1 ZEX_SETS=2 ZEX_MAX_STEPS=0   # full ZEXALL only
```

`tools/ares-run.ps1` can also be run directly from PowerShell; set
`ARES_EXE` if `ares.exe` is not on the PATH. Measurements are logged in
[docs/measurements.md](docs/measurements.md) and design decisions in
[docs/design-notes.md](docs/design-notes.md).

## License

MIT, see [LICENSE](LICENSE). The reference C core keeps its own MIT notice.
