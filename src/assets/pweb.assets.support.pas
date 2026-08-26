{
  pweb.assets.support - shared CAP-4 asset helpers.

  One validation truth for every consumer: the canonical logical-path
  validator and the deterministic MIME resolver used by both stores
  and by the platform URI handler. Also hosts the pweb://app URI ->
  logical-path translation so it is testable headless, away from any
  platform resource handler.

  Canonical sources:
    - core-interfaces.md  : "Canonical asset paths - DECIDED" rules,
                            restated verbatim on IAssetStore.
    - security-model.md   : pweb://app is the only privileged origin.

  Layering: mormot.core.base only (RawUtf8), mirroring
  pweb.assets.intf. No filesystem, archive, WebView or platform type
  may appear here.

  Percent-encoding policy - one decode, ever: the URI layer decodes
  exactly once (PWebParseAppUri). A '%' byte reaching the store-level
  validator therefore means double encoding (or an unsupported
  literal-'%' asset name) and is rejected outright; nothing here ever
  decodes recursively.
}
unit pweb.assets.support;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base;

const
  /// absolute ceiling for a canonical logical path, in bytes
  PWEB_ASSET_PATH_MAX_BYTES = 2048;
  /// absolute ceiling for one path segment, in bytes
  PWEB_ASSET_SEGMENT_MAX_BYTES = 255;
  /// the document served for the pweb://app/ root, mapped in the URI
  // layer only - IAssetStore.TryRead('') stays fail-closed
  PWEB_ASSET_DEFAULT_DOCUMENT: RawUtf8 = 'index.html';
  /// deterministic fallback MIME type for unknown extensions
  PWEB_ASSET_FALLBACK_MIME: RawUtf8 = 'application/octet-stream';

/// validate a canonical logical asset path (fail-closed)
// - enforces the ratified rules from core-interfaces.md: forward
// slashes only; no empty, '.' or '..' segments; no NUL, backslash,
// drive/UNC/ADS colon; no '%' (single-decode policy); no control or
// Windows-reserved characters; strict shortest-form UTF-8; no device
// names (with or without extension); no trailing '.' or ' ' segment;
// bounded total and per-segment length
// - case is NOT folded here: exact-case matching is a store lookup
// property, not a syntax property
function PWebAssetPathValid(const Path: RawUtf8): Boolean;

/// strict shortest-form UTF-8 validation over the whole byte string
// - the ONE UTF-8 truth in PWeb: PWebAssetPathValid uses it, and so do
// the CAP-9B1 plugin-manifest scanner and module-source preparer, so a
// byte sequence a path would refuse can never enter through a module
// - rejects overlong (non-shortest-form) encodings, lone continuation
// and invalid lead bytes, truncated sequences, UTF-16 surrogate halves,
// anything above U+10FFFF, and the C1 control block U+0080..U+009F
// - NUL and the C0 controls are legal UTF-8 and pass here: callers that
// must refuse them (paths, manifests, module source) do so explicitly
function PWebStrictUtf8(const s: RawUtf8): Boolean;

/// deterministic MIME resolution from the logical path's extension
// - fixed table, ASCII case-insensitive on the extension, never the
// Windows registry; unknown/absent extension yields
// PWEB_ASSET_FALLBACK_MIME
function PWebAssetMimeType(const Path: RawUtf8): RawUtf8;

/// percent-decode a raw URI path component exactly once, strictly
// - '%' must be followed by exactly two hex digits; '%zz' or a
// truncated '%2' fails; '+' is NOT translated (path, not form data)
// - returns False on any malformed escape, leaving Decoded empty
function PWebPercentDecodeOnce(const Raw: RawUtf8;
  out Decoded: RawUtf8): Boolean;

/// translate a full pweb://app URI into a validated logical path
// - scheme and authority match case-insensitively (RFC 3986); the
// authority must be exactly 'app' - userinfo, port or any other host
// is refused, never trusted
// - query ('?') and fragment ('#') are cut before decoding; the path
// is percent-decoded exactly once, then validated with
// PWebAssetPathValid
// - 'pweb://app' and 'pweb://app/' map to PWEB_ASSET_DEFAULT_DOCUMENT
// here, in the URI layer only
// - returns False (fail-closed) for anything else, including wrong
// scheme/authority, malformed escapes and non-canonical paths
function PWebParseAppUri(const Uri: RawUtf8;
  out LogicalPath: RawUtf8): Boolean;

implementation

function AsciiLower(c: AnsiChar): AnsiChar; inline;
begin
  if c in ['A'..'Z'] then
    Result := AnsiChar(Ord(c) + 32)
  else
    Result := c;
end;

function SameAsciiText(const a, b: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if Length(a) <> Length(b) then
    exit;
  for i := 1 to Length(a) do
    if AsciiLower(a[i]) <> AsciiLower(b[i]) then
      exit;
  Result := True;
end;

// strict shortest-form UTF-8 over Bytes[1..Len]; rejects overlong
// encodings, UTF-16 surrogates and anything above U+10FFFF
// - published as PWebStrictUtf8 (interface) since CAP-9B1: the plugin
// manifest scanner and module-source preparer share this one validator
// rather than growing a second, subtly different, copy
function PWebStrictUtf8(const s: RawUtf8): Boolean;
var
  i, len, extra, j: PtrInt;
  b: Byte;
  cp, minimum: Cardinal;
begin
  Result := False;
  len := Length(s);
  i := 1;
  while i <= len do
  begin
    b := Ord(s[i]);
    if b < $80 then
    begin
      Inc(i);
      continue;
    end;
    if (b and $E0) = $C0 then
    begin
      extra := 1;
      cp := b and $1F;
      minimum := $80;
    end
    else if (b and $F0) = $E0 then
    begin
      extra := 2;
      cp := b and $0F;
      minimum := $800;
    end
    else if (b and $F8) = $F0 then
    begin
      extra := 3;
      cp := b and $07;
      minimum := $10000;
    end
    else
      exit; // lone continuation or invalid lead byte
    if i + extra > len then
      exit; // truncated sequence
    for j := 1 to extra do
    begin
      b := Ord(s[i + j]);
      if (b and $C0) <> $80 then
        exit; // not a continuation byte
      cp := (cp shl 6) or (b and $3F);
    end;
    if (cp < minimum) or // overlong (non-shortest form)
       (cp > $10FFFF) or
       ((cp >= $D800) and (cp <= $DFFF)) or // surrogate half
       ((cp >= $80) and (cp <= $9F)) then // C1 control characters
      exit;
    Inc(i, extra + 1);
  end;
  Result := True;
end;

// Windows device names resolve case-insensitively and with any
// extension appended, so 'NUL', 'nul.txt' and 'Con.tar.gz' all hit
// the device namespace; compare the part before the first '.', with
// trailing spaces stripped ('CON .txt' aliases CON). The reserved
// set includes the documented superscript-digit variants of COM/LPT
// (U+00B9/U+00B2/U+00B3) and the CONIN$/CONOUT$ console devices.
function IsDeviceSegment(const Segment: RawUtf8): Boolean;
var
  base: RawUtf8;
  dot: PtrInt;
begin
  dot := Pos('.', Segment);
  if dot = 0 then
    base := Segment
  else
    base := Copy(Segment, 1, dot - 1);
  while (base <> '') and
        (base[Length(base)] = ' ') do
    SetLength(base, Length(base) - 1);
  case Length(base) of
    3:
      Result := SameAsciiText(base, 'CON') or
                SameAsciiText(base, 'PRN') or
                SameAsciiText(base, 'AUX') or
                SameAsciiText(base, 'NUL');
    4:
      Result := ((SameAsciiText(Copy(base, 1, 3), 'COM') or
                  SameAsciiText(Copy(base, 1, 3), 'LPT')) and
                 (base[4] in ['1'..'9']));
    5:
      // COM/LPT + UTF-8 encoded superscript one/two/three
      Result := ((SameAsciiText(Copy(base, 1, 3), 'COM') or
                  SameAsciiText(Copy(base, 1, 3), 'LPT')) and
                 (base[4] = #$C2) and
                 (base[5] in [#$B9, #$B2, #$B3]));
    6:
      Result := SameAsciiText(base, 'CONIN$');
    7:
      Result := SameAsciiText(base, 'CONOUT$');
  else
    Result := False;
  end;
end;

function ValidSegment(const Segment: RawUtf8): Boolean;
begin
  Result := False;
  if (Segment = '') or // empty segment: leading/trailing or '//'
     (Segment = '.') or
     (Segment = '..') or
     (Length(Segment) > PWEB_ASSET_SEGMENT_MAX_BYTES) then
    exit;
  // Windows silently strips trailing dots/spaces, so 'app.js.' would
  // alias 'app.js' in a folder store - reject the form itself
  if (Segment[Length(Segment)] = '.') or
     (Segment[Length(Segment)] = ' ') then
    exit;
  if IsDeviceSegment(Segment) then
    exit;
  Result := True;
end;

function PWebAssetPathValid(const Path: RawUtf8): Boolean;
var
  i, start, len: PtrInt;
  c: AnsiChar;
begin
  Result := False;
  len := Length(Path);
  if (len = 0) or
     (len > PWEB_ASSET_PATH_MAX_BYTES) then
    exit;
  for i := 1 to len do
  begin
    c := Path[i];
    // NUL and every other control byte including DEL; backslash;
    // drive/UNC/ADS colon; '%' per the single-decode policy;
    // Windows-reserved punctuation that can never name a portable
    // asset (C1 controls are rejected by PWebStrictUtf8 below)
    if (c < #$20) or
       (c = #$7F) or
       (c in ['\', ':', '%', '<', '>', '"', '|', '?', '*']) then
      exit;
  end;
  if not PWebStrictUtf8(Path) then
    exit;
  start := 1;
  for i := 1 to len + 1 do
    if (i > len) or
       (Path[i] = '/') then
    begin
      if not ValidSegment(Copy(Path, start, i - start)) then
        exit;
      start := i + 1;
    end;
  Result := True;
end;

function PWebAssetMimeType(const Path: RawUtf8): RawUtf8;
var
  i: PtrInt;
  ext: RawUtf8;
begin
  ext := '';
  for i := Length(Path) downto 1 do
    case Path[i] of
      '.':
        begin
          ext := Copy(Path, i + 1, MaxInt);
          break;
        end;
      '/':
        break;
    end;
  for i := 1 to Length(ext) do
    ext[i] := AsciiLower(ext[i]);
  case ext of
    'html', 'htm':
      Result := 'text/html; charset=utf-8';
    'js', 'mjs':
      Result := 'text/javascript; charset=utf-8';
    'css':
      Result := 'text/css; charset=utf-8';
    'json':
      Result := 'application/json; charset=utf-8';
    'txt':
      Result := 'text/plain; charset=utf-8';
    'svg':
      Result := 'image/svg+xml';
    'png':
      Result := 'image/png';
    'jpg', 'jpeg':
      Result := 'image/jpeg';
    'gif':
      Result := 'image/gif';
    'webp':
      Result := 'image/webp';
    'ico':
      Result := 'image/x-icon';
    'woff':
      Result := 'font/woff';
    'woff2':
      Result := 'font/woff2';
    'wasm':
      Result := 'application/wasm';
  else
    Result := PWEB_ASSET_FALLBACK_MIME;
  end;
end;

function HexNibble(c: AnsiChar; out v: Byte): Boolean; inline;
begin
  Result := True;
  case c of
    '0'..'9':
      v := Ord(c) - Ord('0');
    'A'..'F':
      v := Ord(c) - Ord('A') + 10;
    'a'..'f':
      v := Ord(c) - Ord('a') + 10;
  else
    begin
      v := 0;
      Result := False;
    end;
  end;
end;

function PWebPercentDecodeOnce(const Raw: RawUtf8;
  out Decoded: RawUtf8): Boolean;
var
  i, len, outlen: PtrInt;
  hi, lo: Byte;
begin
  Result := False;
  Decoded := '';
  len := Length(Raw);
  SetLength(Decoded, len);
  outlen := 0;
  i := 1;
  while i <= len do
  begin
    if Raw[i] = '%' then
    begin
      if (i + 2 > len) or
         not HexNibble(Raw[i + 1], hi) or
         not HexNibble(Raw[i + 2], lo) then
      begin
        Decoded := '';
        exit; // '%zz', truncated '%2', ... - never passed through
      end;
      Inc(outlen);
      Decoded[outlen] := AnsiChar((hi shl 4) or lo);
      Inc(i, 3);
    end
    else
    begin
      Inc(outlen);
      Decoded[outlen] := Raw[i];
      Inc(i);
    end;
  end;
  SetLength(Decoded, outlen);
  Result := True;
end;

function PWebParseAppUri(const Uri: RawUtf8;
  out LogicalPath: RawUtf8): Boolean;
var
  len, i, pathStart: PtrInt;
  authority, rawPath, decoded: RawUtf8;
begin
  Result := False;
  LogicalPath := '';
  len := Length(Uri);
  // scheme://  - case-insensitive per RFC 3986
  if (len < 7) or
     (AsciiLower(Uri[1]) <> 'p') or
     (AsciiLower(Uri[2]) <> 'w') or
     (AsciiLower(Uri[3]) <> 'e') or
     (AsciiLower(Uri[4]) <> 'b') or
     (Uri[5] <> ':') or
     (Uri[6] <> '/') or
     (Uri[7] <> '/') then
    exit;
  i := 8;
  while (i <= len) and
        not (Uri[i] in ['/', '?', '#']) do
    Inc(i);
  authority := Copy(Uri, 8, i - 8);
  // exactly 'app': any userinfo, port or other host is untrusted
  if not SameAsciiText(authority, 'app') then
    exit;
  pathStart := i;
  rawPath := '';
  if (pathStart <= len) and
     (Uri[pathStart] = '/') then
  begin
    i := pathStart + 1;
    while (i <= len) and
          not (Uri[i] in ['?', '#']) do
      Inc(i);
    rawPath := Copy(Uri, pathStart + 1, i - pathStart - 1);
  end
  else if pathStart <= len then
    // authority directly followed by '?' or '#': treat as root
    rawPath := '';
  // the one root mapping, in the URI layer only
  if rawPath = '' then
  begin
    LogicalPath := PWEB_ASSET_DEFAULT_DOCUMENT;
    Result := True;
    exit;
  end;
  // exactly one percent-decode, then full canonical validation - the
  // ratified order (core-interfaces.md "single percent-decode, then
  // validation"). A decoded %2F therefore acts as a segment separator:
  // 'assets%2Fapp.js' aliases 'assets/app.js', and encoded traversal
  // ('%2e%2e%2Fx') still dies in the post-decode validator.
  if not PWebPercentDecodeOnce(rawPath, decoded) then
    exit;
  if not PWebAssetPathValid(decoded) then
    exit;
  LogicalPath := decoded;
  Result := True;
end;

end.
