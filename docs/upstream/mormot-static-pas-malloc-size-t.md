# The `pas_*` heap exports are declared with 32-bit sizes where the C calls them with `size_t`

**Project:** synopse/mORMot2
**Unit:** `src/lib/mormot.lib.static.pas`
**Severity:** silent truncation — an allocation request above 4 GiB returns an
undersized buffer instead of failing
**Applies to:** every 64-bit target that links the bundled statics

---

## Summary

`mormot.lib.static.pas` exports the heap functions the patched C sources call:

```pascal
function pas_malloc(size: cardinal): pointer; cdecl;
 {$ifdef FPC} public name _PREFIX + 'pas_malloc'; {$endif}
begin
  GetMem(result, size);
end;
```

and, further down the same block:

```pascal
function pas_malloc_usable_size(P: pointer): integer; cdecl;
```

The C side declares both with `size_t`:

```c
/* res/static/libquickjs/cutils.h */
//AB force to use the pascal heap and exceptions
void *pas_malloc(size_t size);
void pas_free(void *ptr);
void *pas_realloc(void *ptr, size_t size);
size_t pas_malloc_usable_size(void *ptr);
```

On a 64-bit target `size_t` is 8 bytes while `cardinal` is 4 and `integer` is 4
and signed.

## What goes wrong

**`pas_malloc`.** The caller passes a 64-bit value; the callee reads 32 bits of
it. A request for `4 GiB + n` bytes is serviced as a request for `n` bytes, the
allocation succeeds, and the caller receives a pointer to a buffer far smaller
than the one it asked for. The next write past `n` is a heap overflow, at a site
with no error to check — `pas_malloc` returned non-nil, which is its whole
success contract.

The truncation is silent in both directions of the ABI: the C compiler emits a
correct 64-bit argument and the Pascal side simply ignores the high half, so
neither a compiler warning nor a linker diagnostic can fire.

**`pas_malloc_usable_size`.** The C prototype returns `size_t`; the Pascal
returns a signed 32-bit `integer`. A usable size above 2 GiB is returned
negative, and above 4 GiB is truncated. Any caller that compares the answer
against a requested size gets a wrong answer for the same class of allocation.

## Reachability

In the QuickJS engine as shipped, a per-runtime `JS_SetMemoryLimit` well below
4 GiB makes a single over-4-GiB request unreachable, so a host that always sets
a limit is not exposed. A host that does not set one, or that sets a limit above
4 GiB, and that then handles a large buffer — a big typed array, a large string
built by concatenation, a `JSON.stringify` of a very large object graph — can
reach it. The same exports also serve the other patched statics in the tree, so
the exposure is not QuickJS-specific.

## Suggested fix

Widen the declarations to a pointer-sized type on both parameter and result:

```pascal
function pas_malloc(size: PtrUInt): pointer; cdecl;
function pas_realloc(P: pointer; Size: PtrUInt): pointer; cdecl;
function pas_malloc_usable_size(P: pointer): PtrUInt; cdecl;
```

`pas_calloc` is declared `(n, size: PtrInt)` and multiplies its two arguments;
widening it to `PtrUInt` is the matching change, and a multiplication of two
attacker-influenced sizes deserves an overflow guard that refuses rather than
wrapping:

```pascal
function pas_calloc(n, size: PtrUInt): pointer; cdecl;
begin
  if (size <> 0) and (n > High(PtrUInt) div size) then
    result := nil   // refuse rather than wrap
  else
    ...
end;
```

None of this changes behaviour for any allocation that fits in 32 bits, which is
every allocation these functions service today on a limited runtime; what it
changes is what happens to the one that does not.

## Notes

- Found while auditing a Pascal host that embeds the QuickJS engine shipped with
  mORMot. That host is not exposed, because it sets a per-engine memory limit
  well below the threshold; it is reported because the declarations are wrong
  independently of any one caller's limits.
- The two files quoted above are in the same checkout, so the C and the Pascal
  disagree within one revision rather than across a version skew.
- On aarch64-darwin, where these exports must be provided by the embedding
  program rather than by the shipped object, we widened our own copies to
  `PtrUInt` with the overflow-guarded `pas_calloc` above; that divergence from
  the declaration in this unit is what prompted the report.
