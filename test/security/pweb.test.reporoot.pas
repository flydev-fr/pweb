/// the ONE repository-root walk the test hosts share
// - deferred-work 8B-7 recorded three private copies of this function and
//   asked for one shared helper "next time any of the three hosts is
//   edited"; 8C-3 recorded a fourth. By the post-MVP triage there were
//   NINE, and one of them had already drifted - which is the whole of what
//   that entry predicted, arriving on schedule
// - IT LIVES UNDER test/security, AND THE REASON IS A PROOF RATHER THAN A
//   PREFERENCE. Two of the nine callers are `pweb.test.capabilities` and
//   `pweb.test.navigation`, which live in this directory - so EVERY compile
//   that can reach them already passes `-Futest/security`, and putting the
//   helper here means every such compile finds it by construction rather than
//   by anyone having enumerated the call sites correctly.
//   The first draft put it under test/core, on the narrower observation that
//   the mORMot-core suite's action passes `-Futest/core`. That was true and
//   insufficient: `test/rpc/cap3tests.pas` reaches
//   `pweb.test.capabilities.integration`, which uses `pweb.test.capabilities`,
//   and the CAP-3U action passes `-Futest/rpc -Futest/security` and no
//   `test/core`. One hosted Windows leg died at
//   `Can't find unit pweb.test.reporoot`. Checking the top of a uses clause
//   is not checking what it pulls in.
// - the seven remaining hosts name `-Futest/security` in both their .ps1 and
//   .sh twins
// - it is TEST SUPPORT and ships in nothing: no unit under src/ or tools/
//   names it, and the CAP-9C1 packager assembles a declared set rather than
//   a directory, so there is no path on which it could reach a distribution
unit pweb.test.reporoot;

{$I mormot.defines.inc}

interface

uses
  SysUtils,
  mormot.core.base,
  mormot.core.os;

/// the repository root, found by walking up from the running image
// - the anchor is `webview.lock`, a file that exists once and only at the
//   root, so the walk asks a question with one answer rather than counting
//   directory levels a build layout is free to change
// - BOUNDED AT EIGHT LEVELS, which is the depth every test host is built at
//   plus headroom; a host that has to raise it has moved somewhere the rest
//   of the harness does not expect
// - returns '' when no root is found, and every caller refuses on that
//   rather than proceeding with a relative path
function RepoRootFromExecutable: TFileName;

implementation

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
  dir := Executable.ProgramFilePath; // trailing delimiter guaranteed
  for i := 1 to 8 do
  begin
    if FileExists(dir + 'webview.lock') then
      exit(dir);
    // THE PARENT IS TAKEN BY TRUNCATION AND THE LOOP STOPS WHEN IT STOPS
    // MOVING. The alternative that had drifted into one of the nine copies
    // - `dir := ExpandFileName(dir + '..' + PathDelim)` - is not equivalent
    // in the case that matters: at a filesystem root `..` resolves to the
    // root again, so that form has no termination condition of its own and
    // is held only by the iteration bound. This form asks the filesystem
    // nothing, cannot loop, and answers '' rather than a wrong directory.
    parent := ExtractFilePath(ExcludeTrailingPathDelimiter(dir));
    if (parent = '') or (parent = dir) then
      break;
    dir := parent;
  end;
  Result := '';
end;

end.
