#!/bin/bash
# usage: zex.sh <git-ref> <tag> [USE_RUN] : build zextest against <ref>'s z80.c, run prelim+zexdoc+zexall
set -u
D=/mnt/c/Users/Mike/AppData/Local/Temp/claude/C--Users-Mike-Desktop-mvs64/76f3600c-b863-48e8-85c1-608fbb86293e/scratchpad
W=/root/zex/$2; rm -rf $W; mkdir -p $W; cd $W
git -C /mnt/c/Users/Mike/Desktop/mvs64 show $1:z80.c > z80.c
git -C /mnt/c/Users/Mike/Desktop/mvs64 show $1:z80.h > z80.h
gcc -O2 -w ${3:+-D$3} -I. -o zextest $D/zextest.c z80.c || exit 1
R=/root/zex/z80up/roms
./zextest $R/prelim.com 8721 > prelim.txt; echo "prelim exit=$?"
./zextest $R/zexdoc.cim 46734978649 > zexdoc.txt & ./zextest $R/zexall.cim 46734978649 > zexall.txt; wait
for t in zexdoc zexall; do echo "$t: $(grep -c OK $t.txt) OK, $(grep -ci error $t.txt) ERROR; $(tail -1 $t.txt)"; done
