# Third-party license notices

## webview/webview (MIT)

The raw binding units in `src/lib/` are generated from the C headers of
[webview/webview](https://github.com/webview/webview) at the pinned commit
recorded in `webview.lock`. Both distributed binaries are built from that same
pinned source: `webview.dll` by `tools/build-webview-dll.ps1` and
`libwebview.so.0.12` by `tools/build-webview-so.sh`. Each script places the
license text next to every built binary as `LICENSE.webview`. The upstream MIT
license is preserved below for all vendored, generated, or distributed
material derived from that project.

```
MIT License

Copyright (c) 2017 Serge Zaitsev
Copyright (c) 2022 Steffen André Langnes

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Microsoft WebView2 SDK (BSD-style)

`webview.dll` embeds upstream's built-in WebView2 loader implementation,
compiled against the Microsoft WebView2 SDK headers. The SDK is obtained
during the pinned build as the `Microsoft.Web.WebView2` nuget package, at the
version pinned inside the pinned upstream commit
(`cmake/webview.cmake`, `WEBVIEW_MSWEBVIEW2_VERSION` = 1.0.1150.38). The
package's `LICENSE.txt` is reproduced below, as its binary-redistribution
clause requires; `tools/build-webview-dll.ps1` also places it next to every
built binary as `LICENSE.webview2sdk`.

```
Copyright (C) Microsoft Corporation. All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are
met:

   * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
   * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
   * The name of Microsoft Corporation, or the names of its contributors
may not be used to endorse or promote products derived from this
software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## GTK 3, WebKitGTK and GLib (LGPL / BSD-style, dynamically linked)

The Linux build (CAP-7L) **dynamically links** the distribution's own GTK 3,
WebKitGTK 4.1 and GLib shared objects (`libwebkit2gtk-4.1.so.0`,
`libgtk-3.so.0`, `libgio-2.0.so.0`, `libgobject-2.0.so.0`,
`libglib-2.0.so.0`). None of them is vendored, bundled, modified or
redistributed by this project, and the release layout deliberately contains no
WebKit file at all — the engine is the target system's, installed and updated
by its package manager (`_bmad-output/specs/spec-pweb/deployment.md`).

GTK and GLib are distributed under the GNU LGPL, and WebKitGTK under the LGPL
together with the BSD-style licenses of the WebKit project; those terms are
satisfied by the distribution that supplies the libraries. Dynamic linking
against the unmodified system copies imposes no additional obligation on a
PWeb application. Applications that choose to redistribute these libraries
themselves — which PWeb neither does nor recommends — become responsible for
carrying their license texts.

## React and react-dom (MIT)

The CAP-5 React example bundles [React](https://github.com/facebook/react)
and react-dom (exact versions pinned in
`examples/04-react/frontend/package.json` / `package-lock.json`) into its
built `dist/assets/app.js`. React is distributed under the MIT license:

```
MIT License

Copyright (c) Meta Platforms, Inc. and affiliates.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Pas2JS / Free Pascal RTL (modified LGPL with linking exception)

The CAP-5 Pas2JS SDK and example are compiled with the pinned
[Pas2JS](https://getpas2js.freepascal.org/) release recorded in
`pas2js.lock` (fetched by `tools/get-pas2js.ps1`). Compiled output embeds
the Pas2JS run-time library (`rtl.js` and compiled RTL units), which is
distributed under the Free Pascal RTL license: the GNU Library General
Public License with the FPC static-linking exception, permitting
distribution of executables/bundles that link the RTL without imposing
LGPL terms on the application itself. The full license texts ship inside
the pinned release archive (`COPYING.FPC` and companions in the Pas2JS
distribution); they apply to all RTL material embedded in the compiled
`app.js` bundles and the SDK test harness output.

TypeScript, esbuild and @types/* packages are build-time toolchain
dependencies only (pinned in the respective `package-lock.json` files);
no part of them is redistributed in built PWeb artifacts.

## QuickJS (MIT)

A plugin-enabled PWeb application statically links the QuickJS engine
from the pinned mORMot2 subtree (`QUICKJS_VERSION 2021-03-27`, mORMot pin
recorded in `mormot.lock`), so the engine's MIT terms travel with every
such binary. The notice file that ships beside it is **generated, never
hand-written**: `tools/quickjs/pwebqjspack` assembles `LICENSE.quickjs`
from the leading notice block of all seventeen pinned sources that
participate in the static build - the `compile-all.sh` amalgamation
inputs plus every pinned header they include - each labelled with its
path and the SHA-256 of its LF-normalized bytes, under a factual
provenance header naming the version and the mORMot pin. Nothing in it is
composed or paraphrased.

One canonicalization is applied and the artifact says so about itself:
line terminators become LF, because the pinned sources check out CRLF on
Windows and LF elsewhere and this file must be byte-identical on all four
targets. It is:

```
sha256 = 8310e7a6c52cd3b45a0aedb5620ef79408c8c155594f37259ba801f6a2fbe2fc
```

That digest is verified against the pinned sources themselves by the
CAP-9C1 gate (independently of the generator that produced it), pinned as
an absolute value by the CAP-7F aggregator, and asserted present exactly
once in every plugin-enabled release layout by the CAP-9C2 gate. It is
deliberately NOT embedded inside `app.pwb` or `plugins.zip`: a licence
notice belongs beside the binary it covers, not inside content the
application serves.

Applications built WITHOUT plugins link no QuickJS object and ship no
`LICENSE.quickjs` - the CAP-6/CAP-7 release layouts are unchanged by this.
