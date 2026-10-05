// Harness logging: ISViewer/USB (debugf) on N64, stdout on PC.
#ifndef TLOG_H
#define TLOG_H

#ifdef N64
#include <libdragon.h>
#define tlog(...) debugf(__VA_ARGS__)
#else
#include <stdio.h>
#define tlog(...) (printf(__VA_ARGS__), fflush(stdout))
#endif

#endif
