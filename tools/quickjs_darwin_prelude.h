/*
  CAP-9A macOS build prelude for the PINNED QuickJS amalgamation.

  Injected with clang -include by tools/build_quickjs_darwin.sh - the
  pinned sources under deps/mormot2/res/static/libquickjs stay byte
  untouched. Two Darwin-only gaps in the pinned tree are bridged here,
  both measured on hosted run 32857758203 (Xcode 16.4, both arches):

  1. quickjs.c uses PATH_MAX and relies on <dirent.h> pulling it in
     ("//AB for PATH_MAX below") - true on glibc and mingw, false on the
     macOS SDK, where PATH_MAX lives in <limits.h> (value 1024).

  2. quickjs.c's CONFIG_DEBUGGER region calls js_std_dump_error(), whose
     prototype lives in the EXCLUDED quickjs-libc.h; the symbol itself is
     implemented in Pascal and exported by the pinned mormot.lib.quickjs
     ("public name _PREFIX + 'js_std_dump_error'"), exactly as the
     Windows/Linux static objects resolve it. Modern clang (16+) makes an
     implicit function declaration a hard error in C99, so the call needs
     a visible declaration. Declared with an empty parameter list (a
     valid no-prototype C99 declaration) because the JSContext type does
     not exist yet at prelude position.
*/
#include <limits.h>
void js_std_dump_error();
