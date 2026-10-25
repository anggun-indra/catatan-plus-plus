#pragma once
#include <stdlib.h>
#include <stdio.h>
static inline char *_itoa(int v, char *buf, int radix) {
    if (radix == 10) { snprintf(buf, 20, "%d", v); return buf; }
    return buf;
}
