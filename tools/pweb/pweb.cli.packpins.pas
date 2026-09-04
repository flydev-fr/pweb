{
  pweb.cli.packpins - the pinned packaging inputs, compiled in (CAP-10D1).

  THIS UNIT IS A TABLE OF FACTS AND NOTHING ELSE. It holds no logic, calls
  nothing, reads no file and - the point of the whole design - carries NO
  URL. It is what makes `pweb build --profile` provably offline: a build tool
  that cannot name a remote address cannot reach one, and that is a property
  of what this file does not contain rather than a promise somebody wrote.

  ---------------------------------------------------------------------------
  WHY THE PINS ARE COMPILED IN RATHER THAN READ FROM THE LOCKS
  ---------------------------------------------------------------------------

  The locks (innosetup.lock, webview2-runtime.lock, webview.lock) are
  REPOSITORY build metadata. They carry the authoritative Microsoft and
  jrsoftware download URLs, and shipping them into an installed SDK would put
  a download address on the build path of every machine that installs PWeb -
  which is exactly the thing this shard exists not to do. So the digests
  travel as constants and the URLs stay behind.

  That inverts, but does not weaken, the house cross-check idiom: where
  test/cap6b1/build_normal_setup.ps1 parses PWEB_WV2_INSTALL_TIMEOUT_MS out
  of a Pascal unit so the unit stays the single source, here
  test/cap10d1/check_cap10d1_contracts.ps1 parses the LOCKS and requires every
  constant below to equal what they say. A pin nobody cross-checks is a number
  somebody typed; each of these is checked against its lock on every CI leg,
  on four targets, before anything is compiled.

  ---------------------------------------------------------------------------
  WHAT IS VERIFIED, AND WHERE
  ---------------------------------------------------------------------------

  BUILD TIME (pweb.cli.package, on the machine running `pweb build`):
    sha256 then byte size of each staged artifact, byte-exact against the
    constants below - the tools/get-webview2-runtime.ps1 verification with
    its transfer half removed. A mismatch is a REFUSAL naming the
    provisioning script; nothing is ever fetched to "repair" it.

  INSTALL TIME (the CAP-13 gates, unchanged):
    the Authenticode axis over the bytes that actually LANDED on the user's
    machine. That is why the subject below is carried but not enforced here:
    the sha256 pin already identifies the exact bytes at build time, and the
    signature check that matters is the one over the deployed tree, which
    tools/setup/pwebwv2prov.pas and pwebwv2fixed.pas perform, and which this
    shard does not touch.

  The subject is passed THROUGH to the installers as a /D define, which is
  the only reason it is here at all.
}
unit pweb.cli.packpins;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base;

const
  { --- the pinned Inno Setup 6 compiler (innosetup.lock) ------------------- }

  /// the ratified compiler version, for a diagnostic that names it
  PWEB_PACK_ISCC_VERSION = '6.7.3';

  /// the sha256 of the INSTALLER that produced the staged compiler
  // - ISCC.exe publishes no machine-readable version resource, so the
  // installer digest IS the toolchain identity: tools/get-innosetup.ps1
  // records it in <target>/.pweb-pin, and the packaging preflight requires
  // that stamp to equal this value byte-exactly
  PWEB_PACK_ISCC_INSTALLER_SHA =
    '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732';

  /// the stamp file the provisioning script writes beside ISCC.exe
  PWEB_PACK_ISCC_STAMP = '.pweb-pin';

  /// the compiler executable, and the banner it must announce
  // - the second identity axis, and the one that survives a hand-copied
  // directory whose stamp says something the binary does not
  PWEB_PACK_ISCC_EXE = 'ISCC.exe';
  PWEB_PACK_ISCC_BANNER = 'Inno Setup 6 Command-Line Compiler';

  { --- the pinned WebView2 distribution artifacts (webview2-runtime.lock) -- }

  /// evergreen-bootstrapper: the ~1.7 MB Evergreen Bootstrapper the NORMAL
  // profile embeds
  PWEB_PACK_WV2_BOOTSTRAPPER = 'MicrosoftEdgeWebview2Setup.exe';
  PWEB_PACK_WV2_BOOTSTRAPPER_BYTES = 1780952;
  PWEB_PACK_WV2_BOOTSTRAPPER_SHA =
    'be695eb3732a94e181f008ab5cf6ee650f8644676e87f9e02b6ab0d02f2ea08e';

  /// evergreen-standalone-x64: the ~212 MB Standalone Installer the OFFLINE
  // profile embeds so a machine with no network still gets a runtime
  PWEB_PACK_WV2_STANDALONE = 'MicrosoftEdgeWebView2RuntimeInstallerX64.exe';
  PWEB_PACK_WV2_STANDALONE_BYTES = 212668624;
  PWEB_PACK_WV2_STANDALONE_SHA =
    '6ac57a21414742ac1a6a03bf9516a048897317cef04a49967b283093e29c31b7';

  /// webview2-fixed-runtime-x64: the ~290 MB cabinet the FIXED-RUNTIME
  // profile expands and bundles
  PWEB_PACK_WV2_FIXED_CAB =
    'Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64.cab';
  PWEB_PACK_WV2_FIXED_BYTES = 304135089;
  PWEB_PACK_WV2_FIXED_SHA =
    'd4c8864a764bc3ff015f7b644e1f9d022ba8a73ab470447398dda0cc9e75ab92';

  /// the four-part runtime version the cabinet carries, and the ONE
  // top-level directory expanding it produces
  // - the tree name is DERIVED from the version by Microsoft's own naming
  // and is spelled out here rather than concatenated, so the contract check
  // can compare one literal against the lock instead of re-deriving a rule
  PWEB_PACK_WV2_FIXED_VERSION = '151.0.4129.78';
  PWEB_PACK_WV2_FIXED_TREE =
    'Microsoft.WebView2.FixedVersionRuntime.151.0.4129.78.x64';

  /// the ratified Authenticode leaf subject, identical for all three
  // artifacts - passed THROUGH to the installers as a /D define and
  // enforced by them over the bytes that landed
  PWEB_PACK_WV2_SUBJECT =
    'CN=Microsoft Corporation, O=Microsoft Corporation, L=Redmond, ' +
    'S=Washington, C=US';

  /// the bounded wait the provisioning helper is given, from the SINGLE
  // source: PWEB_WV2_INSTALL_TIMEOUT_MS in
  // src/platform/windows/pweb.platform.webview2.provision.pas. Restated here
  // only because a /D define needs a value, and cross-checked against that
  // constant by the contract check exactly as the CAP-6b1 build script does
  PWEB_PACK_WV2_TIMEOUT_MS = 900000;

  { --- the pinned WebView2 SDK loader (webview.lock) ----------------------- }

  /// the Fixed Version Runtime package ships NO loader, so the fixed profile
  // bundles the one from the pinned WebView2 SDK tree - the same file
  // test/cap6b3/build_fixed_setup.ps1 copies, covered upstream by
  // webview.lock's webview2-sdk-tree-sha256 and pinned here by its own digest
  // so this build path verifies the exact bytes rather than a tree it cannot
  // see
  PWEB_PACK_WV2_LOADER = 'WebView2Loader.dll';
  PWEB_PACK_WV2_LOADER_BYTES = 158648;
  PWEB_PACK_WV2_LOADER_SHA =
    '24ce662f5e19393e2f8e56d1e62e6b2cacee158096d88d3596280922ec8c6d61';

  // THE SDK VERSION THAT DIGEST BELONGS TO IS DELIBERATELY NOT SPELLED HERE.
  // webview.lock's `webview2-sdk` is its single source, and CAP-10A's
  // contract check refuses a SECOND copy of the WebView2 build number
  // anywhere under tools/pweb - the rule exists because that number already
  // has one owner, the CAP-6b0 detector. The anchor the bump needs lives in
  // test/cap10d1/check_cap10d1_contracts.ps1 instead: it reads the lock, and
  // it requires the loader digest above to be the digest of the file the
  // pinned SDK tree actually carries.

  { --- where the packaging kit lives inside an installed SDK --------------- }

  /// <root>/share/pweb/deps/... - the SAME directory names this repository
  // uses under deps/, so one naming covers a checkout and an installation
  PWEB_PACK_DEPS_INNOSETUP = 'innosetup';
  PWEB_PACK_DEPS_WV2 = 'webview2-runtime';

  /// <root>/share/pweb/pack/... - PWeb's OWN packaging artifacts, which are
  // not dependencies and deliberately do not live beside them
  PWEB_PACK_DIR = 'pack';
  PWEB_PACK_SETUP = 'setup';
  PWEB_PACK_BIN = 'bin';
  PWEB_PACK_LIB = 'lib';

  /// the two compiled CAP-13 setup helpers the generated installers embed
  // - built once, at SDK staging time, from the two tools/setup helper
  // sources and shipped: a build path that compiled them would be a build
  // path that compiles PWeb's own sources on a user's machine
  PWEB_PACK_HELPER_PROV = 'pwebwv2prov.exe';
  PWEB_PACK_HELPER_FIXED = 'pwebwv2fixed.exe';

  /// the three generic setup manifests, one per Windows profile
  PWEB_PACK_ISS_NORMAL = 'app-normal.iss';
  PWEB_PACK_ISS_OFFLINE = 'app-offline.iss';
  PWEB_PACK_ISS_FIXED = 'app-fixed.iss';

  { --- the packaging output layout ---------------------------------------- }

  /// <output>/<os>-<arch>/artifacts/<profile>/ - beside `release`, never
  // inside it: an installer that shipped its own installer would be a
  // release directory that no longer describes what `pweb run` launches
  //
  // NOT `dist`, and that is a MEASUREMENT rather than a preference. The
  // CAP-10C1 pipeline already owns <output>/<target>/dist: it is where the
  // Pas2JS static assembly lands (PWEB_FE_DIST, pweb.cli.pipeline line 711),
  // so an artifact directory of that name would sit inside the frontend
  // staging tree and be replaced by the next build. The CAP-10D1 gate found
  // it on the first real run, and the name moved rather than the frozen
  // layout
  PWEB_PACK_ARTIFACTS = 'artifacts';

  /// the manifest CAP-6b4 left as the seam for CAP-10, in its shape
  PWEB_PACK_INDEX = 'release-index.json';
  PWEB_PACK_INDEX_SCHEMA = 1;

  /// the staging sibling and the retired-artifact sibling, both dot-leading
  // and both under <output>/<target>, exactly as the CAP-10C1 release layout
  // names its own two
  PWEB_PACK_STAGE = '.pweb-pack.tmp';
  PWEB_PACK_OLD = '.pweb-dist-old.tmp';

  { --- the bounds ---------------------------------------------------------- }

  /// the Inno Setup compile. It is generous because the fixed profile
  // LZMA2-compresses a ~690 MB tree; the normal profile finishes in seconds
  // and this bound never comes near it
  PWEB_PACK_ISCC_MS = 1800000;

  /// expanding the pinned cabinet with the system `expand`
  PWEB_PACK_EXPAND_MS = 900000;

  /// ceiling on the archive this CLI writes itself, in bytes
  // - the ustar is built in memory and gzipped in one call, so this is the
  // point at which a release stops being an archive and becomes a streaming
  // problem. A release past it is a typed refusal, never a partial file
  PWEB_PACK_MAX_ARCHIVE_BYTES = 268435456;


implementation

end.
