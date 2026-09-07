# `JS_SetMaxStackSize` is declared with `JSContext` where the C takes `JSRuntime *`

**Project:** synopse/mORMot2
**Unit:** `src/lib/mormot.lib.quickjs.pas`
**Severity:** memory corruption — calling the binding writes a pointer-sized
value into `JSContext` memory
**Reproduced on:** FPC 3.2.2, Windows x86-64, statically linked QuickJS

---

## Summary

`mormot.lib.quickjs.pas` declares:

```pascal
procedure JS_SetMaxStackSize(ctx: JSContext; stack_size: PtrUInt);
  cdecl; external {$ifdef QJSDLL}QJ{$endif};
```

The QuickJS sources shipped in the same repository declare it against the
**runtime**, not the context:

```c
/* res/static/libquickjs/quickjs.h */
void JS_SetRuntimeInfo(JSRuntime *rt, const char *info);
void JS_SetMemoryLimit(JSRuntime *rt, size_t limit);
void JS_SetGCThreshold(JSRuntime *rt, size_t gc_threshold);
/* use 0 to disable maximum stack size check */
void JS_SetMaxStackSize(JSRuntime *rt, size_t stack_size);
```

Its three immediate neighbours in the same block — `JS_SetRuntimeInfo`,
`JS_SetMemoryLimit`, `JS_SetGCThreshold` — are all declared with `rt: JSRuntime`
in the Pascal binding. `JS_SetMaxStackSize` is the odd one out, and the two
types are distinct opaque pointers, so nothing in the compile catches it.

## What goes wrong

`JS_SetMaxStackSize` writes the new bound through its first argument. Given a
`JSContext` where the implementation expects a `JSRuntime`, the write lands at
the runtime-relative offset of the stack-size field, measured from the base of
a context object instead. That is an unrelated field of a live object.

Measured behaviour: a process that calls the binding and then puts the engine
under allocation pressure with a memory limit set faults with an access
violation (`0xC0000005`) inside QuickJS. Bisected: calling the binding as
declared crashes; calling the identical external with `JSRuntime` as the first
parameter is stable across the same three stress paths (deep recursion, an
out-of-memory condition, and runtime destruction).

## Reproduction

Any host that sets all three resource limits on one engine:

```pascal
JS_SetMemoryLimit(rt, 64 shl 20);
JS_SetGCThreshold(rt, 16 shl 20);
JS_SetMaxStackSize(ctx, 512 shl 10);   // as declared today
// ...then drive the context until it allocates heavily and recurses deeply
```

The first two take the runtime and are correct; the third takes the context
and is the one that corrupts. Substituting a locally declared

```pascal
procedure JS_SetMaxStackSize(rt: JSRuntime; stack_size: PtrUInt);
  cdecl; external;
```

makes the same program stable.

## Suggested fix

Change the declaration's first parameter to `JSRuntime`:

```pascal
procedure JS_SetMaxStackSize(rt: JSRuntime; stack_size: PtrUInt);
  cdecl; external {$ifdef QJSDLL}QJ{$endif};
```

This is a source-compatible change for any caller that was passing a context
only because the declaration demanded one — such a caller was already
corrupting memory — and it brings the declaration into line with the three
neighbouring runtime-scoped setters.

## A related declaration worth checking at the same time

`JS_ExecutePendingJob` in the same unit carries an unresolved comment about its
second parameter:

```pascal
// TODO: Check pctx if the type is right.
```

The shipped C writes through that pointer, so passing `nil` is a null-pointer
store rather than a no-op. It is not the subject of this report, but it is in
the same file and the same family, and a caller reading the TODO cannot tell
whether passing `nil` is supported.

## Notes

- Found while auditing a Pascal host that embeds the QuickJS engine shipped
  with mORMot. The host does not call the binding; it declares the external
  itself with the correct first parameter, so this report describes upstream's
  declaration rather than a defect any released product is exposed to.
- The two files quoted above are the ones in the same checkout, so the C and
  the Pascal disagree within one revision rather than across a version skew.
