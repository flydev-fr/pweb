# `imvCurrency` is read from RAX on the SysV x64 ABI too, and there it is wrong

**Project:** synopse/mORMot2
**Unit:** `src/core/mormot.core.interfaces.pas` (`CallMethod`, the `ABIX64`
assembler)
**Introduced by:** `790154afbfb004d31404c81e13e8a1bc90a04d32`
*(core: ensure imvCurrency is returned in rax on x86-64)*
**Severity:** wrong result — an interface-based service method returning
`Currency` yields an unrelated value on Linux/x86-64; no crash, no diagnostic
**Reproduced on:** FPC 3.2.3, Linux x86-64, `TRestServerFullMemory` +
`sicShared`, in-process `Uri()`

---

## Summary

`790154af` removed the `imvCurrency` case from the XMM0 branch of the x64
`CallMethod` stub:

```pascal
        mov     cl, [r12].TCallMethodArgs.resKind
        cmp     cl, imvDouble
        je      @d
        cmp     cl, imvDateTime // but imvCurrency is returned in rax
        jne     @e
@d:     movlpd  qword ptr [r12].TCallMethodArgs.res64, xmm0
```

On Win64 that is right, and it fixes a real defect: FPC 3.2.2 returns
`Currency` there as its scaled `Int64` in RAX, which the previous code never
read.

The block it changes is inside `{$ifdef ABIX64}` and is **shared with SysV
x64**. On Linux/x86-64 the result does not arrive in RAX for a method with
arguments, and the value stored into `res64` is whatever RAX happened to hold
— in practice a stack or heap pointer.

## Measurement

Five methods on one `IInvokable`, differing only in arity and argument kind,
each returning `Currency`, called through `TRestServer.Uri()`:

```pascal
function CurZero: Currency;                        // 1234.5678
function CurOneInt(A: Integer): Currency;          // A + 0.5
function CurOneCur(const V: Currency): Currency;   // V * 2
function CurOneDouble(V: Double): Currency;        // V * 2
function CurTwoInt(A, B: Integer): Currency;       // A*100 + B + 0.25
```

| target | before `790154af` | after `790154af` |
|---|---:|---:|
| Windows x86-64, FPC 3.2.2 | 0 / 5 | **5 / 5** |
| Linux x86-64, FPC 3.2.3 | 0 / 5 | **1 / 5** |

On Linux only `CurZero` — the no-argument case — is correct after the change.
The four with arguments return values of the shape

```
CurOneInt(41)      -> 13953113532.192    (expected 41.5)
CurOneCur(21.25)   -> 13953113532.2144   (expected 42.5)
CurOneDouble(21.25)-> 13953113532.2368   (expected 42.5)
```

The integer part is identical across the three and only the low digits move,
which is what a 64-bit pointer looks like when it is read as a scaled
`Currency`: `13953113532.192 * 10000 = 139531135321920` ≈ `0x7EE7ADE19AC0`, a
mapped address rather than a result.

`Currency` **arguments** are marshalled correctly on both platforms and at
both commits, so this is specific to the return path.

## Why the earlier code was not right either

Before `790154af` the SysV path read `imvCurrency` from XMM0 and scored 0/5,
so this is not a regression report: the change strictly improves Linux and
fixes Windows. What it does mean is that the `imvCurrency` result convention
is still unresolved for SysV x64, and the comment now says *"but imvCurrency
is returned in rax"* for an ABI where that does not hold.

## Suggested direction

The two ABIs disagree, so the branch probably has to as well — something in
the shape of

```pascal
        cmp     cl, imvDateTime
        je      @d
        {$ifdef OSPOSIX}
        cmp     cl, imvCurrency   // SysV x64 does not return it in rax
        je      @d
        {$endif OSPOSIX}
        jne     @e
```

except that the pre-`790154af` XMM0 read did not work on SysV either, so the
correct convention wants measuring on FPC's side before it is encoded here.
`aarch64` is untested by the reporter and uses a different `CallMethod`
entirely.

## Not covered by this report

macOS on either architecture. `macos-x86_64` shares `ABISYSVX64` with Linux
and is likely identical; `macos-arm64` is AAPCS64 and is a separate question.
Neither was measured.
