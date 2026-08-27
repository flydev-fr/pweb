# {{PROJECT_NAME}}

A PWeb application: a React frontend and a Free Pascal backend, in one
process, with no HTTP server between them.

| what | value |
|---|---|
| project name | `{{PROJECT_NAME}}` |
| bundle identifier | `{{BUNDLE_ID}}` |
| frontend kind | `{{UI_KIND}}` |
| version | `{{PROJECT_VERSION}}` |
| Pascal program | `{{PASCAL_PROGRAM}}` |
| executable | `{{EXECUTABLE_NAME}}` |

## Layout

    pweb.json                 the project descriptor, schema 1
    src/{{PASCAL_PROGRAM}}.lpr   the native entry point
    src/app.services.pas      your service, your capability policy
    frontend/                 the React sources
    dist/                     build output, created by a build

## The data path

    React -> @pweb/runtime -> the native invocation primitive
          -> scheduler -> capability policy -> your service

Every call the frontend makes travels that path and no other. There is no
loopback server, no port, no socket and no fallback transport: the frontend
and the backend are the same process, and an invocation crosses a function
call. The application is served from `pweb://app`, a privileged origin the
runtime owns; nothing is loaded from `file://` or from the network.

## The capability policy

Open `src/app.services.pas` and read `BuildAppPolicy` before you add a
service method. A method that is not MAPPED there is DENIED - answered
`forbidden` before the bridge is ever reached - so registering a method with
the service catalogue does not publish it. You publish it by naming its
capability, which is one visible line in one file.

The sample page demonstrates exactly that: it calls a method the policy does
not map and shows you the refusal.

## What creation did not do

Creating this project wrote source files and nothing else. It ran no package
manager, started no compiler, opened no network connection, and initialised
no repository. Those are separate, deliberate steps.

In particular the frontend's dependencies are **not** installed, and
`npm ci` here will not work on its own yet: `@pweb/runtime` is declared as
`file:.pweb/sdk/typescript`, and that directory is materialised from your
PWeb installation when the project is built. Installing it by hand would
vendor a copy of the SDK into this tree, which is the one thing the
dependency model exists to prevent.

## The PWeb runtime

This project contains application sources only. It does not vendor a copy of
the PWeb runtime, of mORMot or of the TypeScript SDK: the `pweb` command
locates all of them from the SDK installation it belongs to, so a framework
upgrade or a security fix reaches this project without anyone editing it.

Nothing in this tree records where that SDK lives, which is why this tree is
portable between machines and safe to commit as it stands.
