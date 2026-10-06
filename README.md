# N64-Z80: an optimized Zilog Z80 core for Nintendo 64

N64-Z80 (library prefix `n64z80`) is a hand-written MIPS assembly Z80
interpreter for the Nintendo 64 (VR4300). It is the sibling of [m64k](https://github.com/mike-r129/mvs64/tree/main/m64k),
the 68000 core used by the mvs64 Neo Geo emulator, and is meant to replace
mvs64's C Z80 core (the sound CPU) as a drop-in, bit-exact alternative that
runs about 4x faster.

The emulator is meant to run within a [libdragon](https://github.com/DragonMinded/libdragon)
application. It is not compatible with other Nintendo 64 development
environments.

> **Status:** milestone M1 is done: the asm run loop (`n64z80_run`) is in
> place and exact, but every opcode still executes in the C fallback, so it
> is slower than the C core. M2 adds the first asm opcode handlers. Nothing
> to integrate into mvs64 before M4. See [PLAN.md](PLAN.md).

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
