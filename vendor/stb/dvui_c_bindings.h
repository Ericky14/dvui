// Wrapper header for dvui C bindings (Zig 0.17 translate-c)
// This replaces the removed @cImport in dvui.zig

#define _SETJMP_H 1

#ifdef DVUI_USE_FREETYPE
#include "freetype/ftadvanc.h"
#include "freetype/ftbbox.h"
#include "freetype/ftbitmap.h"
#include "freetype/ftcolor.h"
#include "freetype/ftlcdfil.h"
#include "freetype/ftsizes.h"
#include "freetype/ftstroke.h"
#include "freetype/fttrigon.h"
#else
#include "stb_truetype.h"
#endif

#ifdef DVUI_NO_LIBC
#define STBI_NO_STDIO 1
#define STBI_NO_STDLIB 1
#define STBIW_NO_STDLIB 1
#endif

// stb_image headers are always needed (dvui references the functions)
#include "stb_image.h"
#include "stb_image_write.h"

#ifdef DVUI_USE_ACCESSKIT
// Workaround for a linker symbol clash on aarch64-windows
#define __mingw_current_teb ___mingw_current_teb
#include "accesskit.h"
#endif
