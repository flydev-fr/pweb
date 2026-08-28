# {{PROJECT_NAME}}

A PWeb application: a Pas2JS frontend and a Free Pascal backend, in one
process, with no HTTP server between them. Both halves are Object Pascal;
only one of them is compiled to JavaScript.

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
    frontend/index.html       the page, served from pweb://app
    frontend/app.css          the stylesheet
    frontend/pas2js.cfg       the frontend compile options
    frontend/src/             the Pas2JS sources
    dist/                     build output, created by a build

The native half of this project is the same as a React PWeb project's: the
same entry point, the same service, the same capability policy, the same
host composition. Only `frontend/` differs, and only `app.pwb` differs at
runtime.

## The data path

    Pas2JS -> pweb.native -> the native invocation primitive
           -> scheduler -> capability policy -> your service

Every call the frontend makes travels that path and no other. There is no
loopback server, no port, no socket and no fallback transport: the frontend
and the backend are the same process, and an invocation crosses a function
call. The application is served from `pweb://app`, a privileged origin the
runtime owns; nothing is loaded from `file://` or from the network.

`frontend/src/app.pas` reaches the backend through `pweb.native` - the PWeb
Pas2JS SDK - and through nothing else. `PWebHandshake` and `PWebInvoke` are
the whole of the frontend's contract with the runtime, and `EPWebError`
carries the typed refusal, with `Code` as the sole normative discriminator.

## The capability policy

Open `src/app.services.pas` and read `BuildAppPolicy` before you add a
service method. A method that is not MAPPED there is DENIED - answered
`forbidden` before the bridge is ever reached - so registering a method with
the service catalogue does not publish it. You publish it by naming its
capability, which is one visible line in one file.

The sample page demonstrates exactly that: it calls a method the policy does
not map and shows you the refusal.

## Building the frontend

The frontend is compiled by **Pas2JS 3.0.1 exactly** - the same compiler the
PWeb Pas2JS SDK is compiled by, which is why the version is pinned rather
than floored. `pweb doctor` reports whether this machine has it.

`frontend/pas2js.cfg` holds the compile options this project owns. The unit
path of the PWeb Pas2JS SDK is **not** in it and must never be written into
this tree: it is supplied at build time from the PWeb installation, which is
what keeps this project portable between machines. The compile is, in shape:

    pas2js @frontend/pas2js.cfg -Fu<the SDK's pas2js directory> \
           -o<output>/assets/app.js frontend/src/{{PASCAL_PROGRAM}}app.lpr

`-Jc` concatenates the RTL into that one file and declares `rtl` without
starting it, so the page loads `assets/app.js` and then a one-line
`assets/boot.js` containing `rtl.run();`. That bootstrap is emitted by the
build, not committed here, and it is the only handwritten JavaScript in the
whole application.

`index.html` and `app.css` are copied verbatim beside it, so the built
frontend is exactly four files: `index.html`, `assets/app.js`,
`assets/boot.js` and `assets/app.css`.

## What creation did not do

Creating this project wrote source files and nothing else. It ran no
compiler, no package manager, opened no network connection, and initialised
no repository. Those are separate, deliberate steps.

There is nothing to install. This project has no `package.json`, no
lockfile and no `node_modules`, and it needs neither Node.js nor npm: its
frontend dependency is a Pascal unit that ships with the PWeb SDK.

## The PWeb runtime

This project contains application sources only. It does not vendor a copy of
the PWeb runtime, of mORMot or of the Pas2JS SDK: the `pweb` command locates
all of them from the SDK installation it belongs to, so a framework upgrade
or a security fix reaches this project without anyone editing it.

Nothing in this tree records where that SDK lives, which is why this tree is
portable between machines and safe to commit as it stands.
