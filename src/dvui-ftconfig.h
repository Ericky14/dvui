/* FT_CONFIG_CONFIG_H replacement used only for Zig's translate-c step (see build.zig).
 *
 * On non-Windows targets FreeType's FT_EXPORT expands to
 * __attribute__((visibility("default"))) via FT_PUBLIC_FUNCTION_ATTRIBUTE, and Zig
 * master's translate-c rejects that attribute on every one of the ~120 public
 * declarations. FreeType defines the macro unconditionally in
 * config/public-macros.h, so predefining it does not help; instead pull in the
 * real configuration and then blank the attribute before any declaration uses it.
 * The translated bindings only need the declarations; the library itself is
 * compiled separately and keeps its normal visibility.
 */
#include <freetype/config/ftconfig.h>
#undef FT_PUBLIC_FUNCTION_ATTRIBUTE
#define FT_PUBLIC_FUNCTION_ATTRIBUTE
