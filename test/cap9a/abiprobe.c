/*
  CAP-9A paired C-side ABI probe.

  Compiled against the PINNED QuickJS headers
  (deps/mormot2/res/static/libquickjs) with the exact static-build
  defines (-DJS_STRICT_NAN_BOXING -DCONFIG_BIGNUM -DCONFIG_JSX
  -DCONFIG_DEBUGGER) wherever the CI target has the matching C
  toolchain. It links NOTHING - it only instantiates the pinned type
  and enum definitions - and prints the exact line set the Pascal
  harness writes to build/cap9a/abi-pascal.txt, so the runner can diff
  the two files byte-for-byte. A divergence is a JSValue ABI mismatch,
  which is a CAP-9A STOP condition.
*/
#include <stdio.h>
#include "quickjs.h"

#ifndef JS_STRICT_NAN_BOXING
#error "CAP-9A requires the pinned JS_STRICT_NAN_BOXING configuration"
#endif

int main(void)
{
    printf("sizeof_jsvalue=%u\n", (unsigned)sizeof(JSValue));
    printf("tag_uninitialized=%d\n", (int)JS_TAG_UNINITIALIZED);
    printf("tag_int=%d\n", (int)JS_TAG_INT);
    printf("tag_bool=%d\n", (int)JS_TAG_BOOL);
    printf("tag_null=%d\n", (int)JS_TAG_NULL);
    printf("tag_undefined=%d\n", (int)JS_TAG_UNDEFINED);
    printf("tag_exception=%d\n", (int)JS_TAG_EXCEPTION);
    printf("tag_float64=%d\n", (int)JS_TAG_FLOAT64);
    printf("tag_object=%d\n", (int)JS_TAG_OBJECT);
    printf("tag_string=%d\n", (int)JS_TAG_STRING);
    printf("callback_int_bytes=%u\n", (unsigned)sizeof(int));
    printf("callback_jsvalue_bytes=%u\n", (unsigned)sizeof(JSValue));
    printf("callback_ptr_bytes=%u\n", (unsigned)sizeof(void *));
    return 0;
}
