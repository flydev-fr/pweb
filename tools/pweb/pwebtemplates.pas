program pwebtemplates;

{ The CAP-10B0 trusted template-pack builder.

    pwebtemplates --source <dir> --pack <file> --registry <file>
                  [--include all|public|private]

  It reads the trusted template list and the template tree beside it, and
  produces exactly two artifacts:

    <pack>       pweb-templates.zip - every entry STORED, canonical order,
                 fixed timestamp, no extra field. Bytes only.
    <registry>   pweb.templates.registry.inc - the generated native trust
                 anchor, compiled into whatever consumes the pack. Every
                 name, output path, content kind, file mode, byte length and
                 digest lives here and NOWHERE else.

  WHAT IT REFUSES, and why each refusal belongs at build time:

    - a file on disk that the list does not declare, and a declared file
      that is not on disk. The cross-check runs in BOTH directions, because
      a template corpus that quietly grew a file is how an unreviewed byte
      reaches somebody's new project;
    - a symlink, a junction or anything that is not a regular file anywhere
      in the tree. Trusted build input is read, never followed;
    - a text template carrying a CR, a NUL, a BOM, invalid UTF-8, or no
      final newline. The CR rule is the one that matters most: Git for
      Windows defaults to core.autocrlf=true, and a CRLF checkout would
      otherwise make the Windows pack diverge from the Linux one by exactly
      the carriage returns - the same divergence CAP-7F measured once
      already, in the frontend corpus;
    - an absolute host path, a home directory or a user name in ANY file,
      text or binary. A generated project must be portable between
      machines, and the cheapest place to prove that is before the bytes
      are ever packed;
    - an output path naming a credential, a key, a database or a build
      artifact.

  IT IS A BUILD TOOL, and it behaves like one: it takes its source from an
  explicit argument rather than from the working directory, it starts no
  process, it opens no socket, and it writes only the two files it was told
  to write.

  TWO PATH SHAPES, deliberately. Everything READ goes through the canonical
  kernel-resolved form (on Windows that carries the long-path prefix, which
  is what makes the exact-spelling walk and the reparse refusal work).
  Everything WRITTEN is a plain absolute path, because the artifacts do not
  exist yet and their parents are ordinary build directories. }

{$mode ObjFPC}{$H+}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  sysutils,
  mormot.core.base,
  pweb.cli.platform,
  pweb.cli.template;

const
  TOOL_ID = 'pwebtemplates';
  LIST_NAME = 'templates.list';
  /// how deep a template tree may go. A template is a project skeleton,
  // not an archive: anything deeper is a mistake worth naming
  MAX_TREE_DEPTH = 8;

var
  SourceDir: RawUtf8 = '';
  PackPath: RawUtf8 = '';
  RegistryPath: RawUtf8 = '';
  IncludeWhat: RawUtf8 = 'all';

procedure Die(const Message: RawUtf8);
begin
  WriteLn(StdErr, 'pwebtemplates: ', string(Message));
  Halt(1);
end;

procedure Usage;
begin
  WriteLn(StdErr, 'usage: pwebtemplates --source <dir> --pack <file> ' +
    '--registry <file> [--include all|public|private]');
  Halt(2);
end;

{ Long options only, one spelling each, no short forms and no environment
  fallback - the grammar rule CAP-10A froze for the public CLI, applied here
  so a build tool and the tool it builds for do not teach two different
  command-line conventions. }
procedure ParseArgs;
var
  i: Integer;
  arg: RawUtf8;

  function Take(const Name: RawUtf8; var Target: RawUtf8): Boolean;
  begin
    Result := arg = Name;
    if not Result then
      exit;
    if Target <> '' then
      Die('repeated option: ' + Name);
    if i >= ParamCount then
      Die('missing value for ' + Name);
    Inc(i);
    Target := RawUtf8(ParamStr(i));
    if Target = '' then
      Die('empty value for ' + Name);
  end;

begin
  i := 1;
  while i <= ParamCount do
  begin
    arg := RawUtf8(ParamStr(i));
    if not (Take('--source', SourceDir) or
            Take('--pack', PackPath) or
            Take('--registry', RegistryPath)) then
    begin
      if arg <> '--include' then
        Usage;
      if i >= ParamCount then
        Die('missing value for --include');
      Inc(i);
      IncludeWhat := RawUtf8(ParamStr(i));
      if (IncludeWhat <> 'all') and
         (IncludeWhat <> 'public') and
         (IncludeWhat <> 'private') then
        Die('--include must be all, public or private');
    end;
    Inc(i);
  end;
  if (SourceDir = '') or
     (PackPath = '') or
     (RegistryPath = '') then
    Usage;
end;

{ Join a canonical native directory and a logical forward-slash path, one
  segment at a time. NOT a string concatenation: a Windows canonical path
  carries the long-path prefix, and the kernel performs NO normalization on
  those - a forward slash left in one is simply part of the file name. }
function JoinLogical(const Dir, Logical: RawUtf8): RawUtf8;
var
  i, start: PtrInt;
begin
  Result := Dir;
  start := 1;
  for i := 1 to Length(Logical) + 1 do
    if (i > Length(Logical)) or
       (Logical[i] = '/') then
    begin
      Result := PWebCliJoin(Result, Copy(Logical, start, i - start));
      start := i + 1;
    end;
end;

{ Enumerate one template's tree into logical, root-relative paths. The
  filesystem's own order is never trusted; the caller sorts. }
procedure Collect(const Root, Prefix: RawUtf8; Depth: Integer;
  var Found: TRawUtf8DynArray);
var
  names: TRawUtf8DynArray;
  i: PtrInt;
  child, logical: RawUtf8;
begin
  if Depth > MAX_TREE_DEPTH then
    Die('template tree deeper than ' + RawUtf8(IntToStr(MAX_TREE_DEPTH)) +
      ' levels: ' + Prefix);
  if not PWebCliListDir(Root, names) then
    Die('cannot enumerate ' + PWebCliDisplayPath(Root));
  for i := 0 to High(names) do
  begin
    child := PWebCliJoin(Root, names[i]);
    if Prefix = '' then
      logical := names[i]
    else
      logical := Prefix + '/' + names[i];
    case PWebCliNodeKind(child) of
      pcnFile:
        begin
          SetLength(Found, Length(Found) + 1);
          Found[High(Found)] := logical;
        end;
      pcnDirectory:
        Collect(child, logical, Depth + 1, Found);
      pcnLink:
        // trusted build input is READ, never followed. A link here is not
        // a file to resolve, it is a review that did not happen
        Die('reparse point refused in the template source: ' + logical);
    else
      Die('not a regular file: ' + logical);
    end;
  end;
end;

function Contains(const List: TRawUtf8DynArray;
  const Item: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := True;
  for i := 0 to High(List) do
    if List[i] = Item then
      exit;
  Result := False;
end;

procedure WriteArtifact(const Path: RawUtf8; const Content: RawByteString);
var
  tmp: RawUtf8;
begin
  // regenerated on every build, so it cannot use the exclusive create the
  // PROJECT writer uses - but it still lands atomically, through the one
  // replacing primitive the platform seam exposes
  tmp := Path + '.tmp';
  PWebCliDeleteFile(tmp);
  if not PWebCliWriteNewFile(tmp, Content, {SetExecBit=}False) then
    Die('cannot write ' + tmp);
  if not PWebCliReplaceFile(tmp, Path) then
    Die('cannot replace ' + Path);
end;

var
  cwd, base, root, tplRoot, native, packAbs, regAbs, packName: RawUtf8;
  parentOfPack: RawUtf8;
  listBytes, content: RawByteString;
  tooBig, wanted: Boolean;
  templates: TPWebTrustedTemplates;
  files: TPWebTrustedFiles;
  code: TPWebTplCode;
  detail, text: RawUtf8;
  entries: TPWebTplEntries;
  roots, found: TRawUtf8DynArray;
  inv: TPWebTplInventory;
  regFiles: TPWebTplFiles;
  regTemplates: TPWebTplTemplates;
  reg: TPWebTemplateRegistry;
  packSha: RawUtf8;
  packBytes: Int64;
  t, i, j, n, kept: PtrInt;
  tmpTpl: TPWebTrustedTemplate;
  tmpFile: TPWebTrustedFile;

begin
  ParseArgs;
  if not PWebCliCwd(cwd) then
    Die('the working directory could not be resolved');
  // the READ side: canonical, kernel-resolved, exact-spelling walk
  if not PWebCliCanonicalDir(PWebCliAbsolute(cwd, SourceDir), root) then
    Die('not a directory: ' + SourceDir);
  // the WRITE side: plain absolute paths, since the artifacts do not exist
  base := PWebCliDisplayPath(cwd);
  packAbs := PWebCliAbsolute(base, PackPath);
  regAbs := PWebCliAbsolute(base, RegistryPath);
  if not PWebCliSplitLast(packAbs, parentOfPack, packName) then
    Die('--pack must name a file inside a directory');

  // ---- 1. the trusted list ----
  if PWebCliEntry(root, LIST_NAME) <> pcnFile then
    Die('missing ' + LIST_NAME + ' in ' + PWebCliDisplayPath(root));
  if not PWebCliReadSmallFile(PWebCliJoin(root, LIST_NAME),
       PWEB_TPL_LIST_MAX_BYTES, listBytes, tooBig) then
    Die('cannot read ' + LIST_NAME);
  if not PWebTplParseList(listBytes, templates, files, code, detail) then
    Die(PWebTplCodeText(code) + ': ' + detail);

  // ---- 2. the visibility filter. CAP-10B0 builds one private fixture;
  // CAP-10B1 will build a public release pack from the same list ----
  if IncludeWhat <> 'all' then
  begin
    kept := 0;
    for t := 0 to High(templates) do
      if (IncludeWhat = 'public') = templates[t].IsPublic then
      begin
        templates[kept] := templates[t];
        Inc(kept);
      end;
    SetLength(templates, kept);
    kept := 0;
    for i := 0 to High(files) do
    begin
      wanted := False;
      for t := 0 to High(templates) do
        if templates[t].Id = files[i].Template then
          wanted := True;
      if wanted then
      begin
        files[kept] := files[i];
        Inc(kept);
      end;
    end;
    SetLength(files, kept);
    if (Length(templates) = 0) or
       (Length(files) = 0) then
      Die('--include ' + IncludeWhat + ' selected no template');
  end;

  // ---- 3. sort: templates bytewise by id, files by '<template>/<source>'.
  // This order IS the registry, so it is established once and explicitly ----
  for i := 1 to High(templates) do
  begin
    tmpTpl := templates[i];
    j := i - 1;
    while (j >= 0) and
          (CompareStr(templates[j].Id, tmpTpl.Id) > 0) do
    begin
      templates[j + 1] := templates[j];
      Dec(j);
    end;
    templates[j + 1] := tmpTpl;
  end;
  for i := 1 to High(files) do
  begin
    tmpFile := files[i];
    j := i - 1;
    while (j >= 0) and
          (CompareStr(files[j].Template + '/' + files[j].Source,
             tmpFile.Template + '/' + tmpFile.Source) > 0) do
    begin
      files[j + 1] := files[j];
      Dec(j);
    end;
    files[j + 1] := tmpFile;
  end;

  // ---- 4. the two-directional cross-check, and every source sweep ----
  SetLength(roots, Length(templates));
  SetLength(entries, Length(files));
  n := 0;
  for t := 0 to High(templates) do
  begin
    roots[t] := templates[t].Id + '/';
    if PWebCliEntry(root, templates[t].Id) <> pcnDirectory then
      Die('template directory missing: ' + templates[t].Id);
    tplRoot := PWebCliJoin(root, templates[t].Id);
    found := nil;
    Collect(tplRoot, '', 0, found);
    // direction A: everything on disk must be declared
    for i := 0 to High(found) do
    begin
      wanted := False;
      for j := 0 to High(files) do
        if (files[j].Template = templates[t].Id) and
           (files[j].Source = found[i]) then
          wanted := True;
      if not wanted then
        Die('undeclared file in the template source: ' +
          templates[t].Id + '/' + found[i]);
    end;
    // direction B: everything declared must be on disk, and must survive
    // every sweep before a byte of it is packed
    for j := 0 to High(files) do
      if files[j].Template = templates[t].Id then
      begin
        if not Contains(found, files[j].Source) then
          Die('declared file missing from the template source: ' +
            templates[t].Id + '/' + files[j].Source);
        native := JoinLogical(tplRoot, files[j].Source);
        if not PWebCliReadSmallFile(native, PWEB_TPL_FILE_MAX_BYTES,
             content, tooBig) then
          Die('cannot read ' + templates[t].Id + '/' + files[j].Source);
        if (files[j].Content = ptkText) and
           not PWebTplTextValid(content, code) then
          Die(PWebTplCodeText(code) + ': ' + templates[t].Id + '/' +
            files[j].Source);
        if PWebTplHasHostPath(content) then
          Die(PWebTplCodeText(ptcEntryHostPath) + ': ' + templates[t].Id +
            '/' + files[j].Source);
        if PWebTplSecretOutput(files[j].OutPath) then
          Die(PWebTplCodeText(ptcEntrySecret) + ': ' + files[j].OutPath);
        entries[n].Name := templates[t].Id + '/' + files[j].Source;
        entries[n].Content := content;
        Inc(n);
      end;
  end;
  SetLength(entries, n);

  // ---- 5. the deterministic pack ----
  if not PWebTplWritePack(packAbs, entries, roots, inv, packSha, packBytes,
       code, detail) then
    Die(PWebTplCodeText(code) + ': ' + detail);

  // ---- 6. the registry. Its file rows are grouped by template and sorted
  // by archive name inside each group; its inventory is globally sorted, as
  // the writer returned it ----
  SetLength(regFiles, Length(files));
  SetLength(regTemplates, Length(templates));
  n := 0;
  for t := 0 to High(templates) do
  begin
    regTemplates[t].Id := templates[t].Id;
    regTemplates[t].IsPublic := templates[t].IsPublic;
    regTemplates[t].Ui := templates[t].Ui;
    regTemplates[t].NativeDir := templates[t].NativeDir;
    regTemplates[t].NativeExt := templates[t].NativeExt;
    regTemplates[t].FrontendRoot := templates[t].FrontendRoot;
    regTemplates[t].OutputDir := templates[t].OutputDir;
    regTemplates[t].FirstFile := n;
    regTemplates[t].FileCount := 0;
    for j := 0 to High(files) do
      if files[j].Template = templates[t].Id then
      begin
        regFiles[n].Archive := templates[t].Id + '/' + files[j].Source;
        regFiles[n].OutPath := files[j].OutPath;
        regFiles[n].Content := files[j].Content;
        regFiles[n].Mode := files[j].Mode;
        regFiles[n].Bytes := -1;
        for i := 0 to High(inv) do
          if inv[i].Name = regFiles[n].Archive then
          begin
            regFiles[n].Bytes := inv[i].Bytes;
            regFiles[n].Sha256 := inv[i].Sha256;
          end;
        if regFiles[n].Bytes < 0 then
          Die('the writer did not report ' + regFiles[n].Archive);
        Inc(n);
        Inc(regTemplates[t].FileCount);
      end;
  end;

  reg := PWebTplRegistryFrom(packName, packSha, packBytes,
    PWebTplInventoryDigest(inv), inv, regFiles, regTemplates);
  if not PWebTplValidateRegistry(reg, code, detail) then
    Die(PWebTplCodeText(code) + ': ' + detail);
  if not PWebTplEmitRegistry(reg, TOOL_ID, text, code, detail) then
    Die(PWebTplCodeText(code) + ': ' + detail);
  WriteArtifact(regAbs, text);

  // ---- 7. the machine-readable summary the gate reads ----
  WriteLn('pack_schema ', PWEB_TPL_SCHEMA);
  WriteLn('pack_file ', string(reg.PackFile));
  WriteLn('pack_sha256 ', string(packSha));
  WriteLn('pack_bytes ', packBytes);
  WriteLn('inventory_digest ', string(reg.InventoryDigest));
  WriteLn('registry_digest ', string(PWebTplRegistryDigest(reg)));
  WriteLn('templates ', Length(reg.Templates));
  WriteLn('files ', Length(reg.Files));
end.
