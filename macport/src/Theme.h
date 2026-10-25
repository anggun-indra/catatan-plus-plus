#ifndef THEME_H
#define THEME_H

typedef struct { int style; unsigned fg; unsigned bg; int bold; int italic; } StyleDef;

#ifdef __cplusplus
extern "C" {
#endif

const StyleDef *ThemeForLexer(const char *lexer, int *count);

#ifdef __cplusplus
}
#endif

#endif
