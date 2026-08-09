---
name: chetcli
description: Use when generating Delphi/Pascal bindings from C header files - translating a C library's .h files into a .pas unit, updating bindings after a library upgrade, or debugging a translation that produced wrong or missing declarations. Covers the chetcli command line, its flags, and the usual parse failures.
---

# Generating Pascal bindings with ChetCLI

ChetCLI translates a directory of C headers into a single Delphi/Pascal unit,
using Clang to parse. Every setting is a command line flag, so no project file
has to be authored first.

## Before anything else

```
chetcli version
```

Prints the ChetCLI version and, more importantly, **the libclang version actually
loaded**. If it says `libclang: not available`, `libclang.dll` is missing next to
the executable and nothing else will work. Different libclang versions produce
different translations, so record this when a binding is checked in.

## The workflow

Always in this order. Skipping step 2 wastes a slow parse on a bad invocation.

1. **Look at the headers.** Find the include root, whether headers live in
   subdirectories, and which `#define`s the library expects to be set.
2. **Dry run.** Same command plus `--dry-run`: it resolves every flag and default,
   prints the effective configuration, and stops without parsing.
3. **Generate.**
4. **Compile the generated unit.** A binding that does not compile is not done.

```
chetcli generate --headers ./include --recursive \
  --out ./src/mylib.pas --lib-const LIB_MYLIB \
  --platform win64=mylib.dll --platform linux64=libmylib.so \
  --clang-arg -I./include \
  --dry-run
```

## Flags worth knowing

`chetcli help` prints all of them with accepted values and defaults - read it
rather than guessing a flag name. The ones that decide whether a run succeeds:

| Flag | Why it matters |
|---|---|
| `--headers <dir>` `--recursive` | the input; required |
| `--out <file.pas>` | the output; **the unit name comes from this filename** |
| `--platform <id>=<lib>` | repeatable; at least one is required, or use `--name` |
| `--name <project>` | presets `LIB_<PROJECT>` and conventional library names, then enables win32 and win64 |
| `--clang-arg <arg>` | repeatable; `-I<dir>` and `-D<name>` go here, and most failures are fixed here |
| `--ignore-parse-errors` | translate anyway; use to *inspect* damage, not as a fix |
| `--save-project <f.chet>` | persist the configuration so the binding is reproducible |
| `--script-file <f>` | post-process script applied to the generated unit |

Platform ids: `win32 win64 macarm macintel linux64 ios android32 android64`.

## Exit codes

`0` success · `1` translation failed · `2` bad command line.

A code of `2` always comes with a message naming the flag and its accepted
values. Read it; do not retry with a guess.

## When it goes wrong

**`'stdint.h' file not found`** or a cascade of unknown-type errors - clang cannot
find the include path. Add `--clang-arg -I<dir>` for each include root, including
the library's own. This is by far the most common failure.

**Declarations missing from the output** - they were behind a `#if` that was false.
Add `--clang-arg -D<name>` for the configuration you are targeting.

**`no platform selected`** - pass `--platform <id>=<lib>` or `--name <project>`.
ChetCLI refuses to guess a platform.

**Output has `{ TODO }` comments** - a declaration could not be translated. Read
those spots: they are usually function-pointer or bitfield constructs needing a
hand fix, or a `--ctype-map` entry.

**Generated unit will not compile** - check `--char` / `--unsigned-char` (C `char`
maps to `UTF8Char` by default) and `--enum-handling` (`const` avoids Delphi's
strict enum rules for sparse C enums).

## Reproducibility

Pass `--save-project mylib.chet` and commit that file next to the binding. Then
`chetcli run mylib.chet` regenerates the exact same unit. The generated unit's
header records the ChetCLI and libclang versions that produced it.
