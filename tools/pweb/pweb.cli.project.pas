{
  pweb.cli.project - the pweb.json project contract (CAP-10A).

  ONE authoritative descriptor, read strictly, resolved deterministically.

  ---------------------------------------------------------------------------
  SCHEMA 1 - EIGHT REQUIRED KEYS, NO OPTIONAL KEYS
  ---------------------------------------------------------------------------

    {
      "schema": 1,
      "name": "my-app",
      "version": "0.1.0",
      "bundleId": "com.example.myapp",
      "ui": "react",
      "native":   { "program": "src/myapp.lpr" },
      "frontend": { "root": "frontend" },
      "output": "dist"
    }

  Every key is required and there are no optional keys at all. That is a
  deliberate choice about how this contract GROWS: an optional key added to
  schema 1 later would be accepted by a new CLI and refused by an old one
  while both call themselves schema 1, which is a silent change of meaning.
  Growth happens by bumping `schema`, and a bump is a visible, reviewable act.

  WHAT IT IS: developer-controlled build metadata, at the trust level of the
  developer's own source tree. WHAT IT IS NOT: frontend content. It is never
  read from app.pwb, plugins.zip, browser storage, JavaScript or a build
  output, and it carries no password, key, credential, certificate path or
  executable command string - a key that even LOOKS like one is refused with
  its own diagnostic rather than the generic unknown-field message, so the
  refusal survives a future schema that adds fields.

  ---------------------------------------------------------------------------
  THE GRAMMARS, AND WHY THEY ARE EXPLICIT
  ---------------------------------------------------------------------------

    name      ^[a-z][a-z0-9]*(-[a-z0-9]+)*$          1..64 bytes
    version   strict X.Y.Z                            (PWebSemVerValid)
    bundleId  ^[a-z][a-z0-9]*(\.[a-z][a-z0-9-]*)+$    2..5 labels, <=128
    ui        exactly 'react' or 'pas2js'
    paths     canonical logical paths (PWebAssetPathValid) resolved under the
              canonical project root

  The Pascal program identifier and the executable base name are the BASENAME
  of native.program without its extension, and that basename must itself
  match ^[a-z][a-z0-9]*$. Nothing is derived from a display string: CAP-10B
  will generate a unit, a product name, a Windows AppId and a
  CFBundleIdentifier, and every one of those needs a rule that a human can
  read off the descriptor rather than reconstruct from an algorithm.

  bundleId exists in schema 1 for the same reason. macOS needs a
  CFBundleIdentifier and Windows setup needs a stable AppId; inventing either
  from a name plus a guessed organisation is exactly the silent derivation
  this contract refuses. The identity is stated, once, by the developer.

  ---------------------------------------------------------------------------
  STRICTNESS OF THE READER
  ---------------------------------------------------------------------------

  UTF-8 with no BOM; strict shortest-form UTF-8 over the whole document
  (PWebStrictUtf8, the same one the asset paths and the plugin manifests
  use); no comments; nothing after the top-level object; duplicate keys
  refused after escape decoding, so "name" cannot smuggle a second
  "name" past the check; unknown keys refused; integers only in their strict
  form (no sign, no leading zero, no fraction, no exponent); raw control
  bytes refused inside strings; bounded at 64 KiB.
}
unit pweb.cli.project;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  pweb.assets.support,
  pweb.assets.bundle,
  pweb.cli.platform,
  pweb.cli.paths,
  pweb.cli.toolchain;

const
  /// the one descriptor filename, matched with EXACT case on every platform
  PWEB_CLI_DESCRIPTOR = 'pweb.json';
  /// the only schema this build understands
  PWEB_CLI_SCHEMA = 1;

type
  /// the ratified frontend kinds of schema 1
  TPWebCliUi = (puiReact, puiPas2js);

  /// why a project could not be established - machine-stable, one cause each
  // - ordinal 0 is the accepted state
  TPWebCliProjectRefusal = (
    pcrNone,
    /// no pweb.json at the explicit location
    pcrDescriptorMissing,
    /// upward discovery reached the filesystem root without finding one
    pcrDescriptorNotFound,
    /// --project named a file that is not exactly 'pweb.json'
    pcrDescriptorName,
    /// the descriptor is a symlink, junction or other reparse point
    pcrDescriptorLink,
    /// larger than PWEB_CLI_DESCRIPTOR_MAX_BYTES
    pcrDescriptorTooBig,
    /// present but unreadable
    pcrDescriptorUnreadable,
    /// the project root could not be canonicalized through the kernel
    pcrRootUnresolved,
    /// BOM, NUL, or non-shortest-form UTF-8
    pcrEncoding,
    /// not one well-formed JSON object
    pcrJsonMalformed,
    /// bytes after the top-level object
    pcrTrailingContent,
    /// the same key twice in one object
    pcrDuplicateKey,
    /// a key schema 1 does not define
    pcrUnknownField,
    /// a key whose NAME suggests a credential - refused by name, on purpose
    pcrSecretField,
    /// a required key is absent
    pcrMissingField,
    /// a key carries the wrong JSON type
    pcrFieldType,
    /// `schema` is not PWEB_CLI_SCHEMA
    pcrSchemaUnsupported,
    /// `ui` is not one of the ratified kinds
    pcrUiInvalid,
    /// name, bundleId or the derived program identifier failed its grammar
    pcrIdentifier,
    /// `version` is not strict X.Y.Z
    pcrVersion,
    /// a path field failed syntax, confinement, case or the link refusal
    pcrPath);

  /// one fully established project, or the reason there is none
  TPWebCliProject = record
    /// pcrNone when Root/DescriptorPath and every field below are valid
    Refusal: TPWebCliProjectRefusal;
    /// which field or segment caused the refusal (machine-stable, no prose)
    Detail: RawUtf8;
    /// canonical project root - captured ONCE, never re-derived from the
    /// working directory afterwards
    Root: RawUtf8;
    /// canonical descriptor path
    DescriptorPath: RawUtf8;
    /// True when the root came from the upward walk rather than --project
    Discovered: Boolean;
    /// how many parent levels the walk climbed (0 = the start directory)
    DiscoveryDepth: Integer;
    Schema: Integer;
    Name: RawUtf8;
    Version: RawUtf8;
    BundleId: RawUtf8;
    Ui: TPWebCliUi;
    /// the logical (forward-slash, root-relative) descriptor values
    NativeProgram: RawUtf8;
    FrontendRoot: RawUtf8;
    Output: RawUtf8;
    /// the Pascal program / executable identifier, derived by the ratified
    /// rule from the basename of NativeProgram
    ProgramIdent: RawUtf8;
    /// what each path field resolved to under Root
    NativeProgramPath: TPWebCliResolved;
    FrontendRootPath: TPWebCliResolved;
    OutputPath: TPWebCliResolved;
  end;

/// fixed text for a refusal - the machine authority
function PWebCliProjectRefusalText(
  Refusal: TPWebCliProjectRefusal): RawUtf8;

/// 'react' | 'pas2js'
function PWebCliUiText(Ui: TPWebCliUi): RawUtf8;

/// the ratified project-name grammar
function PWebCliValidName(const Name: RawUtf8): Boolean;

/// the ratified bundle-identifier grammar
function PWebCliValidBundleId(const Id: RawUtf8): Boolean;

/// the ratified program/executable identifier grammar
function PWebCliValidProgramIdent(const Ident: RawUtf8): Boolean;

/// derive the program identifier from a logical native.program path
// - the basename with its final extension removed; '' when the shape is
// not one the rule covers
function PWebCliProgramIdentOf(const NativeProgram: RawUtf8): RawUtf8;

/// parse and validate one descriptor's BYTES against a canonical root
// - separated from discovery so the whole refusal matrix is testable
// without touching a filesystem beyond the root itself
function PWebCliParseDescriptor(const Root, Json: RawUtf8): TPWebCliProject;

/// establish the project
// - ExplicitPath is the --project value ('' when absent). It names either
// the descriptor or its containing directory, is canonicalized exactly, and
// NOTHING else is searched
// - otherwise the walk climbs from StartDir, stops at the FIRST directory
// carrying a pweb.json with that exact spelling, and stops at the
// filesystem root
function PWebCliOpenProject(const ExplicitPath, StartDir: RawUtf8):
  TPWebCliProject;

implementation

{ ---------------------------------------------------------------------------
  refusal / kind text
  --------------------------------------------------------------------------- }

function PWebCliProjectRefusalText(
  Refusal: TPWebCliProjectRefusal): RawUtf8;
begin
  case Refusal of
    pcrNone:                 Result := 'ok';
    pcrDescriptorMissing:    Result := 'descriptor_missing';
    pcrDescriptorNotFound:   Result := 'descriptor_not_found';
    pcrDescriptorName:       Result := 'descriptor_name';
    pcrDescriptorLink:       Result := 'descriptor_link_refused';
    pcrDescriptorTooBig:     Result := 'descriptor_too_big';
    pcrDescriptorUnreadable: Result := 'descriptor_unreadable';
    pcrRootUnresolved:       Result := 'root_unresolved';
    pcrEncoding:             Result := 'descriptor_encoding';
    pcrJsonMalformed:        Result := 'descriptor_malformed';
    pcrTrailingContent:      Result := 'descriptor_trailing_content';
    pcrDuplicateKey:         Result := 'descriptor_duplicate_key';
    pcrUnknownField:         Result := 'descriptor_unknown_field';
    pcrSecretField:          Result := 'descriptor_secret_field';
    pcrMissingField:         Result := 'descriptor_missing_field';
    pcrFieldType:            Result := 'descriptor_field_type';
    pcrSchemaUnsupported:    Result := 'schema_unsupported';
    pcrUiInvalid:            Result := 'ui_invalid';
    pcrIdentifier:           Result := 'identifier_invalid';
    pcrVersion:              Result := 'version_invalid';
    pcrPath:                 Result := 'path_invalid';
  else
    Result := 'project_refused';
  end;
end;

function PWebCliUiText(Ui: TPWebCliUi): RawUtf8;
begin
  if Ui = puiPas2js then
    Result := 'pas2js'
  else
    Result := 'react';
end;

{ ---------------------------------------------------------------------------
  grammars
  --------------------------------------------------------------------------- }

function PWebCliValidName(const Name: RawUtf8): Boolean;
var
  i: PtrInt;
  prevDash: Boolean;
begin
  Result := False;
  if (Length(Name) < 1) or
     (Length(Name) > 64) then
    exit;
  if not (Name[1] in ['a' .. 'z']) then
    exit;
  prevDash := False;
  for i := 2 to Length(Name) do
    if Name[i] = '-' then
    begin
      if prevDash then
        exit; // no empty label
      prevDash := True;
    end
    else if Name[i] in ['a' .. 'z', '0' .. '9'] then
      prevDash := False
    else
      exit;
  Result := not prevDash; // never ends on a separator
end;

function PWebCliValidBundleId(const Id: RawUtf8): Boolean;
var
  i, labels, labelLen: PtrInt;
  c: AnsiChar;
begin
  Result := False;
  if (Length(Id) < 3) or
     (Length(Id) > 128) then
    exit;
  labels := 1;
  labelLen := 0;
  for i := 1 to Length(Id) do
  begin
    c := Id[i];
    if c = '.' then
    begin
      if labelLen = 0 then
        exit; // empty label
      Inc(labels);
      labelLen := 0;
      continue;
    end;
    if labelLen = 0 then
    begin
      if not (c in ['a' .. 'z']) then
        exit; // every label starts with a letter
    end
    else if not (c in ['a' .. 'z', '0' .. '9', '-']) then
      exit;
    Inc(labelLen);
  end;
  if labelLen = 0 then
    exit; // trailing dot
  Result := (labels >= 2) and (labels <= 5);
end;

function PWebCliValidProgramIdent(const Ident: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if (Length(Ident) < 1) or
     (Length(Ident) > 63) then
    exit;
  if not (Ident[1] in ['a' .. 'z']) then
    exit;
  for i := 2 to Length(Ident) do
    if not (Ident[i] in ['a' .. 'z', '0' .. '9']) then
      exit;
  Result := True;
end;

function PWebCliProgramIdentOf(const NativeProgram: RawUtf8): RawUtf8;
var
  i, slash, dot: PtrInt;
begin
  slash := 0;
  dot := 0;
  for i := 1 to Length(NativeProgram) do
    if NativeProgram[i] = '/' then
    begin
      slash := i;
      dot := 0;
    end
    else if NativeProgram[i] = '.' then
      dot := i;
  if dot > slash then
    Result := Copy(NativeProgram, slash + 1, dot - slash - 1)
  else
    Result := Copy(NativeProgram, slash + 1, MaxInt);
end;

{ ---------------------------------------------------------------------------
  the strict JSON reader
  --------------------------------------------------------------------------- }

type
  TPWebJsonKind = (pjkString, pjkInteger, pjkObject, pjkOther);

  TPWebJsonMember = record
    Key: RawUtf8;
    Kind: TPWebJsonKind;
    /// decoded string value, integer digits, or the exact object substring
    Text: RawUtf8;
  end;
  TPWebJsonMembers = array of TPWebJsonMember;

  TPWebJsonError = (pjeNone, pjeMalformed, pjeDuplicate, pjeTrailing);

// JSON whitespace, and only JSON whitespace: a stray form feed or vertical
// tab is malformed, not "probably fine"
function IsJsonSpace(c: AnsiChar): Boolean; inline;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #13);
end;

procedure SkipSpace(const S: RawUtf8; var P: PtrInt);
begin
  while (P <= Length(S)) and
        IsJsonSpace(S[P]) do
    Inc(P);
end;

function HexNibble(c: AnsiChar; out V: Integer): Boolean;
begin
  Result := True;
  case c of
    '0' .. '9': V := Ord(c) - Ord('0');
    'a' .. 'f': V := Ord(c) - Ord('a') + 10;
    'A' .. 'F': V := Ord(c) - Ord('A') + 10;
  else
    begin
      V := 0;
      Result := False;
    end;
  end;
end;

function ReadHex4(const S: RawUtf8; var P: PtrInt; out V: Integer): Boolean;
var
  i, nib: Integer;
begin
  Result := False;
  V := 0;
  if P + 3 > Length(S) then
    exit;
  for i := 0 to 3 do
  begin
    if not HexNibble(S[P + i], nib) then
      exit;
    V := (V shl 4) or nib;
  end;
  Inc(P, 4);
  Result := True;
end;

procedure AppendUtf8(var Dest: RawUtf8; CodePoint: Integer);
begin
  if CodePoint < $80 then
    Dest := Dest + AnsiChar(CodePoint)
  else if CodePoint < $800 then
    Dest := Dest + AnsiChar($C0 or (CodePoint shr 6)) +
      AnsiChar($80 or (CodePoint and $3F))
  else if CodePoint < $10000 then
    Dest := Dest + AnsiChar($E0 or (CodePoint shr 12)) +
      AnsiChar($80 or ((CodePoint shr 6) and $3F)) +
      AnsiChar($80 or (CodePoint and $3F))
  else
    Dest := Dest + AnsiChar($F0 or (CodePoint shr 18)) +
      AnsiChar($80 or ((CodePoint shr 12) and $3F)) +
      AnsiChar($80 or ((CodePoint shr 6) and $3F)) +
      AnsiChar($80 or (CodePoint and $3F));
end;

function ParseString(const S: RawUtf8; var P: PtrInt;
  out Value: RawUtf8): Boolean;
var
  c: AnsiChar;
  cp, low: Integer;
begin
  Result := False;
  Value := '';
  if (P > Length(S)) or
     (S[P] <> '"') then
    exit;
  Inc(P);
  while P <= Length(S) do
  begin
    c := S[P];
    if c = '"' then
    begin
      Inc(P);
      Result := True;
      exit;
    end;
    if c = '\' then
    begin
      Inc(P);
      if P > Length(S) then
        exit;
      case S[P] of
        '"':  Value := Value + '"';
        '\':  Value := Value + '\';
        '/':  Value := Value + '/';
        'b':  Value := Value + #8;
        'f':  Value := Value + #12;
        'n':  Value := Value + #10;
        'r':  Value := Value + #13;
        't':  Value := Value + #9;
        'u':
          begin
            Inc(P);
            if not ReadHex4(S, P, cp) then
              exit;
            if (cp >= $D800) and (cp <= $DBFF) then
            begin
              // a high surrogate must be followed by its low half; a lone
              // half is refused rather than turned into U+FFFD
              if (P + 1 > Length(S)) or
                 (S[P] <> '\') or
                 (S[P + 1] <> 'u') then
                exit;
              Inc(P, 2);
              if not ReadHex4(S, P, low) then
                exit;
              if (low < $DC00) or (low > $DFFF) then
                exit;
              cp := $10000 + ((cp - $D800) shl 10) + (low - $DC00);
            end
            else if (cp >= $DC00) and (cp <= $DFFF) then
              exit; // a lone low surrogate
            if cp = 0 then
              exit; // an escaped NUL is still a NUL
            AppendUtf8(Value, cp);
            continue; // P already advanced past the escape
          end;
      else
        exit; // no other escape exists in JSON
      end;
      Inc(P);
      continue;
    end;
    if c < ' ' then
      exit; // raw control bytes are malformed inside a JSON string
    Value := Value + c;
    Inc(P);
  end;
end;

function ParseInteger(const S: RawUtf8; var P: PtrInt;
  out Digits: RawUtf8): Boolean;
var
  start: PtrInt;
begin
  Result := False;
  Digits := '';
  start := P;
  if (P <= Length(S)) and
     (S[P] = '-') then
    Inc(P);
  if P > Length(S) then
    exit;
  if S[P] = '0' then
    Inc(P)
  else if S[P] in ['1' .. '9'] then
    repeat
      Inc(P);
    until (P > Length(S)) or
          not (S[P] in ['0' .. '9'])
  else
    exit;
  // schema 1 has exactly one numeric field and it is an integer, so a
  // fraction or an exponent is refused here rather than rounded later
  if (P <= Length(S)) and
     ((S[P] = '.') or (S[P] = 'e') or (S[P] = 'E')) then
    exit;
  Digits := Copy(S, start, P - start);
  Result := True;
end;

function SkipValue(const S: RawUtf8; var P: PtrInt): Boolean; forward;

function SkipObjectOrArray(const S: RawUtf8; var P: PtrInt;
  Opening, Closing: AnsiChar): Boolean;
var
  depth: Integer;
  dummy: RawUtf8;
begin
  Result := False;
  if (P > Length(S)) or
     (S[P] <> Opening) then
    exit;
  depth := 0;
  while P <= Length(S) do
  begin
    if S[P] = '"' then
    begin
      if not ParseString(S, P, dummy) then
        exit;
      continue;
    end;
    if (S[P] = Opening) then
      Inc(depth)
    else if (S[P] = Closing) then
    begin
      Dec(depth);
      if depth = 0 then
      begin
        Inc(P);
        Result := True;
        exit;
      end;
    end;
    Inc(P);
  end;
end;

function SkipValue(const S: RawUtf8; var P: PtrInt): Boolean;
var
  dummy: RawUtf8;
begin
  Result := False;
  SkipSpace(S, P);
  if P > Length(S) then
    exit;
  case S[P] of
    '"': Result := ParseString(S, P, dummy);
    '{': Result := SkipObjectOrArray(S, P, '{', '}');
    '[': Result := SkipObjectOrArray(S, P, '[', ']');
    '-', '0' .. '9': Result := ParseInteger(S, P, dummy);
    't':
      if Copy(S, P, 4) = 'true' then
      begin
        Inc(P, 4);
        Result := True;
      end;
    'f':
      if Copy(S, P, 5) = 'false' then
      begin
        Inc(P, 5);
        Result := True;
      end;
    'n':
      if Copy(S, P, 4) = 'null' then
      begin
        Inc(P, 4);
        Result := True;
      end;
  end;
end;

// parse ONE object into its members, refusing a repeated key
function ParseObject(const S: RawUtf8; var P: PtrInt;
  out Members: TPWebJsonMembers): TPWebJsonError;
var
  key, text: RawUtf8;
  start: PtrInt;
  i, n: PtrInt;
begin
  Result := pjeMalformed;
  Members := nil;
  n := 0;
  SkipSpace(S, P);
  if (P > Length(S)) or
     (S[P] <> '{') then
    exit;
  Inc(P);
  SkipSpace(S, P);
  if (P <= Length(S)) and
     (S[P] = '}') then
  begin
    Inc(P);
    exit(pjeNone);
  end;
  repeat
    SkipSpace(S, P);
    if not ParseString(S, P, key) then
      exit;
    for i := 0 to n - 1 do
      if Members[i].Key = key then
        exit(pjeDuplicate);
    SkipSpace(S, P);
    if (P > Length(S)) or
       (S[P] <> ':') then
      exit;
    Inc(P);
    SkipSpace(S, P);
    if P > Length(S) then
      exit;
    SetLength(Members, n + 1);
    Members[n].Key := key;
    case S[P] of
      '"':
        begin
          if not ParseString(S, P, text) then
            exit;
          Members[n].Kind := pjkString;
          Members[n].Text := text;
        end;
      '{':
        begin
          start := P;
          if not SkipObjectOrArray(S, P, '{', '}') then
            exit;
          Members[n].Kind := pjkObject;
          Members[n].Text := Copy(S, start, P - start);
        end;
      '-', '0' .. '9':
        begin
          if not ParseInteger(S, P, text) then
            exit;
          Members[n].Kind := pjkInteger;
          Members[n].Text := text;
        end;
    else
      begin
        // arrays, true, false, null: parsed so the diagnostic can say
        // "wrong type" instead of "malformed", which is a different bug
        if not SkipValue(S, P) then
          exit;
        Members[n].Kind := pjkOther;
        Members[n].Text := '';
      end;
    end;
    Inc(n);
    SkipSpace(S, P);
    if P > Length(S) then
      exit;
    if S[P] = ',' then
    begin
      Inc(P);
      continue;
    end;
    if S[P] = '}' then
    begin
      Inc(P);
      exit(pjeNone);
    end;
    exit;
  until False;
end;

{ ---------------------------------------------------------------------------
  schema 1
  --------------------------------------------------------------------------- }

const
  { key names a schema-1 descriptor must never carry. They are all already
    unknown fields, so this list changes NO decision today - it changes the
    DIAGNOSTIC, and it keeps changing it when a schema 2 adds keys. A refusal
    that says "secret field" is the one a developer acts on correctly. }
  PWEB_CLI_SECRET_KEYS: array[0 .. 15] of RawUtf8 = (
    'password', 'passwd', 'secret', 'secrets', 'token', 'apikey',
    'api_key', 'apisecret', 'credentials', 'signing', 'signingkey',
    'certificate', 'certpath', 'privatekey', 'keystore', 'env');

function LowerAscii(const S: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := S;
  for i := 1 to Length(Result) do
    if Result[i] in ['A' .. 'Z'] then
      Result[i] := AnsiChar(Ord(Result[i]) + 32);
end;

function IsSecretKey(const Key: RawUtf8): Boolean;
var
  i: PtrInt;
  low: RawUtf8;
begin
  Result := True;
  low := LowerAscii(Key);
  for i := 0 to High(PWEB_CLI_SECRET_KEYS) do
    if low = PWEB_CLI_SECRET_KEYS[i] then
      exit;
  Result := False;
end;

function Fail(var Project: TPWebCliProject;
  Refusal: TPWebCliProjectRefusal; const Detail: RawUtf8): Boolean;
begin
  Project.Refusal := Refusal;
  Project.Detail := Detail;
  Result := False;
end;

// one path field: shared syntax, then the confinement walk
function TakePath(var Project: TPWebCliProject; const Field, Logical: RawUtf8;
  AllowMissing: Boolean; out Resolved: TPWebCliResolved): Boolean;
begin
  Resolved := PWebCliResolveUnder(Project.Root, Logical, AllowMissing);
  if Resolved.Refusal = pprNone then
    exit(True);
  Result := Fail(Project, pcrPath,
    Field + ':' + PWebCliPathRefusalText(Resolved.Refusal));
end;

function FindMember(const Members: TPWebJsonMembers; const Key: RawUtf8;
  out Index: PtrInt): Boolean;
var
  i: PtrInt;
begin
  for i := 0 to High(Members) do
    if Members[i].Key = Key then
    begin
      Index := i;
      exit(True);
    end;
  Index := -1;
  Result := False;
end;

function RequireString(var Project: TPWebCliProject;
  const Members: TPWebJsonMembers; const Key: RawUtf8;
  out Value: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Value := '';
  if not FindMember(Members, Key, i) then
    exit(Fail(Project, pcrMissingField, Key));
  if Members[i].Kind <> pjkString then
    exit(Fail(Project, pcrFieldType, Key));
  Value := Members[i].Text;
  Result := True;
end;

function CheckKnownKeys(var Project: TPWebCliProject;
  const Members: TPWebJsonMembers; const Allowed: array of RawUtf8;
  const Prefix: RawUtf8): Boolean;
var
  i, j: PtrInt;
  known: Boolean;
begin
  for i := 0 to High(Members) do
  begin
    known := False;
    for j := 0 to High(Allowed) do
      if Members[i].Key = Allowed[j] then
      begin
        known := True;
        break;
      end;
    if known then
      continue;
    if IsSecretKey(Members[i].Key) then
      exit(Fail(Project, pcrSecretField, Prefix + Members[i].Key));
    exit(Fail(Project, pcrUnknownField, Prefix + Members[i].Key));
  end;
  Result := True;
end;

function PWebCliParseDescriptor(const Root, Json: RawUtf8): TPWebCliProject;
var
  members, nested: TPWebJsonMembers;
  err: TPWebJsonError;
  p, idx: PtrInt;
  value: RawUtf8;
begin
  Result := Default(TPWebCliProject);
  Result.Root := Root;
  Result.Schema := 0;
  if Root = '' then
  begin
    Fail(Result, pcrRootUnresolved, '');
    exit;
  end;
  // encoding first, over the WHOLE document: a NUL, a BOM or an overlong
  // sequence must be refused before any structure is believed
  if (Length(Json) >= 3) and
     (Json[1] = #$EF) and (Json[2] = #$BB) and (Json[3] = #$BF) then
  begin
    Fail(Result, pcrEncoding, 'bom');
    exit;
  end;
  if Pos(#0, Json) > 0 then
  begin
    Fail(Result, pcrEncoding, 'nul');
    exit;
  end;
  if not PWebStrictUtf8(Json) then
  begin
    Fail(Result, pcrEncoding, 'utf8');
    exit;
  end;
  p := 1;
  err := ParseObject(Json, p, members);
  if err = pjeDuplicate then
  begin
    Fail(Result, pcrDuplicateKey, '');
    exit;
  end;
  if err <> pjeNone then
  begin
    Fail(Result, pcrJsonMalformed, '');
    exit;
  end;
  SkipSpace(Json, p);
  if p <= Length(Json) then
  begin
    Fail(Result, pcrTrailingContent, '');
    exit;
  end;
  if not CheckKnownKeys(Result, members,
       ['schema', 'name', 'version', 'bundleId', 'ui', 'native',
        'frontend', 'output'], '') then
    exit;
  // schema before anything else: a future schema must not be interpreted
  // through this build's field rules
  if not FindMember(members, 'schema', idx) then
  begin
    Fail(Result, pcrMissingField, 'schema');
    exit;
  end;
  if members[idx].Kind <> pjkInteger then
  begin
    Fail(Result, pcrFieldType, 'schema');
    exit;
  end;
  Result.Schema := StrToIntDef(string(members[idx].Text), -1);
  if Result.Schema <> PWEB_CLI_SCHEMA then
  begin
    Fail(Result, pcrSchemaUnsupported, members[idx].Text);
    exit;
  end;
  if not RequireString(Result, members, 'name', Result.Name) then
    exit;
  if not PWebCliValidName(Result.Name) then
  begin
    Fail(Result, pcrIdentifier, 'name');
    exit;
  end;
  if not RequireString(Result, members, 'version', Result.Version) then
    exit;
  if not PWebSemVerValid(Result.Version) then
  begin
    Fail(Result, pcrVersion, 'version');
    exit;
  end;
  if not RequireString(Result, members, 'bundleId', Result.BundleId) then
    exit;
  if not PWebCliValidBundleId(Result.BundleId) then
  begin
    Fail(Result, pcrIdentifier, 'bundleId');
    exit;
  end;
  if not RequireString(Result, members, 'ui', value) then
    exit;
  if value = 'react' then
    Result.Ui := puiReact
  else if value = 'pas2js' then
    Result.Ui := puiPas2js
  else
  begin
    Fail(Result, pcrUiInvalid, value);
    exit;
  end;
  // native { program }
  if not FindMember(members, 'native', idx) then
  begin
    Fail(Result, pcrMissingField, 'native');
    exit;
  end;
  if members[idx].Kind <> pjkObject then
  begin
    Fail(Result, pcrFieldType, 'native');
    exit;
  end;
  p := 1;
  value := members[idx].Text;
  err := ParseObject(value, p, nested);
  if err = pjeDuplicate then
  begin
    Fail(Result, pcrDuplicateKey, 'native');
    exit;
  end;
  if err <> pjeNone then
  begin
    Fail(Result, pcrJsonMalformed, 'native');
    exit;
  end;
  if not CheckKnownKeys(Result, nested, ['program'], 'native.') then
    exit;
  if not RequireString(Result, nested, 'program', Result.NativeProgram) then
  begin
    Result.Detail := 'native.' + Result.Detail;
    exit;
  end;
  // frontend { root }
  if not FindMember(members, 'frontend', idx) then
  begin
    Fail(Result, pcrMissingField, 'frontend');
    exit;
  end;
  if members[idx].Kind <> pjkObject then
  begin
    Fail(Result, pcrFieldType, 'frontend');
    exit;
  end;
  p := 1;
  value := members[idx].Text;
  err := ParseObject(value, p, nested);
  if err = pjeDuplicate then
  begin
    Fail(Result, pcrDuplicateKey, 'frontend');
    exit;
  end;
  if err <> pjeNone then
  begin
    Fail(Result, pcrJsonMalformed, 'frontend');
    exit;
  end;
  if not CheckKnownKeys(Result, nested, ['root'], 'frontend.') then
    exit;
  if not RequireString(Result, nested, 'root', Result.FrontendRoot) then
  begin
    Result.Detail := 'frontend.' + Result.Detail;
    exit;
  end;
  if not RequireString(Result, members, 'output', Result.Output) then
    exit;
  // the derived identifier, by the ratified rule and nothing else
  Result.ProgramIdent := PWebCliProgramIdentOf(Result.NativeProgram);
  if not PWebCliValidProgramIdent(Result.ProgramIdent) then
  begin
    Fail(Result, pcrIdentifier, 'native.program');
    exit;
  end;
  // the three paths, confined under the canonical root. A missing tail is
  // allowed everywhere: whether a path must EXIST is an environment
  // question the doctor answers, while syntax, case and the link refusal
  // are descriptor questions and are answered here.
  if not TakePath(Result, 'native.program', Result.NativeProgram, True,
       Result.NativeProgramPath) then
    exit;
  if not TakePath(Result, 'frontend.root', Result.FrontendRoot, True,
       Result.FrontendRootPath) then
    exit;
  if not TakePath(Result, 'output', Result.Output, True,
       Result.OutputPath) then
    exit;
  Result.Refusal := pcrNone;
  Result.Detail := '';
end;

{ ---------------------------------------------------------------------------
  discovery
  --------------------------------------------------------------------------- }

// read + parse the descriptor that must live directly inside Root
function LoadFrom(const Root: RawUtf8): TPWebCliProject;
var
  content: RawByteString;
  tooBig: Boolean;
  kind: TPWebCliNodeKind;
begin
  Result := Default(TPWebCliProject);
  Result.Root := Root;
  // EXACT spelling, read from the directory itself: on a case-insensitive
  // volume 'PWEB.JSON' must not be this project's descriptor
  kind := PWebCliEntry(Root, PWEB_CLI_DESCRIPTOR);
  if kind = pcnLink then
  begin
    Fail(Result, pcrDescriptorLink, '');
    exit;
  end;
  if kind <> pcnFile then
  begin
    Fail(Result, pcrDescriptorMissing, '');
    exit;
  end;
  Result.DescriptorPath := PWebCliJoin(Root, PWEB_CLI_DESCRIPTOR);
  if not PWebCliReadSmallFile(Result.DescriptorPath,
       PWEB_CLI_DESCRIPTOR_MAX_BYTES, content, tooBig) then
  begin
    if tooBig then
      Fail(Result, pcrDescriptorTooBig, '')
    else
      Fail(Result, pcrDescriptorUnreadable, '');
    exit;
  end;
  Result := PWebCliParseDescriptor(Root, RawUtf8(content));
  Result.DescriptorPath := PWebCliJoin(Root, PWEB_CLI_DESCRIPTOR);
end;

function PWebCliOpenProject(const ExplicitPath, StartDir: RawUtf8):
  TPWebCliProject;
var
  wanted, root, parent, name, dir: RawUtf8;
  depth: Integer;
begin
  Result := Default(TPWebCliProject);
  if ExplicitPath <> '' then
  begin
    // --project is EXACT: it names the descriptor or its directory, it is
    // canonicalized once, and nothing else is looked at. No upward walk,
    // no sibling guess, no fallback.
    wanted := PWebCliAbsolute(StartDir, ExplicitPath);
    if PWebCliCanonicalDir(wanted, root) then
    begin
      Result := LoadFrom(root);
      exit;
    end;
    if not PWebCliSplitLast(wanted, parent, name) then
    begin
      Fail(Result, pcrDescriptorMissing, '');
      exit;
    end;
    if name <> PWEB_CLI_DESCRIPTOR then
    begin
      // naming any other file is an error, never a hint to look nearby
      Fail(Result, pcrDescriptorName, name);
      exit;
    end;
    if not PWebCliCanonicalDir(parent, root) then
    begin
      Fail(Result, pcrDescriptorMissing, '');
      exit;
    end;
    Result := LoadFrom(root);
    exit;
  end;
  // the upward walk: the FIRST descriptor wins, the filesystem root ends
  // the search, and a bound keeps a pathological mount from looping
  if not PWebCliCanonicalDir(StartDir, dir) then
  begin
    Fail(Result, pcrRootUnresolved, '');
    exit;
  end;
  depth := 0;
  repeat
    if PWebCliEntry(dir, PWEB_CLI_DESCRIPTOR) <> pcnMissing then
    begin
      Result := LoadFrom(dir);
      Result.Discovered := True;
      Result.DiscoveryDepth := depth;
      exit;
    end;
    Inc(depth);
    if depth > PWEB_CLI_DISCOVERY_MAX_DEPTH then
      break;
    if not PWebCliParentDir(dir, parent) then
      break;
    dir := parent;
  until False;
  Fail(Result, pcrDescriptorNotFound, '');
end;

end.
