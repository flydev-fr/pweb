# {{PROJECT_NAME}}

A PWeb application scaffolded by `pweb create`.

| what | value |
|---|---|
| project name | `{{PROJECT_NAME}}` |
| bundle identifier | `{{BUNDLE_ID}}` |
| frontend kind | `{{UI_KIND}}` |
| version | `{{PROJECT_VERSION}}` |
| Pascal program | `{{PASCAL_PROGRAM}}` |
| executable | `{{EXECUTABLE_NAME}}` |

## Layout

    pweb.json      the project descriptor, schema 1
    src/           the native Pascal program
    frontend/      the frontend sources
    dist/          build output, created by a build and not by creation

## What creation did not do

Creating this project wrote source files and nothing else. It ran no package
manager, started no compiler, opened no network connection, and initialised
no repository. Those are separate, deliberate steps you take when you are
ready for them.

## The PWeb runtime

This project contains application sources only. It does not vendor a copy of
the PWeb runtime or of mORMot: the `pweb` command locates both from the SDK
installation it belongs to, so a framework upgrade or a security fix reaches
every project at once instead of being copied into each of them.

Nothing in this tree records where that SDK lives, which is why this tree is
portable between machines.
