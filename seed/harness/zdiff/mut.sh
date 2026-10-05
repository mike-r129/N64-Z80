#!/bin/bash
# Negative controls: two planted bugs must be caught.
D=/mnt/c/Users/Mike/AppData/Local/Temp/claude/C--Users-Mike-Desktop-mvs64/76f3600c-b863-48e8-85c1-608fbb86293e/scratchpad/zdiff
R=/mnt/c/Users/Mike/Desktop/mvs64
for m in 's/(val \& (FLAG_Y | FLAG_X)) | FLAG_H;/(val \& (FLAG_Y | FLAG_X));/' 's/z->r = (z->r \& 0x80) | ((z->r + 1) \& 0x7f);/z->r = z->r + 1;/'; do
  rm -rf /root/zmut; mkdir -p /root/zmut; git -C $R show main:z80.c | sed "$m" > /root/zmut/z80.c; git -C $R show main:z80.h > /root/zmut/z80.h
  cmp -s /root/zmut/z80.c <(git -C $R show main:z80.c) && echo "mutation did not apply: $m"
  bash $D/run.sh main /root/zmut 20000 | tail -1
done
