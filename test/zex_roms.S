# The CP/M exercisers, embedded as read-only data. The files are fetched by
# the Makefile into test/roms/ (GPLv2, not committed: see test/roms/README.md).
    .section .rodata.zexroms, "a"

.macro rom name, file
    .balign 16
    .globl zex_\name, zex_\name\()_end
zex_\name:
    .incbin "\file"
zex_\name\()_end:
.endm

    rom prelim, "test/roms/prelim.com"
    rom zexdoc, "test/roms/zexdoc.cim"
    rom zexall, "test/roms/zexall.cim"
