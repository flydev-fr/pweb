{
  pweb.platform.webview2.provision - WebView2 Evergreen Bootstrapper
  provisioning core for the Windows normal install profile (CAP-6b1).

  CAP-6b0 froze detection and policy (pweb.platform.webview2.runtime);
  this Windows-private unit adds the executable half the normal-profile
  setup helper needs, WITHOUT duplicating one line of frozen policy:

    PWebWv2ProvisionRun
      -> Detect (frozen PWebWv2Detect via seam)
      -> decide (frozen PWebWv2ProvisioningDecide)
      -> AlreadyUsable  => done, the installer file is never even read
      -> ProvisionRequired =>
           verify SHA-256 (byte-exact against the ratified lock digest)
           verify Authenticode (WinVerifyTrust Valid + leaf subject
             exactly equal to the ratified pin - the signature axis
             never weakens the SHA pin: both must pass, SHA first)
           execute the EXACT verified file path via CreateProcessW
             (never cmd.exe), args exactly '/silent /install', bounded
             wait (900 s ratified), kill on timeout, exit captured
           mandatory re-probe -> frozen PWebWv2ConfirmPostInstall:
             the re-probe verdict outranks the exit code in BOTH
             directions; exit codes are observational evidence only
             (Microsoft documents none, verified 2026-08-13)
      -> DetectionFailure => fail closed, the installer never runs

  Every failure is fail-closed: a zeroed outcome reads as failure, a
  malformed expected digest or empty expected subject refuses before
  any file access, an invalid timeout bound (0 or INFINITE) refuses at
  entry before even the detector runs, a timeout kills the child and
  fails even though the runtime might have landed (the ratified N10
  rule), and no code path can reach execution without both
  verification axes passing.

  TOCTOU hardening: before the digest is computed the orchestrator
  opens the payload with GENERIC_READ and share mode FILE_SHARE_READ
  ONLY (no write, no delete sharing) and holds that guard handle
  across hash -> signature -> CreateProcessW, so the verified bytes
  cannot be swapped between verification and execution; the guard is
  closed only after process creation. FILE_SHARE_READ still admits
  the loader's own read/execute open, so execution is unaffected.

  The bounded runner is truthful about what happened: a wait failure
  or an unreadable exit code after a successful CreateProcessW is
  reported as "executed, fate unknown" (wv2roExecutedUnknown) - never
  as a creation failure and never as completion - and a kill whose
  confirmation wait did not succeed is reported as UNCONFIRMED, never
  as "killed".

  The impure primitives (real detector, file hasher, WinVerifyTrust
  check, bounded process runner) sit behind the ratified seam style:
  plain procedural variables defaulting to the real implementations,
  public-mutable by design - production code never assigns them; only
  the platform test suite swaps fakes in (and must restore them) to
  drive the full N1-N12 matrix headlessly.

  No URL exists anywhere here (they live in webview2-runtime.lock
  only) and nothing here touches any frozen interface.
}
unit pweb.platform.webview2.provision;

{$mode ObjFPC}{$H+}

interface

uses
  windows,
  sysutils,
  mormot.core.base,
  mormot.core.unicode,
  mormot.core.os,
  mormot.crypt.core,
  pweb.platform.webview2.runtime;

const
  /// the exact documented silent-install arguments for the Evergreen
  // Bootstrapper (learn.microsoft.com distribution doc, retrieved
  // 2026-08-13); never anything else, never through a shell
  PWEB_WV2_BOOTSTRAPPER_ARGS = '/silent /install';

  /// ratified bounded wait for one bootstrapper run: the runtime
  // download is ~150 MB on slow links and Microsoft publishes no
  // guidance, so 900 s, then kill + fail closed
  PWEB_WV2_INSTALL_TIMEOUT_MS = 900000;

  /// how long the runner waits for a killed child to actually die
  PWEB_WV2_KILL_CONFIRM_MS = 30000;

type
  /// outcome of one bounded child-process run
  // - ordinal 0 is the failure state so a zeroed value fails closed
  // - wv2roExecutedUnknown is the truthful state for "the child DID
  // start but its fate or exit code is unknowable" (a failed wait or
  // a failed exit-code read): never reported as a creation failure,
  // never as completion - the orchestrator fails closed on it
  TPWebWv2RunOutcome = (
    wv2roCreateFailed,
    wv2roTimedOut,
    wv2roExecutedUnknown,
    wv2roCompleted);

  /// overall provisioning verdict
  // - ordinal 0 is the failure state so a zeroed value fails closed
  TPWebWv2ProvisionOutcome = (
    wv2poFailed,
    wv2poAlreadyUsable,
    wv2poProvisioned);

  /// which step a failed provisioning run died on (wv2psNone = none)
  TPWebWv2ProvisionStep = (
    wv2psNone,
    wv2psDetect,
    wv2psVerifyDigest,
    wv2psVerifySignature,
    wv2psExecute,
    wv2psReProbe);

  /// everything one provisioning run learned, for machine-parsable
  // reporting by the setup helper and for the test matrix
  TPWebWv2ProvisionResult = record
    /// Failed | AlreadyUsable | Provisioned
    Outcome: TPWebWv2ProvisionOutcome;
    /// the step a failure happened on (wv2psNone on success)
    FailedStep: TPWebWv2ProvisionStep;
    /// the initial detection result (always populated)
    Initial: TPWebWv2DetectionResult;
    /// the mandatory post-install re-probe (see ReProbed)
    ReProbe: TPWebWv2DetectionResult;
    /// True only when the re-probe actually ran
    ReProbed: Boolean;
    /// True once the bootstrapper process was created
    InstallerExecuted: Boolean;
    /// captured exit code - observational evidence ONLY, never a
    // verdict (the frozen re-probe invariant outranks it both ways)
    InstallerExitCode: Integer;
    /// human diagnostic naming digests/subjects/codes on failure
    Diagnostic: RawUtf8;
  end;

  /// signature of the injectable detector seam (initial + re-probe)
  TPWebWv2DetectFunc = function: TPWebWv2DetectionResult;

  /// signature of the injectable file-digest seam
  // - returns False (with ErrorText) when the file cannot be read;
  // HexDigest is always 64 lowercase hex chars on success
  TPWebWv2FileSha256Func = function(const FileName: TFileName;
    out HexDigest, ErrorText: RawUtf8): Boolean;

  /// signature of the injectable Authenticode seam
  // - True only for a Valid embedded signature whose leaf subject
  // equals ExpectedSubject exactly; Diag always names status/subject
  TPWebWv2SignatureFunc = function(const FileName: TFileName;
    const ExpectedSubject: RawUtf8; out Diag: RawUtf8): Boolean;

  /// signature of the injectable bounded-runner seam
  TPWebWv2RunFunc = function(const ExePath: TFileName;
    const Args: RawUtf8; TimeoutMs: Cardinal; out ExitCode: Integer;
    out Diag: RawUtf8): TPWebWv2RunOutcome;

/// SHA-256 of one file as 64 lowercase hex chars
// - fail closed: a missing or empty file is an error, never a digest
function PWebWv2FileSha256(const FileName: TFileName;
  out HexDigest, ErrorText: RawUtf8): Boolean;

/// WinVerifyTrust embedded-Authenticode check with an exact leaf
// subject requirement (case-sensitive ordinal over the X.500 string
// in CN-first order, the same rendering PowerShell's
// SignerCertificate.Subject prints)
// - True only when the signature verifies as Valid AND the signer
// leaf subject equals ExpectedSubject exactly; never raises
function PWebWv2AuthenticodeCheck(const FileName: TFileName;
  const ExpectedSubject: RawUtf8; out Diag: RawUtf8): Boolean;

/// bounded child-process runner: CreateProcessW on the EXACT file
// path (never a shell), wait at most TimeoutMs, kill on timeout,
// capture the exit code; never raises
function PWebWv2RunProcessBounded(const ExePath: TFileName;
  const Args: RawUtf8; TimeoutMs: Cardinal; out ExitCode: Integer;
  out Diag: RawUtf8): TPWebWv2RunOutcome;

var
  /// injectable detector seam (ratified seam style: plain procedural
  // variable, public-mutable; production never assigns it, ONLY the
  // platform test suite - which must restore PWebWv2Detect afterwards)
  PWebWv2ProvisionDetector: TPWebWv2DetectFunc = @PWebWv2Detect;

  /// injectable file-digest seam (same rules as above)
  PWebWv2ProvisionHasher: TPWebWv2FileSha256Func = @PWebWv2FileSha256;

  /// injectable Authenticode seam (same rules as above)
  PWebWv2ProvisionSignature: TPWebWv2SignatureFunc =
    @PWebWv2AuthenticodeCheck;

  /// injectable bounded-runner seam (same rules as above)
  PWebWv2ProvisionRunner: TPWebWv2RunFunc = @PWebWv2RunProcessBounded;

/// the one orchestration: Detect -> verify -> execute -> re-probe
// - reuses the frozen CAP-6b0 policy functions for every decision;
// see the unit comment for the exact ratified flow and N1-N12 mapping
function PWebWv2ProvisionRun(const InstallerPath: TFileName;
  const ExpectedSha256, ExpectedSubject: RawUtf8;
  TimeoutMs: Cardinal): TPWebWv2ProvisionResult;

/// stable text for a provisioning outcome (helper/gates parse these)
function PWebWv2ProvisionOutcomeText(
  Outcome: TPWebWv2ProvisionOutcome): RawUtf8;

/// stable text for a provisioning step (helper/gates parse these)
function PWebWv2ProvisionStepText(Step: TPWebWv2ProvisionStep): RawUtf8;

implementation

function IntToUtf8Local(Value: Int64): RawUtf8;
var
  num: shortstring;
begin
  Str(Value, num); // locale-free ASCII digits
  Result := num;
end;

function HexU32(Value: LongWord): RawUtf8;
begin
  Result := RawUtf8(SysUtils.IntToHex(Value, 8));
end;

{ ---- SHA-256 file digest ---- }

function PWebWv2FileSha256(const FileName: TFileName;
  out HexDigest, ErrorText: RawUtf8): Boolean;
var
  content: RawByteString;
begin
  Result := False;
  HexDigest := '';
  ErrorText := '';
  try
    if not FileExists(FileName) then
    begin
      ErrorText := 'file not found: ' + StringToUtf8(FileName);
      exit;
    end;
    content := StringFromFile(FileName);
    if content = '' then
    begin
      // an unreadable or zero-byte payload can never be the ratified
      // bootstrapper: fail closed, never hash emptiness into a verdict
      ErrorText := 'file empty or unreadable: ' + StringToUtf8(FileName);
      exit;
    end;
    HexDigest := Sha256(content); // 64 lowercase hex chars
    Result := True;
  except
    on E: Exception do
    begin
      HexDigest := '';
      ErrorText := 'unexpected ' + RawUtf8(E.ClassName) +
        ' hashing ' + StringToUtf8(FileName);
    end;
  end;
end;

{ ---- WinVerifyTrust + exact leaf subject ---- }

const
  WTD_UI_NONE = 2;
  WTD_REVOKE_NONE = 0;
  WTD_CHOICE_FILE = 1;
  WTD_STATEACTION_VERIFY = 1;
  WTD_STATEACTION_CLOSE = 2;
  // no online revocation retrieval at verify time: the setup must not
  // hang on a network probe before it even starts provisioning
  WTD_CACHE_ONLY_URL_RETRIEVAL = $1000;
  WINTRUST_ACTION_GENERIC_VERIFY_V2: TGuid =
    '{00AAC56B-CD44-11D0-8CC2-00C04FC295EE}';

  CERT_QUERY_OBJECT_FILE = 1;
  CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED = $400;
  CERT_QUERY_FORMAT_FLAG_BINARY = 2;
  CMSG_SIGNER_INFO_PARAM = 6;
  X509_ASN_ENCODING = 1;
  PKCS_7_ASN_ENCODING = $10000;
  CERT_FIND_SUBJECT_CERT = $000B0000;
  CERT_X500_NAME_STR = 3;
  // CN-first rendering, exactly what .NET X500DistinguishedName.Name
  // (and therefore the ratifying -Refresh printout) uses
  CERT_NAME_STR_REVERSE_FLAG = $02000000;

type
  TWinTrustFileInfo = record
    cbStruct: DWord;
    pcwszFilePath: PWideChar;
    hFile: THandle;
    pgKnownSubject: Pointer;
  end;

  TWinTrustData = record
    cbStruct: DWord;
    pPolicyCallbackData: Pointer;
    pSIPClientData: Pointer;
    dwUIChoice: DWord;
    fdwRevocationChecks: DWord;
    dwUnionChoice: DWord;
    pFile: ^TWinTrustFileInfo;
    dwStateAction: DWord;
    hWVTStateData: THandle;
    pwszURLReference: PWideChar;
    dwProvFlags: DWord;
    dwUIContext: DWord;
    pSignatureSettings: Pointer;
  end;

  TCryptDataBlob = record
    cbData: DWord;
    pbData: PByte;
  end;

  TCryptBitBlob = record
    cbData: DWord;
    pbData: PByte;
    cUnusedBits: DWord;
  end;

  TCryptAlgorithmIdentifier = record
    pszObjId: PAnsiChar;
    Parameters: TCryptDataBlob;
  end;

  TCryptAttributes = record
    cAttr: DWord;
    rgAttr: Pointer;
  end;

  TCmsgSignerInfo = record
    dwVersion: DWord;
    Issuer: TCryptDataBlob;
    SerialNumber: TCryptDataBlob;
    HashAlgorithm: TCryptAlgorithmIdentifier;
    HashEncryptionAlgorithm: TCryptAlgorithmIdentifier;
    EncryptedHash: TCryptDataBlob;
    AuthAttrs: TCryptAttributes;
    UnauthAttrs: TCryptAttributes;
  end;
  PCmsgSignerInfo = ^TCmsgSignerInfo;

  TCertPublicKeyInfo = record
    Algorithm: TCryptAlgorithmIdentifier;
    PublicKey: TCryptBitBlob;
  end;

  TCertInfo = record
    dwVersion: DWord;
    SerialNumber: TCryptDataBlob;
    SignatureAlgorithm: TCryptAlgorithmIdentifier;
    Issuer: TCryptDataBlob;
    NotBefore: TFileTime;
    NotAfter: TFileTime;
    Subject: TCryptDataBlob;
    SubjectPublicKeyInfo: TCertPublicKeyInfo;
    IssuerUniqueId: TCryptBitBlob;
    SubjectUniqueId: TCryptBitBlob;
    cExtension: DWord;
    rgExtension: Pointer;
  end;
  PCertInfo = ^TCertInfo;

  TCertContext = record
    dwCertEncodingType: DWord;
    pbCertEncoded: PByte;
    cbCertEncoded: DWord;
    pCertInfo: PCertInfo;
    hCertStore: Pointer;
  end;
  PCertContext = ^TCertContext;

function WinVerifyTrust(hwnd: THandle; const pgActionID: TGuid;
  pWVTData: Pointer): LongInt; stdcall;
  external 'wintrust.dll' name 'WinVerifyTrust';

function CryptQueryObject(dwObjectType: DWord; pvObject: Pointer;
  dwExpectedContentTypeFlags, dwExpectedFormatTypeFlags,
  dwFlags: DWord; pdwMsgAndCertEncodingType, pdwContentType,
  pdwFormatType: PDWord; phCertStore, phMsg: PPointer;
  ppvContext: PPointer): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptQueryObject';

function CryptMsgGetParam(hCryptMsg: Pointer; dwParamType,
  dwIndex: DWord; pvData: Pointer; pcbData: PDWord): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptMsgGetParam';

function CryptMsgClose(hCryptMsg: Pointer): BOOL; stdcall;
  external 'crypt32.dll' name 'CryptMsgClose';

function CertFindCertificateInStore(hCertStore: Pointer;
  dwCertEncodingType, dwFindFlags, dwFindType: DWord;
  pvFindPara: Pointer; pPrevCertContext: PCertContext): PCertContext;
  stdcall; external 'crypt32.dll' name 'CertFindCertificateInStore';

function CertFreeCertificateContext(pCertContext: PCertContext): BOOL;
  stdcall; external 'crypt32.dll' name 'CertFreeCertificateContext';

function CertCloseStore(hCertStore: Pointer; dwFlags: DWord): BOOL;
  stdcall; external 'crypt32.dll' name 'CertCloseStore';

function CertNameToStrW(dwCertEncodingType: DWord; pName: Pointer;
  dwStrType: DWord; psz: PWideChar; csz: DWord): DWord; stdcall;
  external 'crypt32.dll' name 'CertNameToStrW';

// extracts the leaf signer subject of the embedded PKCS#7 signature
// in CN-first X.500 rendering; '' when anything refuses
function SignerLeafSubject(const WidePath: UnicodeString;
  out Why: RawUtf8): RawUtf8;
var
  store, msg: Pointer;
  encoding: DWord;
  infoBytes: DWord;
  info: PCmsgSignerInfo;
  find: TCertInfo;
  ctx: PCertContext;
  chars: DWord;
  buffer: UnicodeString;
begin
  Result := '';
  Why := '';
  store := nil;
  msg := nil;
  info := nil;
  ctx := nil;
  encoding := 0;
  if not CryptQueryObject(CERT_QUERY_OBJECT_FILE,
      PWideChar(WidePath), CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
      CERT_QUERY_FORMAT_FLAG_BINARY, 0, @encoding, nil, nil,
      @store, @msg, nil) then
  begin
    Why := 'CryptQueryObject error ' + HexU32(GetLastError);
    exit;
  end;
  try
    infoBytes := 0;
    if not CryptMsgGetParam(msg, CMSG_SIGNER_INFO_PARAM, 0, nil,
        @infoBytes) or
       (infoBytes = 0) then
    begin
      Why := 'CryptMsgGetParam(size) error ' + HexU32(GetLastError);
      exit;
    end;
    GetMem(info, infoBytes);
    if not CryptMsgGetParam(msg, CMSG_SIGNER_INFO_PARAM, 0, info,
        @infoBytes) then
    begin
      Why := 'CryptMsgGetParam(data) error ' + HexU32(GetLastError);
      exit;
    end;
    FillChar(find, SizeOf(find), 0);
    find.Issuer := info^.Issuer;
    find.SerialNumber := info^.SerialNumber;
    ctx := CertFindCertificateInStore(store,
      X509_ASN_ENCODING or PKCS_7_ASN_ENCODING, 0,
      CERT_FIND_SUBJECT_CERT, @find, nil);
    if ctx = nil then
    begin
      Why := 'signer certificate not found in message store';
      exit;
    end;
    chars := CertNameToStrW(X509_ASN_ENCODING, @ctx^.pCertInfo^.Subject,
      CERT_X500_NAME_STR or CERT_NAME_STR_REVERSE_FLAG, nil, 0);
    if chars <= 1 then
    begin
      Why := 'CertNameToStrW sizing failed';
      exit;
    end;
    SetLength(buffer, chars);
    chars := CertNameToStrW(X509_ASN_ENCODING, @ctx^.pCertInfo^.Subject,
      CERT_X500_NAME_STR or CERT_NAME_STR_REVERSE_FLAG,
      PWideChar(buffer), chars);
    if chars <= 1 then
    begin
      Why := 'CertNameToStrW rendering failed';
      exit;
    end;
    // chars includes the terminating NUL
    Result := RawUnicodeToUtf8(PWideChar(buffer), chars - 1);
  finally
    if info <> nil then
      FreeMem(info);
    if ctx <> nil then
      CertFreeCertificateContext(ctx);
    if msg <> nil then
      CryptMsgClose(msg);
    if store <> nil then
      CertCloseStore(store, 0);
  end;
end;

function PWebWv2AuthenticodeCheck(const FileName: TFileName;
  const ExpectedSubject: RawUtf8; out Diag: RawUtf8): Boolean;
var
  widePath: UnicodeString;
  fileInfo: TWinTrustFileInfo;
  trust: TWinTrustData;
  status: LongInt;
  subject, why: RawUtf8;
begin
  Result := False;
  Diag := '';
  try
    widePath := UnicodeString(FileName);
    FillChar(fileInfo, SizeOf(fileInfo), 0);
    fileInfo.cbStruct := SizeOf(fileInfo);
    fileInfo.pcwszFilePath := PWideChar(widePath);
    FillChar(trust, SizeOf(trust), 0);
    trust.cbStruct := SizeOf(trust);
    trust.dwUIChoice := WTD_UI_NONE;
    trust.fdwRevocationChecks := WTD_REVOKE_NONE;
    trust.dwUnionChoice := WTD_CHOICE_FILE;
    trust.pFile := @fileInfo;
    trust.dwStateAction := WTD_STATEACTION_VERIFY;
    trust.dwProvFlags := WTD_CACHE_ONLY_URL_RETRIEVAL;
    status := WinVerifyTrust(THandle(-1),
      WINTRUST_ACTION_GENERIC_VERIFY_V2, @trust);
    trust.dwStateAction := WTD_STATEACTION_CLOSE;
    WinVerifyTrust(THandle(-1), WINTRUST_ACTION_GENERIC_VERIFY_V2,
      @trust);
    if status <> 0 then
    begin
      // N8: the status is always named (e.g. 800B0100 for unsigned)
      Diag := 'authenticode status=0x' + HexU32(LongWord(status)) +
        ' (not Valid); expected subject ' + ExpectedSubject;
      exit;
    end;
    subject := SignerLeafSubject(widePath, why);
    if subject = '' then
    begin
      Diag := 'authenticode Valid but signer subject unreadable (' +
        why + '); expected subject ' + ExpectedSubject;
      exit;
    end;
    if subject <> ExpectedSubject then
    begin
      // N8: both subjects are always named, byte-exact comparison
      Diag := 'authenticode subject mismatch: got ' + subject +
        '; expected exactly ' + ExpectedSubject;
      exit;
    end;
    Diag := 'authenticode Valid, subject=' + subject;
    Result := True;
  except
    on E: Exception do
    begin
      Result := False;
      Diag := 'unexpected ' + RawUtf8(E.ClassName) +
        ' during authenticode check';
    end;
  end;
end;

{ ---- bounded child-process runner ---- }

// kills a started child, reporting the kill truthfully: 'process
// killed' ONLY when the confirmation wait proved the death; any other
// outcome is reported as UNCONFIRMED with its reason
function KillChildConfirmed(Process: THandle): RawUtf8;
begin
  if not TerminateProcess(Process, DWord(-1)) then
    Result := 'kill UNCONFIRMED (TerminateProcess failed: error ' +
      IntToUtf8Local(GetLastError) + ')'
  else if WaitForSingleObject(Process, PWEB_WV2_KILL_CONFIRM_MS) =
      WAIT_OBJECT_0 then
    Result := 'process killed'
  else
    Result := 'kill UNCONFIRMED (child not proven dead within ' +
      IntToUtf8Local(PWEB_WV2_KILL_CONFIRM_MS) + ' ms)';
end;

function PWebWv2RunProcessBounded(const ExePath: TFileName;
  const Args: RawUtf8; TimeoutMs: Cardinal; out ExitCode: Integer;
  out Diag: RawUtf8): TPWebWv2RunOutcome;
var
  app, cmd: UnicodeString;
  si: STARTUPINFOW;
  pi: TProcessInformation;
  waitRes, waitErr, code: DWord;
  started: Boolean;
begin
  Result := wv2roCreateFailed;
  ExitCode := -1;
  Diag := '';
  started := False;
  try
    app := UnicodeString(ExePath);
    // the application name is passed EXPLICITLY: no shell, no PATH
    // search, no argument-zero parsing tricks - the exact verified
    // file is what executes, nothing else
    cmd := '"' + app + '" ' + Utf8ToSynUnicode(Args);
    UniqueString(cmd); // CreateProcessW may write into this buffer
    FillChar(si, SizeOf(si), 0);
    si.cb := SizeOf(si);
    FillChar(pi, SizeOf(pi), 0);
    if not CreateProcessW(PWideChar(app), PWideChar(cmd), nil, nil,
        False, CREATE_NO_WINDOW, nil, nil, si, pi) then
    begin
      Diag := 'CreateProcessW failed: error ' +
        IntToUtf8Local(GetLastError);
      exit; // wv2roCreateFailed - and ONLY here: past this point the
            // child exists and no path may claim it never started
    end;
    started := True;
    CloseHandle(pi.hThread);
    try
      waitRes := WaitForSingleObject(pi.hProcess, TimeoutMs);
      if waitRes = WAIT_OBJECT_0 then
      begin
        code := 0;
        if GetExitCodeProcess(pi.hProcess, code) then
        begin
          ExitCode := Integer(code);
          Diag := 'completed with exit code ' +
            IntToUtf8Local(ExitCode);
          Result := wv2roCompleted;
        end
        else
        begin
          // the child ran to completion but its exit code is
          // unknowable: truthful fail-closed state, never "completed"
          Diag := 'executed, but GetExitCodeProcess failed: error ' +
            IntToUtf8Local(GetLastError) + ' (exit code unknowable)';
          Result := wv2roExecutedUnknown;
        end;
      end
      else if waitRes = WAIT_TIMEOUT then
      begin
        // N10: kill, confirm the kill, fail closed - a hung installer
        // never holds the setup hostage and never counts as success
        Diag := 'timed out after ' + IntToUtf8Local(TimeoutMs) +
          ' ms; ' + KillChildConfirmed(pi.hProcess);
        Result := wv2roTimedOut;
      end
      else
      begin
        // WAIT_FAILED (or an impossible wait result): the child DID
        // start - kill it bounded and report the truth, never a
        // creation failure
        waitErr := GetLastError;
        Diag := 'executed, but WaitForSingleObject failed: error ' +
          IntToUtf8Local(waitErr) + '; ' +
          KillChildConfirmed(pi.hProcess);
        Result := wv2roExecutedUnknown;
      end;
    finally
      CloseHandle(pi.hProcess);
    end;
  except
    on E: Exception do
    begin
      // truthfulness even here: once the child started, an internal
      // failure can never be reported as "never started"
      if started then
        Result := wv2roExecutedUnknown
      else
        Result := wv2roCreateFailed;
      Diag := 'unexpected ' + RawUtf8(E.ClassName) +
        ' running the installer';
    end;
  end;
end;

{ ---- orchestration over the frozen CAP-6b0 policy ---- }

function ExpectedDigestValid(const Hex: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := False;
  if Length(Hex) <> 64 then
    exit;
  for i := 1 to 64 do
    if not (Hex[i] in ['0'..'9', 'a'..'f']) then
      exit;
  Result := True;
end;

function PWebWv2ProvisionRun(const InstallerPath: TFileName;
  const ExpectedSha256, ExpectedSubject: RawUtf8;
  TimeoutMs: Cardinal): TPWebWv2ProvisionResult;
var
  actual, hashErr, sigDiag, runDiag: RawUtf8;
  runOutcome: TPWebWv2RunOutcome;
  code: Integer;
  guard: THandle;
begin
  // fail-closed defaults: a zeroed record already reads as a failure
  Result := Default(TPWebWv2ProvisionResult);
  Result.Outcome := wv2poFailed;
  Result.FailedStep := wv2psDetect;
  Result.InstallerExitCode := -1;
  // an unbounded run can never be requested: 0 would poll-and-fail a
  // healthy installer, INFINITE would remove the ratified bound - both
  // are refused at entry, before even the detector runs
  if (TimeoutMs = 0) or
     (TimeoutMs = $FFFFFFFF) then
  begin
    Result.FailedStep := wv2psExecute;
    Result.Diagnostic := 'timeout bound invalid: ' +
      IntToUtf8Local(TimeoutMs) +
      ' ms (0 and INFINITE are refused; the ratified bound is ' +
      IntToUtf8Local(PWEB_WV2_INSTALL_TIMEOUT_MS) + ' ms)';
    exit;
  end;
  Result.Initial := PWebWv2ProvisionDetector();
  case PWebWv2ProvisioningDecide(Result.Initial) of
    wv2pdDetectionFailure:
      begin
        // N6: an unknown machine state never triggers an installer run
        Result.Diagnostic := 'initial detection failed: ' +
          Result.Initial.Diagnostic;
        exit;
      end;
    wv2pdAlreadyUsable:
      begin
        // N1/N11: the bootstrapper file is never even read
        Result.Outcome := wv2poAlreadyUsable;
        Result.FailedStep := wv2psNone;
        Result.Diagnostic := 'runtime already usable: ' +
          Result.Initial.RawVersion;
        exit;
      end;
  end;
  // wv2pdProvisionRequired from here on
  Result.FailedStep := wv2psVerifyDigest;
  if not ExpectedDigestValid(ExpectedSha256) then
  begin
    // a malformed pin argument can never wave a payload through -
    // refused before the payload is even opened
    Result.Diagnostic :=
      'expected sha256 is not 64 lowercase hex chars: ' + ExpectedSha256;
    exit;
  end;
  // TOCTOU guard: GENERIC_READ with FILE_SHARE_READ ONLY - no writer
  // and no deleter can touch the payload between verification and
  // execution while this handle is held (the loader's read/execute
  // open remains compatible, so CreateProcessW still works)
  guard := CreateFileW(PWideChar(UnicodeString(InstallerPath)),
    GENERIC_READ, FILE_SHARE_READ, nil, OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL, 0);
  if guard = INVALID_HANDLE_VALUE then
  begin
    Result.Diagnostic := 'cannot hold the payload for verification (' +
      'CreateFileW error ' + IntToUtf8Local(GetLastError) + '): ' +
      StringToUtf8(InstallerPath);
    exit;
  end;
  try
    if not PWebWv2ProvisionHasher(InstallerPath, actual, hashErr) then
    begin
      Result.Diagnostic := 'sha256 verification impossible: ' + hashErr;
      exit;
    end;
    if actual <> ExpectedSha256 then
    begin
      // N7: both digests are named, the installer never runs
      Result.Diagnostic := 'sha256 mismatch: expected ' + ExpectedSha256 +
        ', got ' + actual + ' -- payload refused';
      exit;
    end;
    Result.FailedStep := wv2psVerifySignature;
    if ExpectedSubject = '' then
    begin
      Result.Diagnostic := 'expected authenticode subject is empty';
      exit;
    end;
    if not PWebWv2ProvisionSignature(InstallerPath, ExpectedSubject,
        sigDiag) then
    begin
      // N8: sigDiag names status and subject(s)
      Result.Diagnostic := sigDiag;
      exit;
    end;
    Result.FailedStep := wv2psExecute;
    runOutcome := PWebWv2ProvisionRunner(InstallerPath,
      PWEB_WV2_BOOTSTRAPPER_ARGS, TimeoutMs, code, runDiag);
    case runOutcome of
      wv2roCreateFailed:
        begin
          Result.Diagnostic := 'installer execution failed: ' + runDiag;
          exit;
        end;
      wv2roTimedOut:
        begin
          // N10: the ratified rule - timeout is a failure even though
          // the runtime might have landed; no re-probe can rescue it
          Result.InstallerExecuted := True;
          Result.Diagnostic := 'installer ' + runDiag;
          exit;
        end;
      wv2roExecutedUnknown:
        begin
          // truthful fail-closed: the child started but its fate or
          // exit code is unknowable - never completion, never a
          // false "never started"
          Result.InstallerExecuted := True;
          Result.Diagnostic := 'installer ' + runDiag;
          exit;
        end;
    end;
    Result.InstallerExecuted := True;
    Result.InstallerExitCode := code;
  finally
    // the guard is released only after process creation: the runner
    // has returned, so the executed image was the verified bytes
    CloseHandle(guard);
  end;
  Result.FailedStep := wv2psReProbe;
  Result.ReProbe := PWebWv2ProvisionDetector();
  Result.ReProbed := True;
  if PWebWv2ConfirmPostInstall(code, Result.ReProbe) then
  begin
    // N2/N3/N5: the frozen invariant confirmed the install - a
    // nonzero exit code with a usable re-probe is still success
    Result.Outcome := wv2poProvisioned;
    Result.FailedStep := wv2psNone;
    Result.Diagnostic := 'provisioned: re-probe usable (' +
      Result.ReProbe.RawVersion + '); installer exit ' +
      IntToUtf8Local(code) + ' (observational)';
  end
  else
    // N4/N12: exit 0 never outranks an unusable re-probe
    Result.Diagnostic := 'post-install re-probe not usable (status=' +
      PWebWv2StatusText(Result.ReProbe.Status) + ' raw=' +
      Result.ReProbe.RawVersion + '); installer exit ' +
      IntToUtf8Local(code) + ' (observational, never a verdict)';
end;

function PWebWv2ProvisionOutcomeText(
  Outcome: TPWebWv2ProvisionOutcome): RawUtf8;
begin
  case Outcome of
    wv2poAlreadyUsable:
      Result := 'AlreadyUsable';
    wv2poProvisioned:
      Result := 'Provisioned';
  else
    Result := 'Failed';
  end;
end;

function PWebWv2ProvisionStepText(Step: TPWebWv2ProvisionStep): RawUtf8;
begin
  case Step of
    wv2psDetect:
      Result := 'detect';
    wv2psVerifyDigest:
      Result := 'verify_digest';
    wv2psVerifySignature:
      Result := 'verify_signature';
    wv2psExecute:
      Result := 'execute';
    wv2psReProbe:
      Result := 'reprobe';
  else
    Result := 'none';
  end;
end;

end.
