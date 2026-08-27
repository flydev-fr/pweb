{
  pweb.cli.scaffold - CAP-10B0 identity mapping, the placeholder renderer,
  and the complete creation plan.

  DELIBERATELY FILESYSTEM-FREE AND PLATFORM-FREE. Everything here happens in
  memory over a verified IAssetStore and a validated registry. It decides
  what a new project WOULD contain, down to the last byte and its digest,
  and hands that to pweb.cli.write - which is the only unit that can create
  anything.

  That split is not tidiness. A test can build a complete plan, inspect
  every path, every byte and every collision verdict, and assert the whole
  refusal matrix WITHOUT a single directory existing. A creation engine
  whose refusals can only be observed by watching it half-write a tree is a
  creation engine whose refusals nobody can characterise.

  ---------------------------------------------------------------------------
  IDENTITY - STATED, NEVER DERIVED FROM A DISPLAY STRING
  ---------------------------------------------------------------------------

  The command shape CAP-10B1 will expose is:

      pweb create NAME --ui <kind> --bundle-id <reverse.dns> [--output <dir>]

  NAME's grammar here is ^[a-z][a-z0-9]*$ - a STRICT SUBSET of the schema-1
  `name` grammar, which also permits hyphens. `pweb create my-app` is
  refused, and that refusal is the point:

      the Pascal program identifier grammar (PWebCliValidProgramIdent) has
      no hyphen. So a hyphenated NAME would force one of - delete the
      hyphen (a lossy transformation of an identifier), add an option whose
      meaning applies only sometimes, or fix every generated executable to
      one constant name. Refusing the input transforms nothing, and CAP-10A
      already ratified the principle: identifiers are stated, not inferred.

  Everything else falls out with NO derivation at all:

      destination directory      NAME
      pweb.json "name"           NAME
      Pascal program identifier  NAME
      executable base name       NAME
      native.program             <native-dir>/NAME.<native-ext>
      frontend.root              the template's declared root
      output                     the template's declared output directory
      version                    PWEB_SCAFFOLD_INITIAL_VERSION
      bundleId                   the --bundle-id value, verbatim

  bundleId is REQUIRED and never defaulted. CAP-10A wrote the reason down:
  inventing an organisation from a project name is exactly the silent
  derivation the contract refuses, and a default would give every developer
  who scaffolds `notes` the same CFBundleIdentifier and the same Windows
  AppId - a collision in the one field whose entire job is to be unique.

  ---------------------------------------------------------------------------
  THE RENDERER, AND THE ONE THING IT REFUSES TO BE
  ---------------------------------------------------------------------------

  Six tokens, one non-recursive pass, no expressions, no conditions, no
  loops, no includes, no environment interpolation, no user-defined names.
  A doubled opening brace ANYWHERE in a text template opens a token: there
  is no escape sequence and no literal form, so `unknown token` and
  `unresolved token` are both hard failures rather than something that
  quietly survives into a generated file.

  The cost is a real authoring constraint - a template cannot contain a
  doubled brace for its own purposes, which JSX inline-style syntax does -
  and it is deliberate. The alternative is a rule that passes unrecognised
  braces through, and then a typo in a token name is a silent, permanent
  string in somebody's new project.

  Three of the six tokens are equal by construction in v1, because NAME is
  the project name, the program identifier and the executable name at once.
  They stay three separate contract slots so a later schema can decouple
  them, and the corpus records all six projected values so that if one ever
  does diverge, the evidence shows it rather than the executable name does.

  ---------------------------------------------------------------------------
  PATHS OUT OF PLACEHOLDERS
  ---------------------------------------------------------------------------

  A rendered output path is checked twice and for two different things:

    - it must satisfy the canonical logical-path grammar with NO
      placeholder left in it, which is the syntax question;
    - it must have EXACTLY as many '/'-separated segments as the template
      path it came from, which is the structural question.

  The second check is what makes separator injection impossible rather than
  merely unlikely. Today no identity value can contain a '/' anyway - but a
  rule that holds because of a grammar three units away is a rule that
  stops holding the day that grammar widens, and nobody re-reads this file
  when it does.
}
unit pweb.cli.scaffold;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  pweb.assets.intf,
  pweb.assets.support,
  pweb.cli.project,
  pweb.cli.template;

const
  /// the version every scaffolded project starts at. A constant, not a
  // guess and not an option: schema 1 requires strict X.Y.Z and a new
  // project has no history to have a version of
  PWEB_SCAFFOLD_INITIAL_VERSION = '0.1.0';

  /// the ONE descriptor a created project carries, generated rather than
  // templated - so its bytes are produced by a serializer whose output the
  // frozen CAP-10A reader then has to accept
  PWEB_SCAFFOLD_DESCRIPTOR = 'pweb.json';

  /// NAME's byte bound. The schema-1 `name` bound, so a NAME that passes
  // here always produces a descriptor that parses
  PWEB_SCAFFOLD_NAME_MAX_BYTES = 64;

type
  /// why a project could not be planned or created - machine-stable, one
  // cause each. Ordinal 0 is the accepted state
  TPWebScaffoldCode = (
    pscNone,
    // ---- identity ----
    pscName,
    pscBundleId,
    pscTemplate,
    // ---- rendering ----
    pscTokenUnknown,          // a token name outside the fixed allowlist
    pscTokenUnterminated,     // a doubled brace with no closing pair
    pscTokenEmpty,
    pscTokenValue,            // a substituted value failed its bound
    pscRenderPath,            // the rendered path failed the grammar
    pscRenderSegments,        // the rendered path gained or lost a segment
    pscSourceEncoding,        // a packed text template is not strict UTF-8
    pscSourceLineEnding,      // a CR, or a missing/doubled final newline
    pscRenderEncoding,        // the RENDERED text is not strict UTF-8
    pscRenderLineEnding,      // the RENDERED text broke the LF contract
    pscRenderMarker,          // a token survived into the output
    // ---- the plan ----
    pscPlanSourceMissing,     // the store has no such archive entry
    pscPlanDuplicate,
    pscPlanCollision,         // Unicode fold or file/directory collision
    pscPlanFileCount,
    pscPlanFileSize,
    pscPlanTotalSize,
    pscPlanPathLength,
    pscPlanSecret,            // a secret or build artifact would be written
    pscPlanHostPath,          // an absolute host path would be written
    // ---- the generated descriptor ----
    pscDescriptorShape,
    pscDescriptorReject,      // the frozen CAP-10A reader refused it
    pscDescriptorMismatch);   // it parsed, but not to the planned identity

  /// the six substituted values, projected once from the command inputs
  TPWebScaffoldIdentity = record
    ProjectName: RawUtf8;
    PascalProgram: RawUtf8;
    ExecutableName: RawUtf8;
    BundleId: RawUtf8;
    ProjectVersion: RawUtf8;
    UiKind: RawUtf8;
  end;

  /// ONE file a created project would contain
  TPWebPlanFile = record
    /// project-relative, forward slashes, fully rendered
    Path: RawUtf8;
    Content: RawByteString;
    Sha256: RawUtf8;
    Kind: TPWebTplContent;
    Mode: TPWebTplMode;
    /// the archive entry this came from; '' for a generated file
    Source: RawUtf8;
  end;
  TPWebPlanFiles = array of TPWebPlanFile;

  /// the complete, immutable description of a project that does not exist
  // yet. Every collision, every bound and every encoding rule has already
  // been decided by the time this record is returned
  TPWebCreationPlan = record
    Identity: TPWebScaffoldIdentity;
    TemplateId: RawUtf8;
    /// sorted bytewise by Path
    Files: TPWebPlanFiles;
    TotalBytes: Int64;
    /// SHA-256 of PWebPlanText - the four-target equality field
    Digest: RawUtf8;
  end;

/// fixed diagnostic text for a code - the machine authority, never prose
function PWebScaffoldCodeText(Code: TPWebScaffoldCode): RawUtf8;

/// the CREATE name grammar: ^[a-z][a-z0-9]*$, 1..64 bytes
// - a strict subset of the schema-1 `name` grammar; see the unit header
function PWebScaffoldNameValid(const Name: RawUtf8): Boolean;

/// project the six substituted values from the command inputs
// - Ui comes from the selected template, never from the command line, so a
// template and its descriptor can never disagree about the frontend kind
function PWebScaffoldIdentityOf(const Name, BundleId, Ui: RawUtf8;
  out Identity: TPWebScaffoldIdentity;
  out Code: TPWebScaffoldCode): Boolean;

/// the fixed token allowlist, in a stable order - for diagnostics, for the
/// contract document and for the corpus
function PWebScaffoldTokenNames: TRawUtf8DynArray;

/// substitute the six tokens in one pass
// - never rescans its own output, so a value containing a doubled brace
// cannot re-expand
// - an unknown name, an unterminated token or an over-long value is a hard
// failure; nothing is ever passed through unrecognised
function PWebScaffoldRender(const Template: RawUtf8;
  const Identity: TPWebScaffoldIdentity; out Output: RawUtf8;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;

/// render one OUTPUT PATH and check it structurally
// - the rendered path must satisfy the canonical grammar with no
// placeholder left, and must have exactly the segment count of the
// template path it came from
function PWebScaffoldRenderPath(const Template: RawUtf8;
  const Identity: TPWebScaffoldIdentity; out Output: RawUtf8;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;

/// the canonical descriptor bytes for a planned project
// - fixed key order, two-space indent, LF, exactly one trailing newline;
// the same shape docs/cli-contract.md prints, so what a reader sees there
// is what `create` emits
function PWebScaffoldDescriptor(const Identity: TPWebScaffoldIdentity;
  const Tpl: TPWebTplTemplate): RawUtf8;

/// the canonical projection of a plan: one LF-terminated
// 'path bytes kind mode sha source' line per file, in the plan's own order,
// under an identity header
function PWebPlanText(const Plan: TPWebCreationPlan): RawUtf8;
/// SHA-256 of PWebPlanText
function PWebPlanDigest(const Plan: TPWebCreationPlan): RawUtf8;

/// the canonical projection of what a created project CONTAINS, without
/// the identity header - so two different projects made from one template
/// can still be compared structurally
function PWebPlanInventoryText(const Plan: TPWebCreationPlan): RawUtf8;
/// SHA-256 of PWebPlanInventoryText
function PWebPlanInventoryDigest(const Plan: TPWebCreationPlan): RawUtf8;

/// build the COMPLETE creation plan, in memory, before anything exists
// - Store must be one PWebTplVerifyPack already returned; Reg must be the
// registry that verified it, and TemplateIndex a row of that registry
// - every path collision, size bound, secret name and encoding rule is
// decided here. Nothing is discovered later, while writing
function PWebBuildPlan(const Reg: TPWebTemplateRegistry;
  TemplateIndex: Integer; const Store: IAssetStore;
  const Identity: TPWebScaffoldIdentity; out Plan: TPWebCreationPlan;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;

/// re-parse generated descriptor bytes with the FROZEN CAP-10A reader and
/// require every field to equal the planned identity
// - Root is the directory the descriptor was actually written into, so the
// path fields are resolved against a tree that exists
function PWebVerifyDescriptor(const Root, Json: RawUtf8;
  const Identity: TPWebScaffoldIdentity; const Tpl: TPWebTplTemplate;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;


implementation

const
  PWEB_SCAFFOLD_CODE_TEXT: array[TPWebScaffoldCode] of RawUtf8 = (
    'ok',
    'name',
    'bundle_id',
    'template',
    'token_unknown',
    'token_unterminated',
    'token_empty',
    'token_value',
    'render_path',
    'render_segments',
    'source_encoding',
    'source_line_ending',
    'render_encoding',
    'render_line_ending',
    'render_marker',
    'plan_source_missing',
    'plan_duplicate',
    'plan_collision',
    'plan_file_count',
    'plan_file_size',
    'plan_total_size',
    'plan_path_length',
    'plan_secret',
    'plan_host_path',
    'descriptor_shape',
    'descriptor_reject',
    'descriptor_mismatch');

  /// THE allowlist. Six names, fixed, in one place. Nothing reads this
  // from a template, a descriptor or an environment
  PWEB_SCAFFOLD_TOKENS: array[0 .. 5] of RawUtf8 = (
    'PROJECT_NAME',
    'PASCAL_PROGRAM',
    'EXECUTABLE_NAME',
    'BUNDLE_ID',
    'PROJECT_VERSION',
    'UI_KIND');

function PWebScaffoldCodeText(Code: TPWebScaffoldCode): RawUtf8;
begin
  Result := PWEB_SCAFFOLD_CODE_TEXT[Code];
end;

function IntStr(Value: Int64): RawUtf8;
begin
  Result := RawUtf8(IntToStr(Value));
end;

function PWebScaffoldTokenNames: TRawUtf8DynArray;
var
  i: PtrInt;
begin
  Result := nil;
  SetLength(Result, Length(PWEB_SCAFFOLD_TOKENS));
  for i := 0 to High(PWEB_SCAFFOLD_TOKENS) do
    Result[i] := PWEB_SCAFFOLD_TOKENS[i];
end;

function PWebScaffoldNameValid(const Name: RawUtf8): Boolean;
var
  i, len: PtrInt;
begin
  Result := False;
  len := Length(Name);
  if (len = 0) or
     (len > PWEB_SCAFFOLD_NAME_MAX_BYTES) then
    exit;
  if not ((Name[1] >= 'a') and (Name[1] <= 'z')) then
    exit;
  for i := 2 to len do
    if not (((Name[i] >= 'a') and (Name[i] <= 'z')) or
            ((Name[i] >= '0') and (Name[i] <= '9'))) then
      exit;
  Result := True;
end;

function PWebScaffoldIdentityOf(const Name, BundleId, Ui: RawUtf8;
  out Identity: TPWebScaffoldIdentity;
  out Code: TPWebScaffoldCode): Boolean;
begin
  Identity := Default(TPWebScaffoldIdentity);
  Result := False;
  if not PWebScaffoldNameValid(Name) then
  begin
    Code := pscName;
    exit;
  end;
  // the SAME grammar the descriptor reader will apply, asked here so the
  // refusal happens before anything is planned rather than after a tree
  // has been written and re-read
  if not PWebCliValidBundleId(BundleId) then
  begin
    Code := pscBundleId;
    exit;
  end;
  if (Ui <> 'react') and
     (Ui <> 'pas2js') then
  begin
    Code := pscTemplate;
    exit;
  end;
  // NAME is simultaneously the project name, the Pascal program identifier
  // and the executable base name. Three slots, one value, no derivation
  Identity.ProjectName := Name;
  Identity.PascalProgram := Name;
  Identity.ExecutableName := Name;
  Identity.BundleId := BundleId;
  Identity.ProjectVersion := PWEB_SCAFFOLD_INITIAL_VERSION;
  Identity.UiKind := Ui;
  // and the derived identifier must satisfy the FROZEN program-identifier
  // grammar, asked of the ratified validator rather than assumed from the
  // grammar above
  if not PWebCliValidProgramIdent(Identity.PascalProgram) then
  begin
    Identity := Default(TPWebScaffoldIdentity);
    Code := pscName;
    exit;
  end;
  Code := pscNone;
  Result := True;
end;

function TokenValue(const Name: RawUtf8;
  const Identity: TPWebScaffoldIdentity; out Value: RawUtf8): Boolean;
begin
  Result := True;
  if Name = 'PROJECT_NAME' then
    Value := Identity.ProjectName
  else if Name = 'PASCAL_PROGRAM' then
    Value := Identity.PascalProgram
  else if Name = 'EXECUTABLE_NAME' then
    Value := Identity.ExecutableName
  else if Name = 'BUNDLE_ID' then
    Value := Identity.BundleId
  else if Name = 'PROJECT_VERSION' then
    Value := Identity.ProjectVersion
  else if Name = 'UI_KIND' then
    Value := Identity.UiKind
  else
  begin
    Value := '';
    Result := False;
  end;
end;

function PWebScaffoldRender(const Template: RawUtf8;
  const Identity: TPWebScaffoldIdentity; out Output: RawUtf8;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;
var
  i, len, nameStart, used, capacity, run: PtrInt;
  name, value: RawUtf8;

  { Append into a buffer that GROWS BY DOUBLING, and copy runs of ordinary
    bytes in one Move rather than one character at a time.

    That is not micro-optimisation, it is a bound. PWEB_TPL_FILE_MAX_BYTES
    permits a 1 MiB text template; appending a byte at a time to a managed
    string reallocates and copies on nearly every append, which is
    quadratic - about 5*10^11 byte copies for a file the limits explicitly
    allow. A trusted template that large is a mistake rather than an
    attack, but "the build hangs" is a terrible way to be told about it. }
  procedure Emit(P: PAnsiChar; Count: PtrInt);
  begin
    if Count <= 0 then
      exit;
    if used + Count > capacity then
    begin
      repeat
        if capacity = 0 then
          capacity := 256
        else
          capacity := capacity * 2;
      until capacity >= used + Count;
      SetLength(Output, capacity);
    end;
    Move(P^, PByteArray(Output)^[used], Count);
    Inc(used, Count);
  end;

begin
  Output := '';
  Detail := '';
  Code := pscNone;
  Result := False;
  len := Length(Template);
  used := 0;
  capacity := 0;
  i := 1;
  while i <= len do
  begin
    if (i < len) and
       (Template[i] = '{') and
       (Template[i + 1] = '{') then
    begin
      Inc(i, 2);
      nameStart := i;
      while (i <= len) and
            (((Template[i] >= 'A') and (Template[i] <= 'Z')) or
             (Template[i] = '_')) do
        Inc(i);
      name := Copy(Template, nameStart, i - nameStart);
      if name = '' then
      begin
        Code := pscTokenEmpty;
        Detail := 'at byte ' + IntStr(nameStart);
        Output := '';
        exit;
      end;
      if (i >= len) or
         (Template[i] <> '}') or
         (Template[i + 1] <> '}') then
      begin
        Code := pscTokenUnterminated;
        Detail := name;
        Output := '';
        exit;
      end;
      Inc(i, 2);
      if not TokenValue(name, Identity, value) then
      begin
        Code := pscTokenUnknown;
        Detail := name;
        Output := '';
        exit;
      end;
      if (value = '') or
         (Length(value) > PWEB_TPL_TOKEN_MAX_BYTES) then
      begin
        Code := pscTokenValue;
        Detail := name;
        Output := '';
        exit;
      end;
      // emitted, never rescanned: the output of a substitution is final,
      // which is what makes ONE pass a guarantee and not a detail
      Emit(PAnsiChar(pointer(value)), Length(value));
      continue;
    end;
    // the longest run of bytes that cannot open a token, copied at once
    run := i;
    while (run <= len) and
          not ((run < len) and (Template[run] = '{') and
               (Template[run + 1] = '{')) do
      Inc(run);
    Emit(@PByteArray(Template)^[i - 1], run - i);
    i := run;
  end;
  SetLength(Output, used);
  Result := True;
end;

function PWebScaffoldRenderPath(const Template: RawUtf8;
  const Identity: TPWebScaffoldIdentity; out Output: RawUtf8;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;
begin
  Result := False;
  if not PWebScaffoldRender(Template, Identity, Output, Code, Detail) then
    exit;
  // the syntax question, asked of the shared canonical grammar with NO
  // placeholder allowed: anything left over is not a path
  if not PWebTplPathValid(Output, {Placeholders=}False) then
  begin
    Code := pscRenderPath;
    Detail := Output;
    Output := '';
    exit;
  end;
  // and the STRUCTURAL question: a substitution may change what a segment
  // is called and may never change how many there are
  if PWebTplSegmentCount(Output) <> PWebTplSegmentCount(Template) then
  begin
    Code := pscRenderSegments;
    Detail := Template + ' -> ' + Output;
    Output := '';
    exit;
  end;
  Code := pscNone;
  Result := True;
end;

function PWebScaffoldDescriptor(const Identity: TPWebScaffoldIdentity;
  const Tpl: TPWebTplTemplate): RawUtf8;
begin
  // canonical by construction: fixed key order, two-space indent, LF, one
  // trailing newline. Every value here has already passed its grammar, so
  // none of them can carry a character JSON would have to escape
  Result :=
    '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "name": "' + Identity.ProjectName + '",' + #10 +
    '  "version": "' + Identity.ProjectVersion + '",' + #10 +
    '  "bundleId": "' + Identity.BundleId + '",' + #10 +
    '  "ui": "' + Identity.UiKind + '",' + #10 +
    '  "native": { "program": "' + Tpl.NativeDir + '/' +
      Identity.PascalProgram + '.' + Tpl.NativeExt + '" },' + #10 +
    '  "frontend": { "root": "' + Tpl.FrontendRoot + '" },' + #10 +
    '  "output": "' + Tpl.OutputDir + '"' + #10 +
    '}' + #10;
end;

{ ---------------- the plan ----------------------------------------------- }

function PWebPlanInventoryText(const Plan: TPWebCreationPlan): RawUtf8;
var
  i: PtrInt;
begin
  Result := '';
  for i := 0 to High(Plan.Files) do
    Result := Result + Plan.Files[i].Path + ' ' +
      IntStr(Length(Plan.Files[i].Content)) + ' ' +
      PWebTplContentText(Plan.Files[i].Kind) + ' ' +
      PWebTplModeText(Plan.Files[i].Mode) + ' ' +
      Plan.Files[i].Sha256 + #10;
end;

function PWebPlanInventoryDigest(const Plan: TPWebCreationPlan): RawUtf8;
begin
  Result := PWebTplSha256Hex(PWebPlanInventoryText(Plan));
end;

function PWebPlanText(const Plan: TPWebCreationPlan): RawUtf8;
begin
  Result := 'template ' + Plan.TemplateId + #10 +
    'identity ' + Plan.Identity.ProjectName + ' ' +
      Plan.Identity.PascalProgram + ' ' + Plan.Identity.ExecutableName +
      ' ' + Plan.Identity.BundleId + ' ' + Plan.Identity.ProjectVersion +
      ' ' + Plan.Identity.UiKind + #10 +
    'total ' + IntStr(Plan.TotalBytes) + #10 +
    PWebPlanInventoryText(Plan);
end;

function PWebPlanDigest(const Plan: TPWebCreationPlan): RawUtf8;
begin
  Result := PWebTplSha256Hex(PWebPlanText(Plan));
end;

function SortPlan(var Files: TPWebPlanFiles): Boolean;
var
  i, j: PtrInt;
  tmp: TPWebPlanFile;
begin
  for i := 1 to High(Files) do
  begin
    tmp := Files[i];
    j := i - 1;
    while (j >= 0) and
          (CompareStr(Files[j].Path, tmp.Path) > 0) do
    begin
      Files[j + 1] := Files[j];
      Dec(j);
    end;
    Files[j + 1] := tmp;
  end;
  Result := True;
  for i := 1 to High(Files) do
    if Files[i].Path = Files[i - 1].Path then
      exit(False);
end;

function StartsWithStr(const S, Prefix: RawUtf8): Boolean;
begin
  Result := (Length(S) >= Length(Prefix)) and
    (CompareStr(Copy(S, 1, Length(Prefix)), Prefix) = 0);
end;

function PWebBuildPlan(const Reg: TPWebTemplateRegistry;
  TemplateIndex: Integer; const Store: IAssetStore;
  const Identity: TPWebScaffoldIdentity; out Plan: TPWebCreationPlan;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;
var
  tpl: TPWebTplTemplate;
  asset: TAssetResponse;
  folded: TRawUtf8DynArray;
  i, j, n: PtrInt;
  rendered, descriptor, text: RawUtf8;
  body: RawByteString;
  tcode: TPWebTplCode;
begin
  Plan := Default(TPWebCreationPlan);
  Detail := '';
  Result := False;
  if (Store = nil) or
     (TemplateIndex < 0) or
     (TemplateIndex > High(Reg.Templates)) then
  begin
    Code := pscTemplate;
    exit;
  end;
  tpl := Reg.Templates[TemplateIndex];
  // the descriptor's `ui` is the TEMPLATE's, so a command line and a
  // template can never disagree about the frontend kind
  if Identity.UiKind <> tpl.Ui then
  begin
    Code := pscTemplate;
    Detail := Identity.UiKind + ' vs ' + tpl.Ui;
    exit;
  end;
  Plan.Identity := Identity;
  Plan.TemplateId := tpl.Id;
  n := 0;
  SetLength(Plan.Files, tpl.FileCount + 1); // + the generated descriptor
  for i := tpl.FirstFile to tpl.FirstFile + tpl.FileCount - 1 do
  begin
    if not Store.TryRead(Reg.Files[i].Archive, asset) then
    begin
      Code := pscPlanSourceMissing;
      Detail := Reg.Files[i].Archive;
      exit;
    end;
    if not PWebScaffoldRenderPath(Reg.Files[i].OutPath, Identity, rendered,
         Code, Detail) then
      exit;
    if Reg.Files[i].Content = ptkText then
    begin
      // the SOURCE must already obey the text contract, so a template that
      // was authored with CRLF fails at the source rather than producing a
      // generated file whose bytes depend on who checked the repo out
      if not PWebTplTextValid(asset.Content, tcode) then
      begin
        if tcode = ptcEntryEncoding then
          Code := pscSourceEncoding
        else
          Code := pscSourceLineEnding;
        Detail := Reg.Files[i].Archive;
        exit;
      end;
      // a real local of the renderer's own type, then one raw assignment.
      // Passing RawByteString through a typecast as an OUT parameter works
      // and reads like a trick; RawByteString is the codepage-free type, so
      // the assignment below copies bytes and converts nothing
      if not PWebScaffoldRender(RawUtf8(asset.Content), Identity, text,
           Code, Detail) then
      begin
        Detail := Reg.Files[i].Archive + ': ' + Detail;
        exit;
      end;
      body := text;
      // and the RENDERED bytes must obey it too: a substitution cannot
      // introduce a CR, a NUL or an invalid sequence, but proving that
      // costs one pass and assuming it costs a corpus
      if not PWebTplTextValid(body, tcode) then
      begin
        if tcode = ptcEntryEncoding then
          Code := pscRenderEncoding
        else
          Code := pscRenderLineEnding;
        Detail := Reg.Files[i].Archive;
        exit;
      end;
      // no token may survive. Under this renderer none can, which is
      // exactly why the check is cheap enough to keep
      for j := 1 to Length(body) - 1 do
        if (body[j] = '{') and
           (body[j + 1] = '{') then
        begin
          Code := pscRenderMarker;
          Detail := Reg.Files[i].Archive;
          exit;
        end;
    end
    else
      // byte-exact. A binary file is never scanned for tokens and never
      // substituted, whatever its bytes happen to look like
      body := asset.Content;
    if PWebTplSecretOutput(rendered) then
    begin
      Code := pscPlanSecret;
      Detail := rendered;
      exit;
    end;
    if PWebTplHasHostPath(body) then
    begin
      Code := pscPlanHostPath;
      Detail := rendered;
      exit;
    end;
    Plan.Files[n].Path := rendered;
    Plan.Files[n].Content := body;
    Plan.Files[n].Sha256 := PWebTplSha256Hex(body);
    Plan.Files[n].Kind := Reg.Files[i].Content;
    Plan.Files[n].Mode := Reg.Files[i].Mode;
    Plan.Files[n].Source := Reg.Files[i].Archive;
    Inc(n);
  end;
  // the generated descriptor. It is NOT a template file: its bytes come
  // from a serializer, so the frozen reader has to accept what a serializer
  // produced rather than what somebody typed into a template
  descriptor := PWebScaffoldDescriptor(Identity, tpl);
  if not PWebTplTextValid(descriptor, tcode) then
  begin
    Code := pscDescriptorShape;
    exit;
  end;
  Plan.Files[n].Path := PWEB_SCAFFOLD_DESCRIPTOR;
  Plan.Files[n].Content := descriptor;
  Plan.Files[n].Sha256 := PWebTplSha256Hex(descriptor);
  Plan.Files[n].Kind := ptkText;
  Plan.Files[n].Mode := ptmNormal;
  Plan.Files[n].Source := '';
  Inc(n);
  SetLength(Plan.Files, n);
  // ---- the whole-plan validation. Every one of these is decided HERE,
  // before pweb.cli.write has been told a destination even exists ----
  if not SortPlan(Plan.Files) then
  begin
    Code := pscPlanDuplicate;
    exit;
  end;
  if n > PWEB_TPL_MAX_OUTPUT_FILES then
  begin
    Code := pscPlanFileCount;
    Detail := IntStr(n);
    exit;
  end;
  Plan.TotalBytes := 0;
  for i := 0 to n - 1 do
  begin
    if Length(Plan.Files[i].Path) > PWEB_TPL_PATH_MAX_BYTES then
    begin
      Code := pscPlanPathLength;
      Detail := Plan.Files[i].Path;
      exit;
    end;
    if Length(Plan.Files[i].Content) > PWEB_TPL_FILE_MAX_BYTES then
    begin
      Code := pscPlanFileSize;
      Detail := Plan.Files[i].Path;
      exit;
    end;
    Inc(Plan.TotalBytes, Length(Plan.Files[i].Content));
  end;
  if Plan.TotalBytes > PWEB_TPL_TOTAL_MAX_BYTES then
  begin
    Code := pscPlanTotalSize;
    Detail := IntStr(Plan.TotalBytes);
    exit;
  end;
  // the ratified CAP-6 D1 fold rule, applied to OUTPUT paths: two files
  // that differ only by case cannot both exist on NTFS or on a default
  // APFS volume, and a scaffold that half-writes on two platforms and
  // fully writes on a third is worse than one that refuses everywhere
  SetLength(folded, n);
  for i := 0 to n - 1 do
    folded[i] := UpperCaseReference(Plan.Files[i].Path);
  for i := 0 to n - 1 do
    for j := i + 1 to n - 1 do
      if folded[i] = folded[j] then
      begin
        Code := pscPlanCollision;
        Detail := Plan.Files[i].Path + ' vs ' + Plan.Files[j].Path;
        exit;
      end;
  // a file that is also a directory prefix of another cannot exist in any
  // filesystem layout
  for i := 0 to n - 1 do
    for j := 0 to n - 1 do
      if (i <> j) and
         (Length(Plan.Files[j].Path) > Length(Plan.Files[i].Path) + 1) and
         StartsWithStr(Plan.Files[j].Path, Plan.Files[i].Path) and
         (Plan.Files[j].Path[Length(Plan.Files[i].Path) + 1] = '/') then
      begin
        Code := pscPlanCollision;
        Detail := Plan.Files[i].Path + ' vs ' + Plan.Files[j].Path;
        exit;
      end;
  Plan.Digest := PWebPlanDigest(Plan);
  Code := pscNone;
  Result := True;
end;

function PWebVerifyDescriptor(const Root, Json: RawUtf8;
  const Identity: TPWebScaffoldIdentity; const Tpl: TPWebTplTemplate;
  out Code: TPWebScaffoldCode; out Detail: RawUtf8): Boolean;
var
  project: TPWebCliProject;
begin
  Detail := '';
  Result := False;
  // the FROZEN CAP-10A reader, unmodified and un-relaxed. If a generated
  // descriptor cannot survive the reader every other project must survive,
  // the generator is wrong - not the reader
  project := PWebCliParseDescriptor(Root, Json);
  if project.Refusal <> pcrNone then
  begin
    Code := pscDescriptorReject;
    Detail := PWebCliProjectRefusalText(project.Refusal);
    if project.Detail <> '' then
      Detail := Detail + ':' + project.Detail;
    exit;
  end;
  Code := pscDescriptorMismatch;
  if project.Schema <> PWEB_CLI_SCHEMA then
  begin
    Detail := 'schema';
    exit;
  end;
  if project.Name <> Identity.ProjectName then
  begin
    Detail := 'name';
    exit;
  end;
  if project.Version <> Identity.ProjectVersion then
  begin
    Detail := 'version';
    exit;
  end;
  if project.BundleId <> Identity.BundleId then
  begin
    Detail := 'bundleId';
    exit;
  end;
  if PWebCliUiText(project.Ui) <> Identity.UiKind then
  begin
    Detail := 'ui';
    exit;
  end;
  if project.NativeProgram <> Tpl.NativeDir + '/' +
       Identity.PascalProgram + '.' + Tpl.NativeExt then
  begin
    Detail := 'native.program';
    exit;
  end;
  if project.FrontendRoot <> Tpl.FrontendRoot then
  begin
    Detail := 'frontend.root';
    exit;
  end;
  if project.Output <> Tpl.OutputDir then
  begin
    Detail := 'output';
    exit;
  end;
  // and the identifier the READER derived must be the one we planned - the
  // one field where a generator and a reader could each be internally
  // consistent and still disagree
  if project.ProgramIdent <> Identity.PascalProgram then
  begin
    Detail := 'programIdent';
    exit;
  end;
  Code := pscNone;
  Result := True;
end;

end.
