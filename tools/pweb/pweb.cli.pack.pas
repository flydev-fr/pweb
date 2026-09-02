{
  pweb.cli.pack - app.pwb, through the frozen CAP-6 bundler (CAP-10C1).

  The pipeline does NOT pack the archive itself. `pwebbundle` is the frozen
  CAP-6 release bundler - a deterministic writer with a global bytewise sort,
  a fixed DOS timestamp, a fixed deflate level, no extra fields, its own
  self-validation and an atomic replace - and it ships in the SDK's bin/
  beside `pweb`. Reimplementing its rules inside the CLI would be a second
  writer for one format, and the interesting failure of a second writer is
  that it agrees with the first until it does not.

  So this unit's whole content is the ARGUMENT CONTRACT, stated once:

      pwebbundle <dist-directory> <out.pwb>

  and nothing else. No --min-runtime, no --max-asset-bytes, no
  --include-sourcemaps: the manifest's protocol and minRuntime come from the
  runtime constants the bundler is compiled with, the asset threshold is the
  ratified one, and a source map that reached a release would be a defect
  rather than an option. Those are exactly the three arguments the CAP-10B1
  and CAP-10B2 harnesses withhold, and byte parity with what they produce is
  this shard's acceptance.
}
unit pweb.cli.pack;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.stage;

const
  /// the ONE bundle name, resolved by the host exactly where run places it
  PWEB_PACK_BUNDLE = 'app.pwb';

/// `pwebbundle <dist> <out.pwb>` - the whole argument contract
// - BundlerPath is the SDK root's own bin/pwebbundle[.exe]
// - WorkDir is the project root: every path is absolute, so the working
// directory decides nothing, and stating it is what every spawn owes the
// supervision contract
function PWebCliPackCommand(const BundlerPath, DistDir, OutPwb,
  ProjectRoot: RawUtf8): TPWebCliCommand;


implementation

function PWebCliPackCommand(const BundlerPath, DistDir, OutPwb,
  ProjectRoot: RawUtf8): TPWebCliCommand;
begin
  Result := Default(TPWebCliCommand);
  Result.Exe := BundlerPath;
  SetLength(Result.Args, 2);
  Result.Args[0] := PWebCliArgPath(DistDir);
  Result.Args[1] := PWebCliArgPath(OutPwb);
  Result.WorkDir := ProjectRoot;
end;

end.
