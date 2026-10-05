#!/bin/bash
# usage: run.sh <ref git-ref> <new: git-ref or "wt" (working tree)> [cases] [seed]
set -e
S=/mnt/c/Users/Mike/AppData/Local/Temp/claude/C--Users-Mike-Desktop-mvs64/76f3600c-b863-48e8-85c1-608fbb86293e/scratchpad/zdiff
R=/mnt/c/Users/Mike/Desktop/mvs64
T=/root/zdiff; rm -rf $T; mkdir -p $T/REF $T/NEW
git -C $R show $1:z80.c > $T/REF/z80.c; git -C $R show $1:z80.h > $T/REF/z80.h
if [ -d "$2" ]; then cp $2/z80.c $2/z80.h $T/NEW/
elif [ "$2" = wt ]; then cp $R/z80.c $R/z80.h $T/NEW/
else git -C $R show $2:z80.c > $T/NEW/z80.c; git -C $R show $2:z80.h > $T/NEW/z80.h; fi
for v in REF NEW; do
  gcc -O2 -w -fvisibility=hidden -DPFX=$v $([ $v = NEW ] && [ -n "$ZD_DIRECT" ] && echo -DTEST_WDIRECT) -I$T/$v -I$S -c $S/wrap.c -o $T/$v.o
  objcopy --localize-hidden $T/$v.o
done
gcc -O2 -I$S -o $T/zdiff $S/main.c $T/REF.o $T/NEW.o
$T/zdiff ${3:-200000} ${4:-1} 2>/dev/null
