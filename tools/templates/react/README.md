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
    dist/                     build output, created by `pweb build`

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

## The five commands

The `pweb` command owns the whole lifecycle of this project, and these five
are all of it:

    pweb create    wrote this tree. Offline: no package manager, no
                   compiler, no network connection, no repository.
    pweb doctor    tells you whether this machine can build and run it,
                   with a row per requirement and a reason per refusal.
    pweb build     builds it for THIS machine and leaves
                   dist/<os>-<arch>/release/. Every stage runs on every
                   build, so there is no incremental mode and nothing to
                   clean. Exactly one stage reaches the network: the
                   dependency install.
    pweb dev       builds it, launches it, watches the frontend, and on
                   every completed rebuild reloads the running window
                   WITHOUT restarting the application.
    pweb run       launches what `pweb build` produced. It builds nothing,
                   and it answers `not_built` if you have not built yet.

`pweb dev` watches the frontend only. A change under `src/` — the Pascal
half — is picked up by the next `pweb build`, or by restarting `pweb dev`.

## What creation did not do

Creating this project wrote source files and nothing else. It ran no package
manager, started no compiler, opened no network connection, and initialised
no repository. Those are separate steps, and `pweb build` and `pweb dev` are
the commands that take them.

In particular the frontend's dependencies are **not** installed yet.

`@pweb/runtime` is declared as `file:.pweb/sdk/typescript`, and that
directory is materialised from your PWeb installation by `pweb build` and
`pweb dev`, before either of them installs anything. So `npm ci` on its own
will install everything else and then LINK `@pweb/runtime` at that path —
which does not exist until one of those two commands puts it there, so the
link dangles and the first typecheck says
`Cannot find module '@pweb/runtime'`. That is the dependency model working:
the runtime is never fetched from a package registry, and copying it into
this tree by hand would vendor the SDK, which is the one thing the model
exists to prevent. Run `pweb build` and the problem does not arise.

## The PWeb runtime

This project contains application sources only. It does not vendor a copy of
the PWeb runtime, of mORMot or of the TypeScript SDK: the `pweb` command
locates all of them from the SDK installation it belongs to, so a framework
upgrade or a security fix reaches this project without anyone editing it.

Nothing in this tree records where that SDK lives, which is why this tree is
portable between machines and safe to commit as it stands.
