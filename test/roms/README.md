# test/roms

The Z80 instruction exercisers used by the testsuite:

| File | What |
|---|---|
| `prelim.com` | preliminary checks (899 instructions) |
| `zexdoc.cim` | documented-flags exerciser, 67 groups |
| `zexall.cim` | all-flags exerciser, 67 groups |

They are Frank D. Cringle's exercisers (with J.G. Harston's 2002 changes),
licensed **GPLv2**, so they are not committed to this MIT repository. The
Makefile downloads them from superzazu/z80 at a pinned commit and checks
their SHA-256 (`make roms`). Sources: `roms/*.src` / `prelim.z80` in that
repository.
