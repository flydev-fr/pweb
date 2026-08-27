{
  pweb.cli.sdk - where the PWeb SDK is, and how that is decided (CAP-10B0).

  ONE question, answered from ONE anchor:

      given the executable that is running right now, where is the PWeb SDK
      it belongs to, and where inside that SDK is the trusted template pack?

  ---------------------------------------------------------------------------
  THE ANCHOR, AND EVERYTHING IT IS NOT
  ---------------------------------------------------------------------------

  The anchor is the canonical directory holding the running image, and the
  rule is a single step:

      <sdk-root>/bin/pweb[.exe]      ->   sdk-root = parent(dir(image))
      <sdk-root>/share/pweb/pweb-templates.zip

  It is NOT the working directory. It is NOT a value from pweb.json, from
  app.pwb, from a frontend, or from a build output. It is NOT an environment
  variable - there is no PWEB_HOME, no PWEB_SDK and no PWEB_TEMPLATES, and
  test/cap10b0/check_cap10b0_contracts.ps1 sweeps for every spelling of one.
  A developer tool that can be pointed at a different SDK by exporting a
  variable is a tool whose trusted input is whatever the last shell profile
  said it was.

  There is exactly ONE shape, not a search. A basename test ("am I in a
  directory called bin?") would be two shapes and a guess about which one
  applies; a search up the tree would make the answer depend on what happens
  to exist above the executable. The repository build stages the same
  <root>/bin + <root>/share/pweb layout the installed SDK will have, so the
  tested arrangement IS the shipped arrangement rather than a second path.

  ---------------------------------------------------------------------------
  WHY THE RESOLUTION IS A WALK AND NOT A CONCATENATION
  ---------------------------------------------------------------------------

  'share', 'pweb' and the pack file name are resolved one component at a
  time through PWebCliEntry, which reads the directory and compares the name
  byte-exactly, and which reports a reparse point as pcnLink. So a junction
  called `share` cannot redirect the SDK, a case variant cannot resolve on
  NTFS or APFS, and the answer is the kernel's rather than a string's - the
  identical discipline pweb.cli.paths applies to project paths.

  Callers that need a DIFFERENT root - the test suite staging a fixture SDK,
  a developer build - pass it as a PARAMETER to PWebCliTemplatePackIn. That
  is the whole of the seam: an argument at a call site, visible in the
  source, and never an ambient input the process reads behind its own back.
}
unit pweb.cli.sdk;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.cli.platform;

const
  /// the executable's own directory inside an SDK root
  PWEB_SDK_BIN = 'bin';
  /// the first component of the SDK's architecture-independent data
  PWEB_SDK_SHARE = 'share';
  /// the second: this project's own sub-tree of it
  PWEB_SDK_SHARE_PWEB = 'pweb';
  /// the ONE trusted template carrier. Deliberately NOT '.pwb' and
  // deliberately not 'plugins.zip': both of those names carry frozen,
  // structurally different contracts, and a third archive must not be
  // mistakable for either
  PWEB_SDK_TEMPLATE_PACK = 'pweb-templates.zip';

type
  /// why an SDK resolution failed - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebSdkRefusal = (
    psrNone,
    /// the running image's directory could not be canonicalized
    psrImageUnresolved,
    /// that directory has no parent (the image sits at a filesystem root)
    psrNoRoot,
    /// 'share' is absent, is not a directory, or is a reparse point
    psrShareMissing,
    /// 'share/pweb' is absent, is not a directory, or is a reparse point
    psrShareTreeMissing,
    /// the pack is absent, is not a regular file, or is a reparse point
    psrPackMissing);

/// fixed diagnostic text - the machine authority, never localized prose
function PWebSdkRefusalText(Refusal: TPWebSdkRefusal): RawUtf8;

/// the SDK root associated with the RUNNING executable
// - Root is canonical; see the unit header for what it is not
function PWebCliSdkRoot(out Root: RawUtf8;
  out Refusal: TPWebSdkRefusal): Boolean;

/// the trusted template pack inside an EXPLICIT SDK root
// - Root must already be canonical (PWebCliCanonicalDir); this function
// never canonicalizes it, so a caller that skipped that step cannot be
// granted a confinement it did not establish
// - every component is resolved by its exact on-disk spelling and a reparse
// point anywhere refuses the whole path
function PWebCliTemplatePackIn(const Root: RawUtf8; out PackPath: RawUtf8;
  out Refusal: TPWebSdkRefusal): Boolean;

/// the trusted template pack of the running executable's own SDK
// - the composition of the two above, and the form the CLI itself will use
function PWebCliTemplatePack(out PackPath: RawUtf8;
  out Refusal: TPWebSdkRefusal): Boolean;


implementation

function PWebSdkRefusalText(Refusal: TPWebSdkRefusal): RawUtf8;
begin
  case Refusal of
    psrNone:              Result := 'ok';
    psrImageUnresolved:   Result := 'sdk_image_unresolved';
    psrNoRoot:            Result := 'sdk_no_root';
    psrShareMissing:      Result := 'sdk_share_missing';
    psrShareTreeMissing:  Result := 'sdk_share_tree_missing';
    psrPackMissing:       Result := 'sdk_pack_missing';
  else
    Result := 'sdk_refused';
  end;
end;

function PWebCliSdkRoot(out Root: RawUtf8;
  out Refusal: TPWebSdkRefusal): Boolean;
var
  exeDir: RawUtf8;
begin
  Root := '';
  Result := False;
  if not PWebCliExeDir(exeDir) then
  begin
    Refusal := psrImageUnresolved;
    exit;
  end;
  // the one step: <sdk>/bin -> <sdk>. PWebCliParentDir works on a CANONICAL
  // path and stops at the filesystem root, so this can never climb out of a
  // volume by appending '..' to a string
  if not PWebCliParentDir(exeDir, Root) then
  begin
    Root := '';
    Refusal := psrNoRoot;
    exit;
  end;
  Refusal := psrNone;
  Result := True;
end;

function PWebCliTemplatePackIn(const Root: RawUtf8; out PackPath: RawUtf8;
  out Refusal: TPWebSdkRefusal): Boolean;
var
  share, tree: RawUtf8;
begin
  PackPath := '';
  Result := False;
  if Root = '' then
  begin
    Refusal := psrNoRoot;
    exit;
  end;
  // PWebCliEntry reads the directory and compares the name byte-exactly,
  // and reports a junction or a symlink as pcnLink - so each of these three
  // steps refuses a redirected component rather than following it
  if PWebCliEntry(Root, PWEB_SDK_SHARE) <> pcnDirectory then
  begin
    Refusal := psrShareMissing;
    exit;
  end;
  share := PWebCliJoin(Root, PWEB_SDK_SHARE);
  if PWebCliEntry(share, PWEB_SDK_SHARE_PWEB) <> pcnDirectory then
  begin
    Refusal := psrShareTreeMissing;
    exit;
  end;
  tree := PWebCliJoin(share, PWEB_SDK_SHARE_PWEB);
  if PWebCliEntry(tree, PWEB_SDK_TEMPLATE_PACK) <> pcnFile then
  begin
    Refusal := psrPackMissing;
    exit;
  end;
  PackPath := PWebCliJoin(tree, PWEB_SDK_TEMPLATE_PACK);
  Refusal := psrNone;
  Result := True;
end;

function PWebCliTemplatePack(out PackPath: RawUtf8;
  out Refusal: TPWebSdkRefusal): Boolean;
var
  root: RawUtf8;
begin
  PackPath := '';
  Result := PWebCliSdkRoot(root, Refusal) and
    PWebCliTemplatePackIn(root, PackPath, Refusal);
end;

end.
