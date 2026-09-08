# Compiles the CAP-6 deliverables:
#   1. layering proof - pweb.assets.bundle compiles with the assets
#      layer alone (no webview, no rpc, no platform unit path);
#   2. the pwebbundle CLI (assets layer + the RTL-only rpc constant
#      units; deliberately no webview/rest paths);
#   3. the release host (real CAP-3 bridge, so it drives mORMot's Win64
#      asm CallMethod - compiled against the PRISTINE pinned mORMot since
#      the 2026-09-08 pin move took upstream 896f1c1c and 790154af and
#      retired the CAP-3U patch window, exactly like the CAP-5 hosts).
$ErrorActionPreference = 'Stop'

New-Item -ItemType Directory -Force build/cap6/assets-fpc, build/cap6/bundler-fpc,
    build/cap6/host-fpc, build/cap6/bin | Out-Null

# 1) layering proof: webview-free and rpc-free by construction
fpc -MObjFPC -Sh -B -FUbuild/cap6/assets-fpc -Fusrc/assets `
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
    src/assets/pweb.assets.bundle.pas
if ($LASTEXITCODE -ne 0) {
    throw 'pweb.assets.bundle.pas failed its isolation compile'
}

# 2) the bundler CLI (static lib path mirrors the proven CAP-4
#    mkappzip compile - mormot.core.zip statics on Win64)
fpc -MObjFPC -Sh -B -FUbuild/cap6/bundler-fpc -FEbuild/cap6/bin `
    -Fusrc/assets -Fusrc/rpc `
    -Fideps/mormot2/src -Fudeps/mormot2/src/core -Fudeps/mormot2/src/lib `
    -Fldeps/mormot2/static/x86_64-win64 `
    tools/bundler/pwebbundle.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-6 bundler compile failed' }

# 3) the release host, against the pristine pinned mORMot
fpc -MObjFPC -Sh -B -Xm `
    -FUbuild/cap6/host-fpc -FEbuild/cap6/bin `
    -Fusrc/lib -Fusrc/rpc -Fusrc/security -Fusrc/webview `
    -Fusrc/assets -Fusrc/platform/windows `
    -Fideps/mormot2/src -Fudeps/mormot2/src/core `
    -Fudeps/mormot2/src/lib -Fudeps/mormot2/src/crypt `
    -Fudeps/mormot2/src/net -Fudeps/mormot2/src/db `
    -Fudeps/mormot2/src/orm -Fudeps/mormot2/src/rest `
    -Fudeps/mormot2/src/soa `
    -Fldeps/mormot2/static/x86_64-win64 `
    examples/08-release/releaseapp.pas
if ($LASTEXITCODE -ne 0) { throw 'CAP-6 release host compile failed' }
Write-Host 'CAP-6 bundler + release host compiled against the pristine pinned mORMot'
