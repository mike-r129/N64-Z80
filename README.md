# N64-Z80: an optimized Zilog Z80 core for Nintendo 64

N64-Z80 (library prefix `n64z80`) is a hand-written MIPS assembly Z80
interpreter for the Nintendo 64 (VR4300). It is the sibling of [m64k](https://github.com/mike-r129/mvs64/tree/main/m64k),
the 68000 core used by the mvs64 Neo Geo emulator, and is meant to replace
mvs64's C Z80 core (the sound CPU) as a drop-in, bit-exact alternative that
runs about 4x faster.

The emulator is meant to run within a [libdragon](https://github.com/DragonMinded/libdragon)
application. It is not compatible with other Nintendo 64 development
environments.

> **Status:** early development (milestone M0: test harness and baseline
> measurements). There is no assembly core yet. See [PLAN.md](PLAN.md).

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

To be written once the core exists (milestone M1). The API contract is in
[PLAN.md §3](PLAN.md).

## Testing

Everything runs on N64 (in ares, or on real hardware). `make` builds
`n64z80_testsuite.z64`, a single ROM that links every core under test and
runs:

* a differential test: random CPU states and memory, both cores run the same
  case, and the full state, every bus event (with its cycle stamp), the
  memory image and the stop point must match. Planted-bug mutants of the
  reference (`test/mutants/`) must each be caught;
* the prelim and ZEXDOC instruction exercisers with CP/M BDOS stubs, checked
  per test group against exact instruction and cycle counts;
* benchmarks (COP0 Count around `z80_run`).

Every verdict line starts with `>>> PASS` or `>>> FAIL`. Until milestone M1
the candidate core is the reference itself, which validates the harness.

```sh
# in WSL, with the libdragon toolchain
export N64_INST=/root/n64inst
make                    # fetches the ZEX ROMs once, builds the ROM
make ares               # runs it headless in ares, stops at the done marker
make pc                 # host build of the same harness (build/pc/zpc)
make ZEX_MAX_STEPS=0    # all 67 ZEXDOC groups (hours on N64)
```

`tools/ares-run.ps1` can also be run directly from PowerShell; set
`ARES_EXE` if `ares.exe` is not on the PATH. Measurements are logged in
[docs/measurements.md](docs/measurements.md) and design decisions in
[docs/design-notes.md](docs/design-notes.md).

## License

MIT, see [LICENSE](LICENSE). The reference C core keeps its own MIT notice.
