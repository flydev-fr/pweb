{
  pweb.test.capabilities - headless CAP-8A unit suite over the
  production capability engine (mormot.core.test).

  Covers the mandated A1-A35 matrix exactly; each published method's
  header comment names the numbers it carries:
    A1-A6   capability grammar (PWebValidCapability, D2 bound)
    A7-A15  canonical sets, intersection defaults, builder refusals
    A16-A22 method mapping decisions (fail closed, all-of, exact)
    A23-A26 context identity (D5/D6) and forgery/copy-on-read
    A27     policy exception => deny => internal_error (frozen barrier)
    A28-A30 runtime grants: revocation, keying, concurrency
    A31-A32 zero-cap registration is advisory-compatible and distinct
            from unmapped
    A33-A35 deny envelope through the real scheduler: canonical
            forbidden result, zero bridge activity, malformed context

  This unit is WEBVIEW-FREE and mORMot-BRIDGE-FREE: the pipeline cases
  run the real TInvocationScheduler over the CAP-2 dummy bridge, so the
  whole suite is headless on all four CI targets.

  It is also the ONE home of the CAP-8A REFERENCE CONFIGURATION
  (security-model.md worked example + the CalculatorService mapping):
  NewReferencePolicy and the Ref*Context builders are exported for the
  integration gates in pweb.test.capabilities.integration.pas - no
  duplication.

  DecisionDigest additionally emits build/cap7f/capability-policy.txt:
  the canonical LF policy-decision corpus whose SHA-256 the CAP-7F
  evidence emitters record as capability_policy_digest and the
  aggregator requires to be identical across the four targets. Every
  line is a pure policy decision, so the bytes are target-independent
  by construction.
}

{$I mormot.defines.inc}

unit pweb.test.capabilities;

interface

uses
  sysutils,
  classes,
  syncobjs,
  mormot.core.base,
  mormot.core.os,
  mormot.core.test,
  pweb.rpc.intf,
  pweb.rpc.support,
  pweb.rpc.scheduler,
  pweb.rpc.bridge.dummy,
  pweb.capabilities.policy,
  pweb.test.scheduler;

type
  TTestCapabilityPolicy = class(TSynTestCase)
  protected
    procedure GrantMisuseMustRaise(APolicy: TPWebCapabilityPolicy);
  published
    procedure GrammarVector;
    procedure CanonicalSetsAndIntersection;
    procedure BuilderRefusals;
    procedure MappingDecisions;
    procedure ContextIdentityAndForgery;
    procedure PolicyExceptionBarrier;
    procedure RuntimeGrantLifecycle;
    procedure ConcurrentGrantSafety;
    procedure AdvisoryZeroCap;
    procedure DenyEnvelopeAndZeroBridge;
    procedure DecisionDigest;
  end;

const
  { the file the CAP-7F emitters hash into capability_policy_digest -
    the ONE spelling of the path on the Pascal side; DecisionDigest
    derives its write path from this constant (repo-root anchored,
    '/' mapped to PathDelim) }
  PWEB_CAP8A_DIGEST_FILE = 'build/cap7f/capability-policy.txt';

  { the reference configuration's explicit AppMaximum, spelled once:
    NewReferencePolicy configures it and DecisionDigest derives its
    `appmax=` corpus line from it - never from a snapshot of some
    incidentally unconfigured principal }
  PWEB_CAP8A_REF_APPMAX: array[0..6] of Utf8String = (
    'calculator.add', 'filesystem.read', 'parking.read', 'parking.write',
    'settings.read', 'settings.write', 'window.control');

/// the CAP-8A reference configuration (worked example of
// security-model.md + CalculatorService/GhostService rows), built
// through the production builder - shared with the integration gates
function NewReferencePolicy: TPWebCapabilityPolicy;

/// native reference contexts with Capabilities populated from
// SnapshotCapabilities, exactly as the release host's D9 wrapper does
function RefContextMain(APolicy: TPWebCapabilityPolicy): TInvocationContext;
function RefContextLogin(APolicy: TPWebCapabilityPolicy): TInvocationContext;
function RefContextPlugin(APolicy: TPWebCapabilityPolicy): TInvocationContext;

implementation

{ ---------------- reference configuration (shared) ---------------- }

function NewReferencePolicy: TPWebCapabilityPolicy;
var
  b: TPWebCapabilityPolicyBuilder;
begin
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    // the ceiling: the worked example of security-model.md plus the
    // calculator capability the CAP-3..7 pipeline proves end to end -
    // spelled ONCE in PWEB_CAP8A_REF_APPMAX (the digest corpus derives
    // its appmax= line from the same constant)
    b.SetAppMaximum(PWEB_CAP8A_REF_APPMAX);
    // static window sets (filesystem.read stays ceiling-only on purpose:
    // no principal or window lists it, so nothing effective carries it)
    b.SetWindowCapabilities('main', ['calculator.add', 'parking.read',
      'parking.write', 'settings.read', 'settings.write',
      'window.control']);
    b.SetWindowCapabilities('login', ['settings.read', 'window.control']);
    // static principal sets
    b.SetPrincipalCapabilities('window:main', ['calculator.add',
      'parking.read', 'parking.write', 'settings.read', 'settings.write',
      'window.control']);
    b.SetPrincipalCapabilities('window:login',
      ['settings.read', 'window.control']);
    b.SetPrincipalCapabilities('plugin:reporting', ['parking.read']);
    // method -> required-set rows (all-of); SettingsService.Purge is
    // deliberately NOT mapped (the unmapped => deny gate), and
    // GhostService.Ping is mapped but never registered in any bridge
    // catalog (the mapped-but-unregistered => method_not_found gate)
    b.MapMethod('CalculatorService.Add', ['calculator.add']);
    b.MapMethod('SettingsService.GetValue', ['settings.read']);
    b.MapMethod('SettingsService.SetValue', ['settings.write']);
    b.MapMethod('ParkingService.List', ['parking.read']);
    b.MapMethod('ParkingService.Reserve', ['parking.write']);
    b.MapMethod('GhostService.Ping', ['settings.read']);
    // explicit zero-capability registrations - distinct from unmapped
    b.RegisterZeroCapMethod(PWEB_METHOD_HANDSHAKE);
    b.RegisterZeroCapMethod(PWEB_METHOD_ECHO);
    Result := b.Build;
  finally
    b.Free;
  end;
end;

function RefContextMain(APolicy: TPWebCapabilityPolicy): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := 'main';
  Result.PrincipalId := 'window:main';
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
  Result.Capabilities := APolicy.SnapshotCapabilities('window:main', 'main');
end;

function RefContextLogin(APolicy: TPWebCapabilityPolicy): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.WindowId := 'login';
  Result.PrincipalId := 'window:login';
  Result.PrincipalKind := pkWindow;
  Result.TrustedContent := True;
  Result.Capabilities := APolicy.SnapshotCapabilities('window:login', 'login');
end;

function RefContextPlugin(APolicy: TPWebCapabilityPolicy): TInvocationContext;
begin
  Result := Default(TInvocationContext);
  Result.PrincipalId := 'plugin:reporting';
  Result.PrincipalKind := pkPlugin;
  Result.PluginId := 'reporting';
  Result.TrustedContent := True;
  Result.Capabilities := APolicy.SnapshotCapabilities('plugin:reporting');
end;

{ The repository root, found by walking up from the executable to the
  webview.lock marker (at most eight levels - the test binaries live two
  or three below it). Returns '' outside a checkout, in which case the
  digest falls back to the current directory - emitters are CI-side and
  always run inside the checkout. Trailing path delimiter included. }
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
    parent := ExtractFilePath(ExcludeTrailingPathDelimiter(dir));
    if (parent = '') or (parent = dir) then
      break;
    dir := parent;
  end;
  Result := '';
end;

function CapsCsv(const ACaps: TPWebCapabilities): Utf8String;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(ACaps) do
  begin
    if i > 0 then
      Result := Result + ',';
    Result := Result + ACaps[i];
  end;
end;

{ ---------------- A1-A6 grammar ---------------- }

procedure TTestCapabilityPolicy.GrammarVector;
var
  s: Utf8String;
begin
  // A1: canonical identifiers of every legal shape are accepted
  Check(PWebValidCapability('a'), 'A1 single segment');
  Check(PWebValidCapability('calculator.add'), 'A1 two segments');
  Check(PWebValidCapability('a.b.c'), 'A1 three segments');
  Check(PWebValidCapability('parking0.read1'), 'A1 digits inside');
  Check(PWebValidCapability('0'), 'A1 digit-only segment');
  // A2: the empty string is never a capability
  Check(not PWebValidCapability(''), 'A2 empty');
  // A3: uppercase, underscore and hyphen are outside the grammar
  Check(not PWebValidCapability('Parking.read'), 'A3 uppercase');
  Check(not PWebValidCapability('parking_read'), 'A3 underscore');
  Check(not PWebValidCapability('parking-read'), 'A3 hyphen');
  // A4: dot abuse - leading, trailing, doubled, lone
  Check(not PWebValidCapability('.parking'), 'A4 leading dot');
  Check(not PWebValidCapability('parking.'), 'A4 trailing dot');
  Check(not PWebValidCapability('parking..read'), 'A4 double dot');
  Check(not PWebValidCapability('.'), 'A4 lone dot');
  // A5: the D2 byte bound - 128 accepted, 129 refused
  s := Utf8String(StringOfChar('a', PWEB_CAPABILITY_MAX_BYTES));
  Check(PWebValidCapability(s), 'A5 exactly 128 bytes');
  Check(not PWebValidCapability(s + 'a'), 'A5 129 bytes');
  // A6: space, NUL, slash, non-ASCII are refused
  Check(not PWebValidCapability('parking read'), 'A6 space');
  Check(not PWebValidCapability('parking'#0'read'), 'A6 NUL');
  Check(not PWebValidCapability('parking/read'), 'A6 slash');
  Check(not PWebValidCapability('caf'#$C3#$A9), 'A6 non-ASCII');
end;

{ ---------------- A7-A15 sets, intersection, builder ---------------- }

procedure TTestCapabilityPolicy.CanonicalSetsAndIntersection;
var
  s, t, r: TPWebCapabilities;
  f, g, h: TPWebCapabilityFactor;
begin
  // A7: construction canonicalizes to byte-sorted unique order
  s := PWebCapabilitySetOf(['settings.write', 'parking.read', 'a']);
  CheckEqual(CapsCsv(s), 'a,parking.read,settings.write', 'A7 sorted');
  Check(PWebCapabilityIn(s, 'parking.read'), 'A7 member');
  Check(not PWebCapabilityIn(s, 'parking'), 'A7 no prefix match');
  // A8: exact intersection of two explicit sets
  t := PWebCapabilitySetOf(['parking.read', 'settings.read', 'a']);
  r := PWebCapabilityIntersect(s, t);
  CheckEqual(CapsCsv(r), 'a,parking.read', 'A8 exact intersection');
  // A9: an absent factor is the neutral element (unrestricted)
  f := PWebFactorOf(['parking.read', 'settings.read']);
  g := PWebFactorAbsent;
  h := PWebFactorIntersect(f, g);
  Check(h.Present, 'A9 explicit wins over absent');
  CheckEqual(CapsCsv(h.Caps), 'parking.read,settings.read', 'A9 unchanged');
  h := PWebFactorIntersect(g, g);
  Check(not h.Present, 'A9 absent INTERSECT absent stays absent');
  // A10: an explicit EMPTY factor annihilates - no rights
  h := PWebFactorIntersect(f, PWebFactorOf([]));
  Check(h.Present and (Length(h.Caps) = 0), 'A10 explicit empty = no rights');
end;

procedure TTestCapabilityPolicy.BuilderRefusals;
var
  b: TPWebCapabilityPolicyBuilder;
  p: TPWebCapabilityPolicy;
  raised: Boolean;
begin
  // A11: a duplicate capability inside one configured set refuses
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    raised := False;
    try
      b.SetAppMaximum(['parking.read', 'parking.read']);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A11 duplicate cap in a set');
    // A12: bad grammar refuses in every setter
    raised := False;
    try
      b.SetPrincipalCapabilities('window:main', ['Parking.Read']);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A12 grammar refused in principal row');
    raised := False;
    try
      b.MapMethod('not a method', ['parking.read']);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A12 non-canonical method row refused');
    raised := False;
    try
      b.MapMethod('Parking.List', []);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A12 empty required set must go through zero-cap');
  finally
    b.Free;
  end;
  // A13: Build without AppMaximum refuses - the ceiling is mandatory
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.MapMethod('Parking.List', ['parking.read']);
    raised := False;
    try
      p := b.Build;
      p.Free;
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A13 missing AppMaximum');
  finally
    b.Free;
  end;
  // A14: duplicate rows refuse (method, principal, window, ceiling)
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum(['parking.read']);
    raised := False;
    try
      b.SetAppMaximum(['parking.read']);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A14 second AppMaximum');
    b.SetWindowCapabilities('main', ['parking.read']);
    raised := False;
    try
      b.SetWindowCapabilities('main', []);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A14 duplicate window row');
    b.RegisterZeroCapMethod('Parking.List');
    raised := False;
    try
      b.MapMethod('Parking.List', ['parking.read']);
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A14 duplicate method row');
  finally
    b.Free;
  end;
  // A15: a contradictory row (required outside AppMaximum) refuses at
  // Build, atomically - no policy object exists afterwards
  b := TPWebCapabilityPolicyBuilder.Create;
  try
    b.SetAppMaximum(['parking.read']);
    b.MapMethod('Settings.Get', ['settings.read']);
    p := nil;
    raised := False;
    try
      p := b.Build;
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, 'A15 contradictory row refused');
    Check(p = nil, 'A15 no partially valid policy exists');
  finally
    b.Free;
  end;
end;

{ ---------------- A16-A22 mapping decisions ---------------- }

procedure TTestCapabilityPolicy.MappingDecisions;
var
  p, raw: TPWebCapabilityPolicy;
  pRef, rawRef: ICapabilityPolicy;
  ctx: TInvocationContext;
begin
  p := NewReferencePolicy;
  pRef := p; // interface reference owns the lifetime
  // A16: mapped method + capability held => allowed
  ctx := RefContextMain(p);
  Check(p.IsAllowed(ctx, 'CalculatorService.Add'), 'A16 allowed');
  // A17: unmapped method => deny, even for the most capable principal
  Check(not p.IsAllowed(ctx, 'SettingsService.Purge'), 'A17 unmapped');
  Check(not p.IsAllowed(ctx, 'Unknown.Method'), 'A17 unknown');
  // A18: mapped method, capability absent from the context => deny
  ctx := RefContextLogin(p);
  Check(not p.IsAllowed(ctx, 'CalculatorService.Add'), 'A18 cap not held');
  Check(p.IsAllowed(ctx, 'SettingsService.GetValue'), 'A18 held cap ok');
  // A19: all-of over a multi-capability row (fresh two-cap config; the
  // previous policy is released through its interface reference)
  pRef := nil;
  p := nil;
  with TPWebCapabilityPolicyBuilder.Create do
  try
    SetAppMaximum(['settings.read', 'settings.write']);
    MapMethod('Settings.Replace', ['settings.read', 'settings.write']);
    p := Build;
  finally
    Free;
  end;
  pRef := p;
  ctx := Default(TInvocationContext);
  ctx.PrincipalId := 'window:w';
  ctx.WindowId := 'w';
  ctx.PrincipalKind := pkWindow;
  ctx.TrustedContent := True;
  ctx.Capabilities := PWebCapabilitySetOf(['settings.read']);
  Check(not p.IsAllowed(ctx, 'Settings.Replace'), 'A19 one of two held');
  ctx.Capabilities := PWebCapabilitySetOf(['settings.read', 'settings.write']);
  Check(p.IsAllowed(ctx, 'Settings.Replace'), 'A19 both held');
  // A20: defense in depth - a context capability OUTSIDE AppMaximum
  // grants nothing (required is checked against the ceiling too)
  pRef := nil;
  p := nil;
  with TPWebCapabilityPolicyBuilder.Create do
  try
    SetAppMaximum(['settings.read']);
    MapMethod('Settings.Get', ['settings.read']);
    RegisterZeroCapMethod('Zero.Cap');
    p := Build;
  finally
    Free;
  end;
  pRef := p;
  ctx.Capabilities := PWebCapabilitySetOf(['filesystem.read', 'settings.read']);
  Check(p.IsAllowed(ctx, 'Settings.Get'), 'A20 in-ceiling cap works');
  // an out-of-ceiling capability can never appear in a Build-validated
  // row; the ceiling membership check in IsAllowed guards the raw-
  // constructed and future-config paths - proven via a raw instance:
  raw := TPWebCapabilityPolicy.Create;
  rawRef := raw; // interface reference owns the lifetime
  Check(not raw.IsAllowed(ctx, 'Settings.Get'),
    'A20 raw instance denies everything');
  rawRef := nil;
  // A21: exact compare - no wildcard, no prefix, no inheritance
  ctx.Capabilities := PWebCapabilitySetOf(['settings']);
  Check(not p.IsAllowed(ctx, 'Settings.Get'), 'A21 parent grants nothing');
  ctx.Capabilities := PWebCapabilitySetOf(['settings.read.details']);
  Check(not p.IsAllowed(ctx, 'Settings.Get'), 'A21 child grants nothing');
  // A22: zero-cap registration - allowed with an empty capability set,
  // and distinct from unmapped (which stays denied)
  ctx.Capabilities := nil;
  Check(p.IsAllowed(ctx, 'Zero.Cap'), 'A22 zero-cap with empty set');
  Check(not p.IsAllowed(ctx, 'Zero.Unmapped'), 'A22 unmapped still denied');
  pRef := nil;
end;

{ ---------------- A23-A26 context identity and forgery ---------------- }

procedure TTestCapabilityPolicy.ContextIdentityAndForgery;
var
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  ctx: TInvocationContext;
  snap: TPWebCapabilities;
begin
  p := NewReferencePolicy;
  pRef := p;
  // A23: an empty PrincipalId denies, whatever else the context claims
  ctx := RefContextMain(p);
  ctx.PrincipalId := '';
  Check(not p.IsAllowed(ctx, 'CalculatorService.Add'), 'A23 empty principal');
  // A24: a window principal with untrusted content or no window id denies
  ctx := RefContextMain(p);
  ctx.TrustedContent := False;
  Check(not p.IsAllowed(ctx, 'CalculatorService.Add'), 'A24 untrusted');
  ctx := RefContextMain(p);
  ctx.WindowId := '';
  Check(not p.IsAllowed(ctx, 'CalculatorService.Add'), 'A24 no window id');
  // A25: a plugin principal without a plugin id denies; system and
  // QuickJS principals need no window fields
  ctx := RefContextPlugin(p);
  ctx.PluginId := '';
  Check(not p.IsAllowed(ctx, 'ParkingService.List'), 'A25 no plugin id');
  ctx := Default(TInvocationContext);
  ctx.PrincipalId := 'system:host';
  ctx.PrincipalKind := pkSystem;
  ctx.Capabilities := PWebCapabilitySetOf(['parking.read']);
  Check(p.IsAllowed(ctx, 'ParkingService.List'), 'A25 system principal');
  ctx.PrincipalKind := pkQuickJS;
  Check(p.IsAllowed(ctx, 'ParkingService.List'), 'A25 quickjs principal');
  // A26: copy-on-read - mutating a returned snapshot never reaches the
  // policy's own state; the next snapshot is pristine (the forged-args
  // integration gate I9 proves the wire-side half of this claim)
  snap := p.SnapshotCapabilities('window:login', 'login');
  CheckEqual(CapsCsv(snap), 'settings.read,window.control', 'A26 snapshot');
  snap[0] := 'calculator.add';
  snap := p.SnapshotCapabilities('window:login', 'login');
  CheckEqual(CapsCsv(snap), 'settings.read,window.control',
    'A26 state unharmed by caller mutation');
  // and an empty principal id snapshots to the empty set - fail closed
  CheckEqual(CapsCsv(p.SnapshotCapabilities('', 'main')), '',
    'A26 empty principal snapshots to nothing');
  pRef := nil;
end;

{ ---------------- A27 exception barrier ---------------- }

procedure TTestCapabilityPolicy.PolicyExceptionBarrier;
var
  bridge: TDummyInvocationBridge;
  bridgeRef: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
begin
  // A27: an exception escaping IsAllowed is a DENY completed as
  // internal_error at the frozen call site - never fail open, and the
  // bridge is never reached. The production engine never raises; this
  // pins the barrier the engine's contract stands on.
  bridge := TDummyInvocationBridge.Create;
  bridgeRef := bridge;
  scheduler := TInvocationScheduler.Create(TRaisingPolicy.Create,
    bridgeRef, 1);
  schedulerRef := scheduler;
  try
    limits.MaxConcurrent := 1;
    limits.MaxQueueSize := 4;
    source := scheduler.RegisterSource(limits);
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(TestContext, PWEB_METHOD_ECHO, '{}',
      sinkRef) = perAccepted);
    if not sink.WaitDone(5000) then
    begin
      Check(False, 'A27 completion never arrived');
      exit; // never read an empty completion (finally still tears down)
    end;
    Check(sink.First.Kind = prkError, 'A27 error arm');
    Check(sink.First.Error.Code = pecInternalError, 'A27 internal_error');
    CheckEqual(bridge.InvokeCount, 0, 'A27 bridge never reached');
  finally
    scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    bridgeRef := nil;
  end;
end;

{ ---------------- A28-A30 runtime grants ---------------- }

procedure TTestCapabilityPolicy.RuntimeGrantLifecycle;
var
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  before, after: TPWebCapabilities;
begin
  p := NewReferencePolicy;
  pRef := p;
  // A28: revocation between two snapshots - the next snapshot loses
  // the capability while the EARLIER snapshot array stays intact (an
  // enqueued invocation keeps its captured context, deep-copied at the
  // scheduler's frozen TryEnqueue gate)
  p.SetRuntimeGrants('window:main', ['calculator.add', 'parking.read',
    'parking.write', 'settings.read', 'settings.write', 'window.control']);
  before := p.SnapshotCapabilities('window:main', 'main');
  Check(PWebCapabilityIn(before, 'calculator.add'), 'A28 granted before');
  p.RevokeRuntimeGrant('window:main', 'calculator.add');
  after := p.SnapshotCapabilities('window:main', 'main');
  Check(not PWebCapabilityIn(after, 'calculator.add'), 'A28 revoked after');
  Check(PWebCapabilityIn(after, 'settings.read'), 'A28 others survive');
  Check(PWebCapabilityIn(before, 'calculator.add'),
    'A28 captured snapshot untouched by the revoke');
  // A30: grants are keyed by principal - revoking one principal leaves
  // the other untouched; Clear restores the absent (unrestricted) factor
  p.RevokeRuntimeGrant('window:login', 'settings.read');
  CheckEqual(CapsCsv(p.SnapshotCapabilities('window:login', 'login')), '',
    'A30 revoke on an absent factor fails closed to empty');
  Check(PWebCapabilityIn(p.SnapshotCapabilities('window:main', 'main'),
    'settings.read'), 'A30 sibling principal unaffected');
  p.ClearRuntimeGrants('window:login');
  CheckEqual(CapsCsv(p.SnapshotCapabilities('window:login', 'login')),
    'settings.read,window.control', 'A30 clear restores unrestricted');
  p.ClearRuntimeGrants('window:main');
  Check(PWebCapabilityIn(p.SnapshotCapabilities('window:main', 'main'),
    'calculator.add'), 'A30 clear restores the static set');
  // the documented loud-misuse contract of the grant store (A28-A30):
  // every refusal below is the ratified EPWebCapabilityConfig, and the
  // out-of-ceiling refusal mirrors the builder's contradictory-row rule
  GrantMisuseMustRaise(p);
  pRef := nil;
end;

procedure TTestCapabilityPolicy.GrantMisuseMustRaise(
  APolicy: TPWebCapabilityPolicy);

  procedure MustRaise(AWhich: Integer; const AMsg: string);
  var
    raised: Boolean;
  begin
    raised := False;
    try
      case AWhich of
        0: APolicy.SetRuntimeGrants('', ['settings.read']);
        1: APolicy.SetRuntimeGrants('window:main', ['Settings.Read']);
        2: APolicy.SetRuntimeGrants('window:main',
             ['settings.read', 'settings.read']);
        3: APolicy.SetRuntimeGrants('window:main', ['outside.ceiling']);
        4: APolicy.RevokeRuntimeGrant('', 'settings.read');
        5: APolicy.RevokeRuntimeGrant('window:main', 'BAD CAP');
        6: APolicy.ClearRuntimeGrants('');
      end;
    except
      on EPWebCapabilityConfig do
        raised := True;
    end;
    Check(raised, AMsg);
  end;

begin
  MustRaise(0, 'grants: empty principal id must raise');
  MustRaise(1, 'grants: invalid capability grammar must raise');
  MustRaise(2, 'grants: duplicate capability must raise');
  MustRaise(3, 'grants: capability outside AppMaximum must raise');
  MustRaise(4, 'revoke: empty principal id must raise');
  MustRaise(5, 'revoke: invalid capability grammar must raise');
  MustRaise(6, 'clear: empty principal id must raise');
  // and none of the refusals left partial state behind: the principal
  // still resolves to its full static set
  CheckEqual(CapsCsv(APolicy.SnapshotCapabilities('window:main', 'main')),
    'calculator.add,parking.read,parking.write,settings.read,' +
    'settings.write,window.control',
    'grants: refused misuse mutated no state');
end;

type
  { A29 driver: flips one principal's grant factor between two coherent
    states while the test thread snapshots. Started behind an explicit
    Go barrier and stopped by the test, with an interlocked flip
    counter, so the test can PROVE the two sides actually overlapped
    instead of passing vacuously when one side finished before the
    other began. }
  TGrantFlipperThread = class(TThread)
  private
    FPolicy: TPWebCapabilityPolicy;
    FGo, FStop, FFlips: LongInt;
  protected
    procedure Execute; override;
  public
    constructor Create(APolicy: TPWebCapabilityPolicy);
    procedure Go;
    procedure Stop;
    function Flips: Integer;
  end;

constructor TGrantFlipperThread.Create(APolicy: TPWebCapabilityPolicy);
begin
  FPolicy := APolicy;
  inherited Create({suspended=}False);
end;

procedure TGrantFlipperThread.Go;
begin
  InterlockedExchange(FGo, 1);
end;

procedure TGrantFlipperThread.Stop;
begin
  InterlockedExchange(FStop, 1);
end;

function TGrantFlipperThread.Flips: Integer;
begin
  Result := PWebAtomicRead(FFlips);
end;

procedure TGrantFlipperThread.Execute;
var
  i: Integer;
begin
  // an exception raised here lands in FatalException, which the test
  // asserts nil - a raising flipper can never pass silently
  while PWebAtomicRead(FGo) = 0 do
    Sleep(1); // start barrier: no flip before the test is snapshotting
  i := 0;
  while PWebAtomicRead(FStop) = 0 do
  begin
    Inc(i);
    if (i and 1) = 0 then
      FPolicy.SetRuntimeGrants('window:main', ['settings.read'])
    else
      FPolicy.SetRuntimeGrants('window:main',
        ['settings.read', 'settings.write']);
    InterlockedIncrement(FFlips);
  end;
end;

procedure TTestCapabilityPolicy.ConcurrentGrantSafety;
const
  MIN_OBS = 200;       // both sides must perform at least this many ops
  TIMEOUT_MS = 10000;  // loud failure bound, never a hang
var
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  flipper: TGrantFlipperThread;
  snap: TPWebCapabilities;
  csv: Utf8String;
  snaps, coherent: Integer;
  deadline: Int64;
begin
  // A29: set/revoke/snapshot race-free under the lock - every snapshot
  // observed concurrently is one of the two coherent states, never a
  // torn mix, nothing crashes or deadlocks, and the OVERLAP is proven:
  // the flipper only runs between Go and Stop, so its flip counter
  // advancing past MIN_OBS while this thread snapshots means both
  // sides really interleaved inside the same window.
  p := nil;
  with TPWebCapabilityPolicyBuilder.Create do
  try
    SetAppMaximum(['settings.read', 'settings.write']);
    SetPrincipalCapabilities('window:main',
      ['settings.read', 'settings.write']);
    MapMethod('Settings.Get', ['settings.read']);
    p := Build;
  finally
    Free;
  end;
  pRef := p;
  p.SetRuntimeGrants('window:main', ['settings.read']);
  flipper := TGrantFlipperThread.Create(p);
  try
    flipper.Go;
    snaps := 0;
    coherent := 0;
    deadline := GetTickCount64 + TIMEOUT_MS;
    while ((snaps < MIN_OBS) or (flipper.Flips < MIN_OBS)) and
          (GetTickCount64 < deadline) do
    begin
      snap := p.SnapshotCapabilities('window:main');
      csv := CapsCsv(snap);
      Inc(snaps);
      if (csv = 'settings.read') or
         (csv = 'settings.read,settings.write') then
        Inc(coherent)
      else
        Check(False, 'A29 torn snapshot observed: ' + string(csv));
    end;
    flipper.Stop;
    flipper.WaitFor;
    Check(flipper.FatalException = nil, 'A29 flipper thread raised');
    CheckEqual(coherent, snaps, 'A29 every snapshot coherent');
    Check(snaps >= MIN_OBS, 'A29 snapshot side never reached MIN_OBS - no overlap proven');
    Check(flipper.Flips >= MIN_OBS, 'A29 flipper side never reached MIN_OBS - no overlap proven');
  finally
    flipper.Stop; // idempotent: never leave the loop running on a failure path
    flipper.WaitFor;
    flipper.Free;
  end;
  pRef := nil;
end;

{ ---------------- A31-A32 advisory / zero-cap ---------------- }

procedure TTestCapabilityPolicy.AdvisoryZeroCap;
var
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  ctx: TInvocationContext;
begin
  p := NewReferencePolicy;
  pRef := p;
  // A31: pweb.handshake is callable through its explicit zero-cap row
  // for every valid principal - including one whose effective set is
  // EMPTY - and the capability list it would advertise is advisory
  // only: holding the advertisement changes no decision
  ctx := Default(TInvocationContext);
  ctx.WindowId := 'other';
  ctx.PrincipalId := 'window:other';
  ctx.PrincipalKind := pkWindow;
  ctx.TrustedContent := True;
  ctx.Capabilities := p.SnapshotCapabilities('window:other', 'other');
  // 'window:other'/'other' have no static rows => unrestricted factors,
  // so the effective set is exactly AppMaximum - and STILL nothing
  // unmapped is callable
  Check(p.IsAllowed(ctx, PWEB_METHOD_HANDSHAKE), 'A31 handshake zero-cap');
  Check(not p.IsAllowed(ctx, 'Unmapped.Method'),
    'A31 advertised set grants nothing unmapped');
  ctx.Capabilities := nil; // empty effective set: handshake still works
  Check(p.IsAllowed(ctx, PWEB_METHOD_HANDSHAKE),
    'A31 handshake with empty effective set');
  // A32: pweb.echo zero-cap likewise; an UNKNOWN pweb.* method is
  // unmapped and denied here BEFORE the bridge's reserved-namespace 404
  // (forbidden outranks method_not_found through the production host)
  Check(p.IsAllowed(ctx, PWEB_METHOD_ECHO), 'A32 echo zero-cap');
  Check(not p.IsAllowed(ctx, 'pweb.unknown'), 'A32 unknown pweb.* denied');
  // context identity is still validated on zero-cap rows
  ctx.TrustedContent := False;
  Check(not p.IsAllowed(ctx, PWEB_METHOD_HANDSHAKE),
    'A32 zero-cap still validates context');
  pRef := nil;
end;

{ ---------------- A33-A35 deny envelope through the scheduler ------- }

procedure TTestCapabilityPolicy.DenyEnvelopeAndZeroBridge;
var
  p: TPWebCapabilityPolicy;
  bridge: TDummyInvocationBridge;
  bridgeRef: IInvocationBridge;
  scheduler: TInvocationScheduler;
  schedulerRef: IInvocationScheduler;
  source: IInvocationSource;
  sink: TTestCompletion;
  sinkRef: IInvocationCompletion;
  limits: TPWebSourceLimits;
  ctx: TInvocationContext;
begin
  // real scheduler + production policy + counting dummy bridge: every
  // deny is the canonical forbidden envelope with ZERO bridge activity
  p := nil;
  with TPWebCapabilityPolicyBuilder.Create do
  try
    SetAppMaximum(['demo.echo']);
    MapMethod(PWEB_METHOD_ECHO, ['demo.echo']);
    p := Build;
  finally
    Free;
  end;
  bridge := TDummyInvocationBridge.Create;
  bridgeRef := bridge;
  scheduler := TInvocationScheduler.Create(p, bridgeRef, 1);
  schedulerRef := scheduler;
  try
    limits.MaxConcurrent := 1;
    limits.MaxQueueSize := 8;
    source := scheduler.RegisterSource(limits);

    // A33: denied (capability not held) => canonical forbidden result:
    // code forbidden, default message, JSON-null data, status table 403
    ctx := TestContext; // no capabilities populated
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(ctx, PWEB_METHOD_ECHO, '{}',
      sinkRef) = perAccepted);
    if not sink.WaitDone(5000) then
    begin
      Check(False, 'A33 completion never arrived');
      exit;
    end;
    Check(sink.First.Kind = prkError, 'A33 error arm');
    Check(sink.First.Error.Code = pecForbidden, 'A33 forbidden');
    CheckEqual(sink.First.Error.Message,
      PWEB_DEFAULT_ERROR_MESSAGE[pecForbidden], 'A33 default message');
    CheckEqual(sink.First.Error.Data, PWEB_JSON_NULL, 'A33 null data');
    CheckEqual(PWEB_ERROR_STATUS[pecForbidden], 403, 'A33 status table');
    CheckEqual(PWEB_ERROR_CODE_TEXT[pecForbidden], 'forbidden',
      'A33 wire code text');
    CheckEqual(bridge.InvokeCount, 0, 'A33 zero bridge activity');

    // A34: unmapped method => forbidden BEFORE routing, zero bridge -
    // the dummy bridge would answer method_not_found, so a nonzero
    // count or a 404 here would prove the precedence broke
    ctx.Capabilities := PWebCapabilitySetOf(['demo.echo']);
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(ctx, 'test.fail', '{}',
      sinkRef) = perAccepted);
    if not sink.WaitDone(5000) then
    begin
      Check(False, 'A34 completion never arrived');
      exit;
    end;
    Check(sink.First.Error.Code = pecForbidden,
      'A34 forbidden outranks method_not_found');
    CheckEqual(bridge.InvokeCount, 0, 'A34 zero bridge activity');

    // the allowed counterpart proves the pipeline is live, not inert
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(ctx, PWEB_METHOD_ECHO, '{"k":1}',
      sinkRef) = perAccepted);
    if not sink.WaitDone(5000) then
    begin
      Check(False, 'A34 allowed completion never arrived');
      exit;
    end;
    Check(sink.First.Kind = prkSuccess, 'A34 allowed passes');
    CheckEqual(bridge.InvokeCount, 1, 'A34 exactly one bridge call');

    // A35: malformed context (empty PrincipalId passes the enqueue
    // gate, which cannot know principal semantics) => forbidden with
    // no exception text leaked and zero further bridge activity
    ctx := TestContext;
    ctx.PrincipalKind := pkSystem;
    ctx.WindowId := '';
    ctx.PrincipalId := '';
    ctx.Capabilities := PWebCapabilitySetOf(['demo.echo']);
    sink := TTestCompletion.Create;
    sinkRef := sink;
    Check(source.TryEnqueue(ctx, PWEB_METHOD_ECHO, '{}',
      sinkRef) = perAccepted);
    if not sink.WaitDone(5000) then
    begin
      Check(False, 'A35 completion never arrived');
      exit;
    end;
    Check(sink.First.Error.Code = pecForbidden, 'A35 forbidden');
    CheckEqual(sink.First.Error.Message,
      PWEB_DEFAULT_ERROR_MESSAGE[pecForbidden],
      'A35 no native detail in the message');
    CheckEqual(bridge.InvokeCount, 1, 'A35 zero additional bridge calls');
  finally
    scheduler.Shutdown;
    source := nil;
    sinkRef := nil;
    schedulerRef := nil;
    bridgeRef := nil;
  end;
end;

{ ---------------- the CAP-7F decision corpus ---------------- }

procedure TTestCapabilityPolicy.DecisionDigest;
var
  p: TPWebCapabilityPolicy;
  pRef: ICapabilityPolicy;
  lines: Utf8String;
  allPass: Boolean;
  stream: TFileStream;
  root, digestFile: TFileName;
  appmaxCsv: Utf8String;
  ctxMain, ctxLogin, ctxPlugin, ctx: TInvocationContext;

  procedure Emit(const ALine: Utf8String);
  begin
    lines := lines + ALine + #10; // LF only - the digest crosses OSes
  end;

  procedure Probe(const ALabel: Utf8String; const ACtx: TInvocationContext;
    const AMethod: Utf8String; AExpected: Boolean);
  var
    got: Boolean;
  begin
    got := p.IsAllowed(ACtx, AMethod);
    Emit('decision ctx=' + ALabel + ' method=' + AMethod +
      ' allow=' + Utf8String(IntToStr(Ord(got))));
    if got <> AExpected then
      allPass := False;
    Check(got = AExpected, 'digest probe ' + string(ALabel) + ' ' +
      string(AMethod));
  end;

begin
  // The canonical policy-decision corpus: every line is a pure decision
  // of the reference configuration, so the file bytes - and therefore
  // the sha256 the CAP-7F emitters record as capability_policy_digest -
  // are identical on all four targets by construction.
  p := NewReferencePolicy;
  pRef := p;
  lines := '';
  allPass := True;
  Emit('schema=1');
  // the appmax= line comes from the configured ceiling CONSTANT, never
  // from a snapshot of some incidentally unconfigured principal; the
  // cross-check below pins that an unconfigured principal with no
  // window does resolve to exactly that ceiling (so a future config
  // row for the probe id would fail loudly here instead of silently
  // changing what the corpus line means)
  appmaxCsv := CapsCsv(PWebCapabilitySetOf(PWEB_CAP8A_REF_APPMAX));
  Emit('appmax=' + appmaxCsv);
  CheckEqual(CapsCsv(p.SnapshotCapabilities('appmax.probe')), appmaxCsv,
    'unconfigured principal must resolve to the configured ceiling');
  ctxMain := RefContextMain(p);
  ctxLogin := RefContextLogin(p);
  ctxPlugin := RefContextPlugin(p);
  Emit('snapshot principal=window:main window=main caps=' +
    CapsCsv(ctxMain.Capabilities));
  Emit('snapshot principal=window:login window=login caps=' +
    CapsCsv(ctxLogin.Capabilities));
  Emit('snapshot principal=plugin:reporting window= caps=' +
    CapsCsv(ctxPlugin.Capabilities));
  Probe('main', ctxMain, 'CalculatorService.Add', True);
  Probe('login', ctxLogin, 'CalculatorService.Add', False);
  Probe('plugin', ctxPlugin, 'CalculatorService.Add', False);
  Probe('main', ctxMain, 'SettingsService.GetValue', True);
  Probe('main', ctxMain, 'SettingsService.SetValue', True);
  Probe('login', ctxLogin, 'SettingsService.GetValue', True);
  Probe('login', ctxLogin, 'SettingsService.SetValue', False);
  Probe('plugin', ctxPlugin, 'ParkingService.List', True);
  Probe('plugin', ctxPlugin, 'ParkingService.Reserve', False);
  Probe('main', ctxMain, 'SettingsService.Purge', False);
  Probe('main', ctxMain, 'GhostService.Ping', True);
  Probe('main', ctxMain, 'pweb.handshake', True);
  Probe('main', ctxMain, 'pweb.echo', True);
  Probe('main', ctxMain, 'pweb.unknown', False);
  ctx := ctxMain;
  ctx.TrustedContent := False;
  Probe('main-untrusted', ctx, 'CalculatorService.Add', False);
  ctx := ctxMain;
  ctx.PrincipalId := '';
  Probe('empty-principal', ctx, 'CalculatorService.Add', False);
  if allPass then
    Emit('verdict=PASS')
  else
    Emit('verdict=FAIL');
  // TSynTests runs every case with the CURRENT DIRECTORY set to the
  // executable's folder (mormot.core.test WorkDir), which differs per
  // target (build/test, build/cap7l/bin, build/cap7m/bin) - so the file
  // is anchored to the REPOSITORY ROOT, found by walking up from the
  // executable to the webview.lock marker, exactly where the CAP-7F
  // emitters look. The path itself is derived from the ONE
  // PWEB_CAP8A_DIGEST_FILE constant. LF, no BOM: the aggregator
  // compares byte digests across OSes. A missing root marker is a
  // LOUD failure, never a silent CWD-relative write the emitters
  // would then miss.
  root := RepoRootFromExecutable;
  if root = '' then
  begin
    Check(False, 'repository root (webview.lock marker) not found from ' +
      string(Executable.ProgramFilePath) +
      ' - refusing to write the digest corpus at an ambiguous location');
    pRef := nil;
    exit;
  end;
  digestFile := root + TFileName(StringReplace(PWEB_CAP8A_DIGEST_FILE,
    '/', PathDelim, [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(digestFile)) then
    Check(False, 'unable to create ' + string(ExtractFilePath(digestFile)))
  else
  begin
    stream := TFileStream.Create(digestFile, fmCreate);
    try
      if lines <> '' then
        stream.WriteBuffer(lines[1], Length(lines));
    finally
      stream.Free;
    end;
  end;
  pRef := nil;
end;

end.
