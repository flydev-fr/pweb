{
  pweb.platform.webview2.runtime - WebView2 Evergreen runtime detection
  and provisioning foundation for the Windows engine (CAP-6b0).

  CAP-4W taught the loader to hard-reject any runtime whose BUILD
  version component is below 1587, but webview_create collapses every
  bad state into one nil: absent runtime, too-old runtime and missing
  desktop session are indistinguishable there. This Windows-private
  unit restores the distinction ahead of webview_create:

    PWebWv2Detect
      -> available | unavailable | detection_error
         + raw version text, parsed 4-part version, source channel

  Detection is the Microsoft-documented registry check ("Approach 1",
  learn.microsoft.com distribution guide): value 'pv' under
  EdgeUpdate\Clients\GUID (stable-channel Evergreen GUID F3017226-
  FE2A-4295-8BDF-00C3A9A7E4C5), probed in
  the HKLM 32-bit registry view (per-machine) first, then HKCU
  (per-user); an absent or empty value, or the literal '0.0.0.0',
  means "not installed". PWeb never ships WebView2Loader.dll (the
  release layout is frozen at exe + app.pwb + webview.dll), and the
  pinned CAP-4W loader's own fallback is a registry walk of
  EdgeUpdate\ClientState\...\EBWebView - so the documented registry
  check IS loader parity; the ClientState walk is probed here as well
  and any divergence is reported in the Diagnostic text, never acted
  on. PWebWv2Detect never raises across its boundary: unexpected
  failures become a structured detection_error.

  Ratified probe precedence (loader parity outranks pessimism): HKLM
  is probed first and a hit there wins; a runtime found in EITHER hive
  is reported available even when the other hive's read errored,
  because the pinned loader's own walk would equally have found and
  used that runtime - the failed read is preserved in the Diagnostic
  text, named by its concrete Win32 error code. Only when NO hive
  reports a runtime does a read error escalate the verdict to
  detection_error (never a false "unavailable" over an unknown
  machine state), and every detection_error carries a non-empty
  Diagnostic naming the Win32 error code(s) behind it.

  The raw registry read sits behind an internal test seam: a plain
  procedural variable defaulting to the real reader, public-mutable
  by design (the ratified seam style - no interface type, no frozen
  surface). Production code never assigns it; only the platform test
  suite swaps a fake hive in - and must restore the real reader - to
  pin the exact key paths, value names, 32-bit-view flag and
  precedence rules.

  Policy and provisioning are PURE functions over the detection-result
  record, so tests inject every outcome without touching the registry:

    - usability = strict 4-part parse succeeded AND the BUILD (third)
      component is numerically >= PWEB_WV2_MIN_BUILD (1587), the one
      CAP-4W loader minimum - no second threshold exists. Numeric
      comparison of the build component only, mirroring the pinned
      loader's find_installed_client; never lexicographic. Malformed
      version text fails closed: never usable.
    - provisioning: Detect -> AlreadyUsable | ProvisionRequired |
      DetectionFailure. The frozen invariant: INSTALLER SUCCESS IS
      NEVER RUNTIME SUCCESS - after any future installer run a
      mandatory re-probe must report usable, else the installation
      failed; the re-probe verdict outranks the installer exit code.

  No installer runs in this shard (CAP-6b1..6b4 build on this seam),
  and nothing here touches any frozen public interface.
}
unit pweb.platform.webview2.runtime;

{$mode ObjFPC}{$H+}

interface

uses
  windows,
  sysutils,
  mormot.core.base,
  mormot.core.unicode;

const
  /// the single ratified runtime minimum: the BUILD (third) component
  // of the WebView2 runtime version must be numerically >= this value
  // - source of truth is tools/cap4w/webview2-custom-scheme.patch
  // (loader api_version 1150 -> 1587); CI cross-checks both numbers
  PWEB_WV2_MIN_BUILD = 1587;

  /// KEY_WOW64_32KEY: the pinned loader opens every EdgeUpdate key
  // through the 32-bit registry view, so the detector passes this
  // flag on every probe (the test seam's fake hive asserts it)
  PWEB_KEY_WOW64_32KEY = $0200;

type
  /// strict 4-part WebView2 runtime version (major.minor.build.patch)
  TPWebWv2Version = record
    Major: Cardinal;
    Minor: Cardinal;
    Build: Cardinal;
    Patch: Cardinal;
  end;

  /// structured detection verdict
  // - ordinal 0 is the error state so a zeroed record can never read
  // as an available runtime (fail closed)
  TPWebWv2DetectionStatus = (
    wv2dsDetectionError,
    wv2dsUnavailable,
    wv2dsAvailable);

  /// which registry hive reported the runtime
  TPWebWv2Channel = (
    wv2chNone,
    wv2chHKLM,
    wv2chHKCU);

  /// everything one registry probe learned, as an injectable record
  // - policy/provisioning functions take this record, never the OS
  TPWebWv2DetectionResult = record
    /// available | unavailable | detection_error
    Status: TPWebWv2DetectionStatus;
    /// exact registry version text when Status = wv2dsAvailable
    RawVersion: RawUtf8;
    /// strict 4-part parse of RawVersion - all zero unless ParsedOk
    Parsed: TPWebWv2Version;
    /// True only when RawVersion parsed as strict major.minor.build.patch
    ParsedOk: Boolean;
    /// hive that reported the runtime (wv2chNone unless available)
    Channel: TPWebWv2Channel;
    /// human diagnostic: probe notes + pinned-loader cross-check
    // - evidence only; no policy decision ever reads this text
    Diagnostic: RawUtf8;
  end;

  /// pure provisioning decision over one detection result
  // - ordinal 0 is the failure state so a zeroed value fails closed
  TPWebWv2ProvisioningDecision = (
    wv2pdDetectionFailure,
    wv2pdProvisionRequired,
    wv2pdAlreadyUsable);

  /// outcome of one raw registry string read (internal test seam)
  // - ordinal 0 is the error state so a zeroed value fails closed
  TPWebWv2RegRead = (
    wv2rrError,
    wv2rrAbsent,
    wv2rrFound);

  /// signature of the injectable registry reader (internal test seam)
  // - SamFlags carries the registry-view flags: the detector passes
  // PWEB_KEY_WOW64_32KEY on every probe and a fake hive can therefore
  // assert the exact view the pinned loader uses
  TPWebWv2RegReader = function(Root: HKEY; const SubKey,
    ValueName: UnicodeString; SamFlags: LongWord; out Text: RawUtf8;
    out SysError: LongInt): TPWebWv2RegRead;

/// strict fail-closed parser for 4-part runtime versions
// - accepts exactly digits.digits.digits.digits with no leading zeros
// (a lone '0' stands alone), no sign, no whitespace, no channel or
// prerelease suffix, no trailing bytes; each component is bounded to
// nine digits so its numeric value is always exact
// - on any refusal returns False and a fully zeroed Version - a
// malformed string can never leak partial components into a decision
function PWebWv2VersionParse(const Text: RawUtf8;
  out Version: TPWebWv2Version): Boolean;

/// canonical text of a parsed version (round-trips the strict grammar)
function PWebWv2VersionText(const Version: TPWebWv2Version): RawUtf8;

/// the one usability threshold over a parsed version
// - pinned-loader parity: the BUILD component alone is compared,
// numerically, against PWEB_WV2_MIN_BUILD
function PWebWv2VersionUsable(const Version: TPWebWv2Version): Boolean;

/// pure usability policy over a full detection result
// - fail closed: only an AVAILABLE runtime whose version text parsed
// as strict 4-part AND whose build meets the minimum is usable;
// absent, error and malformed states are never usable
function PWebWv2DetectionUsable(
  const Detection: TPWebWv2DetectionResult): Boolean;

/// pure provisioning decision from one detection result
// - detection_error -> wv2pdDetectionFailure (never a false verdict)
// - usable -> wv2pdAlreadyUsable
// - anything else (absent, too old, malformed) -> wv2pdProvisionRequired
function PWebWv2ProvisioningDecide(
  const Detection: TPWebWv2DetectionResult): TPWebWv2ProvisioningDecision;

/// the frozen post-install invariant: installer success is never
// runtime success
// - True only when the mandatory re-probe reports a usable runtime;
// the installer exit code is diagnostic evidence and its success can
// never overrule an unusable re-probe (nor a failure exit code a
// usable one - the re-probe verdict outranks the exit code both ways)
function PWebWv2ConfirmPostInstall(InstallerExitCode: Integer;
  const ReProbe: TPWebWv2DetectionResult): Boolean;

/// the real Windows registry reader behind the seam: one REG_SZ value
// through the requested registry view; never raises
// - fail closed on anything suspicious: a non-REG_SZ value or an
// odd-length payload is a read ERROR, never truncated or coerced
function PWebWv2RegReadOs(Root: HKEY; const SubKey,
  ValueName: UnicodeString; SamFlags: LongWord; out Text: RawUtf8;
  out SysError: LongInt): TPWebWv2RegRead;

var
  /// internal test seam over the raw registry reader, public-mutable
  // by design: a plain procedural variable is the ratified seam style
  // (no interface type, no frozen surface)
  // - defaults to the real PWebWv2RegReadOs; production code never
  // assigns it - ONLY the platform test suite swaps it to pin the
  // detection walk against a fake hive, and MUST restore
  // PWebWv2RegReadOs afterwards
  PWebWv2RegReader: TPWebWv2RegReader = @PWebWv2RegReadOs;

/// the real Windows registry probe - the only impure function here
// - Microsoft-documented Clients\{...}\pv check, HKLM 32-bit view
// first then HKCU, with the pinned loader's ClientState\...\EBWebView
// walk recorded as a cross-check diagnostic
// - never raises across this boundary: any unexpected failure returns
// Status = wv2dsDetectionError
function PWebWv2Detect: TPWebWv2DetectionResult;

/// stable lowercase text for a detection status
function PWebWv2StatusText(Status: TPWebWv2DetectionStatus): RawUtf8;

/// stable lowercase text for a source channel
function PWebWv2ChannelText(Channel: TPWebWv2Channel): RawUtf8;

/// stable text for a provisioning decision
function PWebWv2DecisionText(
  Decision: TPWebWv2ProvisioningDecision): RawUtf8;

implementation

const
  // stable-channel WebView2 Evergreen GUID (Microsoft distribution doc
  // and the pinned loader's default_release_channel_guid agree)
  PWEB_WV2_STABLE_GUID = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}';
  // documented detection key: value 'pv' below Clients\{GUID}
  PWEB_WV2_CLIENTS_KEY: UnicodeString =
    'SOFTWARE\Microsoft\EdgeUpdate\Clients\' + PWEB_WV2_STABLE_GUID;
  PWEB_WV2_CLIENTS_VALUE: UnicodeString = 'pv';
  // pinned-loader parity walk: value 'EBWebView' below ClientState\{GUID}
  PWEB_WV2_CLIENT_STATE_KEY: UnicodeString =
    'SOFTWARE\Microsoft\EdgeUpdate\ClientState\' + PWEB_WV2_STABLE_GUID;
  PWEB_WV2_CLIENT_STATE_VALUE: UnicodeString = 'EBWebView';
  // winerror.h ERROR_UNSUPPORTED_TYPE (not declared by the FPC RTL)
  PWEB_ERROR_UNSUPPORTED_TYPE = 1630;
  // winerror.h ERROR_INVALID_DATA: odd-length REG_SZ payloads
  PWEB_ERROR_INVALID_DATA = 13;

function PWebWv2VersionParse(const Text: RawUtf8;
  out Version: TPWebWv2Version): Boolean;
var
  p, len: PtrInt;

  function Component(out V: Cardinal): Boolean;
  var
    digits: PtrInt;
  begin
    Result := False;
    V := 0;
    if (p > len) or
       not (Text[p] in ['0'..'9']) then
      exit;
    if Text[p] = '0' then
    begin
      Inc(p);
      // '0' must stand alone: leading zeros never round-trip
      if (p <= len) and
         (Text[p] in ['0'..'9']) then
        exit;
    end
    else
    begin
      digits := 0;
      repeat
        Inc(digits);
        // bound BEFORE any arithmetic: a too-long component fails
        // closed without the accumulator ever being able to overflow
        if digits > 9 then
          exit;
        V := V * 10 + Cardinal(Ord(Text[p]) - 48);
        Inc(p);
      until (p > len) or
            not (Text[p] in ['0'..'9']);
    end;
    Result := True;
  end;

  function Dot: Boolean;
  begin
    Result := (p <= len) and
              (Text[p] = '.');
    if Result then
      Inc(p);
  end;

begin
  FillChar(Version, SizeOf(Version), 0);
  p := 1;
  len := Length(Text);
  Result := Component(Version.Major) and Dot and
            Component(Version.Minor) and Dot and
            Component(Version.Build) and Dot and
            Component(Version.Patch) and
            // fail closed: no channel/prerelease suffix, no trailing
            // bytes of any kind
            (p > len);
  if not Result then
    // a refused parse never leaks partial components
    FillChar(Version, SizeOf(Version), 0);
end;

function IntToUtf8Local(Value: Int64): RawUtf8;
var
  num: shortstring;
begin
  Str(Value, num); // locale-free ASCII digits
  Result := num;
end;

function PWebWv2VersionText(const Version: TPWebWv2Version): RawUtf8;
begin
  Result := IntToUtf8Local(Version.Major) + '.' +
            IntToUtf8Local(Version.Minor) + '.' +
            IntToUtf8Local(Version.Build) + '.' +
            IntToUtf8Local(Version.Patch);
end;

function PWebWv2VersionUsable(const Version: TPWebWv2Version): Boolean;
begin
  // one threshold, numeric, build component only - CAP-4W loader parity
  Result := Version.Build >= PWEB_WV2_MIN_BUILD;
end;

function PWebWv2DetectionUsable(
  const Detection: TPWebWv2DetectionResult): Boolean;
begin
  Result := (Detection.Status = wv2dsAvailable) and
            Detection.ParsedOk and
            PWebWv2VersionUsable(Detection.Parsed);
end;

function PWebWv2ProvisioningDecide(
  const Detection: TPWebWv2DetectionResult): TPWebWv2ProvisioningDecision;
begin
  if Detection.Status = wv2dsDetectionError then
    // an unknown machine state must surface as a failure, never as a
    // silent install attempt or a false "already usable"
    Result := wv2pdDetectionFailure
  else if PWebWv2DetectionUsable(Detection) then
    Result := wv2pdAlreadyUsable
  else
    // absent, present-but-old and present-but-malformed all need
    // provisioning; the detection record keeps them distinguishable
    Result := wv2pdProvisionRequired;
end;

function PWebWv2ConfirmPostInstall(InstallerExitCode: Integer;
  const ReProbe: TPWebWv2DetectionResult): Boolean;
begin
  // the frozen invariant: only the re-probe can prove the install.
  // InstallerExitCode belongs to the ratified contract shape but is
  // deliberately never read - it is diagnostic evidence for callers,
  // and the compiler hint about the unused parameter documents that
  // no exit code can ever influence this verdict
  Result := PWebWv2DetectionUsable(ReProbe);
end;

{ ---- registry probe (the only impure code in this unit) ---- }

function PWebWv2RegReadOs(Root: HKEY; const SubKey,
  ValueName: UnicodeString; SamFlags: LongWord; out Text: RawUtf8;
  out SysError: LongInt): TPWebWv2RegRead;
var
  key: HKEY;
  status: LongInt;
  valueType, bytes: DWord;
  buffer: UnicodeString;
  chars: PtrInt;
  attempt: PtrInt;
begin
  Result := wv2rrError;
  Text := '';
  SysError := 0;
  key := 0;
  status := RegOpenKeyExW(Root, PWideChar(SubKey), 0,
    KEY_QUERY_VALUE or SamFlags, key);
  if (status = ERROR_FILE_NOT_FOUND) or
     (status = ERROR_PATH_NOT_FOUND) then
  begin
    Result := wv2rrAbsent;
    exit;
  end;
  if status <> ERROR_SUCCESS then
  begin
    SysError := status;
    exit; // wv2rrError
  end;
  try
    for attempt := 1 to 4 do
    begin
      bytes := 0;
      valueType := REG_NONE;
      status := RegQueryValueExW(key, PWideChar(ValueName), nil,
        @valueType, nil, @bytes);
      if status = ERROR_FILE_NOT_FOUND then
      begin
        Result := wv2rrAbsent;
        exit;
      end;
      if status <> ERROR_SUCCESS then
      begin
        SysError := status;
        exit; // wv2rrError
      end;
      if valueType <> REG_SZ then
      begin
        // a non-string 'pv' is a broken installation state, not an
        // absent runtime: report it as a detection error (fail closed)
        SysError := PWEB_ERROR_UNSUPPORTED_TYPE;
        exit; // wv2rrError
      end;
      if bytes = 0 then
      begin
        Result := wv2rrFound; // present but empty - caller decides
        exit;
      end;
      SetLength(buffer, (bytes div 2) + 1);
      status := RegQueryValueExW(key, PWideChar(ValueName), nil,
        @valueType, PByte(PWideChar(buffer)), @bytes);
      if status = ERROR_MORE_DATA then
        continue; // value grew between the two calls: retry bounded
      if (status <> ERROR_SUCCESS) or
         (valueType <> REG_SZ) then
      begin
        SysError := status;
        exit; // wv2rrError
      end;
      if (bytes and 1) <> 0 then
      begin
        // an odd byte count can never be well-formed UTF-16 REG_SZ
        // data: fail closed as a read error, never truncate silently
        SysError := PWEB_ERROR_INVALID_DATA;
        exit; // wv2rrError
      end;
      chars := bytes div 2;
      // REG_SZ data may or may not carry its terminating NUL(s)
      while (chars > 0) and
            (buffer[chars] = #0) do
        Dec(chars);
      Text := RawUnicodeToUtf8(PWideChar(buffer), chars);
      Result := wv2rrFound;
      exit;
    end;
    SysError := ERROR_MORE_DATA; // still racing after bounded retries
  finally
    RegCloseKey(key);
  end;
end;

function LastPathComponent(const Path: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := Path;
  while (Result <> '') and
        (Result[Length(Result)] in ['\', '/']) do
    SetLength(Result, Length(Result) - 1);
  i := Length(Result);
  while (i > 0) and
        not (Result[i] in ['\', '/']) do
    Dec(i);
  if i > 0 then
    Result := copy(Result, i + 1, MaxInt);
end;

// pinned-loader parity walk, reported as diagnostic text only: HKLM
// then HKCU ClientState\{GUID}\EBWebView (32-bit view), version = last
// path component - exactly what loader.hh find_installed_client reads
function ClientStateCrossCheck(const PvRaw: RawUtf8): RawUtf8;
var
  text, version, source: RawUtf8;
  err: LongInt;
  found: Boolean;
begin
  found := False;
  source := '';
  version := '';
  case PWebWv2RegReader(HKEY_LOCAL_MACHINE, PWEB_WV2_CLIENT_STATE_KEY,
    PWEB_WV2_CLIENT_STATE_VALUE, PWEB_KEY_WOW64_32KEY, text, err) of
    wv2rrFound:
      begin
        found := True;
        source := 'hklm';
      end;
    wv2rrError:
      begin
        Result := 'clientstate(hklm)=error ' + IntToUtf8Local(err);
        exit;
      end;
  else
    case PWebWv2RegReader(HKEY_CURRENT_USER, PWEB_WV2_CLIENT_STATE_KEY,
      PWEB_WV2_CLIENT_STATE_VALUE, PWEB_KEY_WOW64_32KEY, text, err) of
      wv2rrFound:
        begin
          found := True;
          source := 'hkcu';
        end;
      wv2rrError:
        begin
          Result := 'clientstate(hkcu)=error ' + IntToUtf8Local(err);
          exit;
        end;
    end;
  end;
  if not found then
  begin
    if PvRaw = '' then
      Result := 'clientstate=absent (agrees with pv)'
    else
      Result := 'clientstate=absent vs pv=' + PvRaw + ' - DIVERGENCE';
    exit;
  end;
  version := LastPathComponent(text);
  if PvRaw = '' then
    Result := 'clientstate(' + source + ')=' + version +
      ' vs absent pv - DIVERGENCE'
  else if version = PvRaw then
    Result := 'clientstate(' + source + ')=' + version +
      ' (agrees with pv)'
  else
    Result := 'clientstate(' + source + ')=' + version + ' vs pv=' +
      PvRaw + ' - DIVERGENCE';
end;

function PWebWv2Detect: TPWebWv2DetectionResult;
const
  ROOTS: array[0..1] of HKEY = (HKEY_LOCAL_MACHINE, HKEY_CURRENT_USER);
  CHANNELS: array[0..1] of TPWebWv2Channel = (wv2chHKLM, wv2chHKCU);
  NAMES: array[0..1] of RawUtf8 = ('hklm', 'hkcu');
var
  i: PtrInt;
  text, notes: RawUtf8;
  err: LongInt;
  sawError: Boolean;
begin
  // fail-closed defaults: nothing detected until proven otherwise
  Result.Status := wv2dsUnavailable;
  Result.RawVersion := '';
  FillChar(Result.Parsed, SizeOf(Result.Parsed), 0);
  Result.ParsedOk := False;
  Result.Channel := wv2chNone;
  Result.Diagnostic := '';
  try
    sawError := False;
    notes := '';
    for i := 0 to High(ROOTS) do
    begin
      case PWebWv2RegReader(ROOTS[i], PWEB_WV2_CLIENTS_KEY,
        PWEB_WV2_CLIENTS_VALUE, PWEB_KEY_WOW64_32KEY, text, err) of
        wv2rrFound:
          if (text = '') or
             (text = '0.0.0.0') then
            // both are the documented "not installed" sentinels
            notes := notes + 'pv(' + NAMES[i] + ')=not-installed; '
          else
          begin
            Result.Status := wv2dsAvailable;
            Result.RawVersion := text;
            Result.Channel := CHANNELS[i];
            Result.ParsedOk :=
              PWebWv2VersionParse(text, Result.Parsed);
            notes := notes + 'pv(' + NAMES[i] + ')=' + text + '; ';
            break; // HKLM (per-machine) outranks HKCU, like the loader
          end;
        wv2rrAbsent:
          notes := notes + 'pv(' + NAMES[i] + ')=absent; ';
        wv2rrError:
          begin
            sawError := True;
            notes := notes + 'pv(' + NAMES[i] + ')=error ' +
              IntToUtf8Local(err) + '; ';
          end;
      end;
    end;
    if (Result.Status <> wv2dsAvailable) and
       sawError then
      // no false "unavailable" when the machine state is unknown
      Result.Status := wv2dsDetectionError;
    Result.Diagnostic := notes + ClientStateCrossCheck(Result.RawVersion);
  except
    on E: Exception do
    begin
      // the boundary contract: never raise - fail closed instead
      Result.Status := wv2dsDetectionError;
      Result.RawVersion := '';
      FillChar(Result.Parsed, SizeOf(Result.Parsed), 0);
      Result.ParsedOk := False;
      Result.Channel := wv2chNone;
      Result.Diagnostic := 'unexpected ' + RawUtf8(E.ClassName) +
        ' during detection';
    end;
  end;
end;

function PWebWv2StatusText(Status: TPWebWv2DetectionStatus): RawUtf8;
begin
  case Status of
    wv2dsAvailable:
      Result := 'available';
    wv2dsUnavailable:
      Result := 'unavailable';
  else
    Result := 'detection_error';
  end;
end;

function PWebWv2ChannelText(Channel: TPWebWv2Channel): RawUtf8;
begin
  case Channel of
    wv2chHKLM:
      Result := 'hklm';
    wv2chHKCU:
      Result := 'hkcu';
  else
    Result := 'none';
  end;
end;

function PWebWv2DecisionText(
  Decision: TPWebWv2ProvisioningDecision): RawUtf8;
begin
  case Decision of
    wv2pdAlreadyUsable:
      Result := 'AlreadyUsable';
    wv2pdProvisionRequired:
      Result := 'ProvisionRequired';
  else
    Result := 'DetectionFailure';
  end;
end;

end.
