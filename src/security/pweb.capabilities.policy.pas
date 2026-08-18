{
  pweb.capabilities.policy - the production contextual capability engine
  (Phase 8 / CAP-8A).

  Implements the ratified contextual model of security-model.md behind
  the FROZEN ICapabilityPolicy contract:

    Effective = AppMaximum
              INTERSECT PrincipalCapabilities
              INTERSECT WindowCapabilities
              INTERSECT RuntimeGrants

  Division of labour, ratified at CAP-8A Checkpoint 1 (D1):
    - SnapshotCapabilities computes the per-invocation EFFECTIVE set for
      NATIVE context construction (the host's binding-side wrapper calls
      it per invocation and places the result in Context.Capabilities);
    - IsAllowed then recomputes `required SUBSETOF AppMaximum INTERSECT
      Context.Capabilities` as defense in depth - the ceiling is applied
      twice on purpose, so a host that forgets to snapshot can only ever
      be MORE restrictive, never less.

  Intersection defaults (security-model.md DECIDED):
    - an ABSENT optional factor means unrestricted (no additional
      restriction);
    - an EXPLICITLY configured EMPTY set means no rights;
    - AppMaximum is mandatory and explicit - Build refuses without it.
  Context.Capabilities is an INPUT, not a config factor: a nil/empty
  array there means the principal holds nothing (only zero-capability
  methods pass) - it is never read as "unrestricted", which would fail
  open.

  Capability grammar (security-model.md; bound ratified as D2):
  [a-z0-9]+(\.[a-z0-9]+)*, at most PWEB_CAPABILITY_MAX_BYTES bytes,
  compared exactly - no wildcards, no regex, no implicit inheritance.

  Configuration comes ONLY from native Pascal builder code in the host -
  never from app.pwb, a manifest file, JS, the environment or any policy
  file format. The builder validates every row at the call site and
  Build re-validates the whole; EPWebCapabilityConfig aborts atomically,
  so no partially valid policy can ever exist (the host fails to start).

  Fail-closed rules (ratified): unknown/unmapped method => deny; empty
  PrincipalId => deny; a pkWindow context with an empty WindowId or with
  TrustedContent=False => deny; a pkPlugin context with an empty
  PluginId => deny (D5/D6). IsAllowed never raises on any input; the
  scheduler's frozen call-site barrier (exception => deny =>
  internal_error) stays the last line, not the first.

  Thread affinity: IsAllowed is called concurrently on worker threads
  and reads only immutable post-Build state - no lock. The runtime-grant
  store is guarded by one critical section; SnapshotCapabilities copies
  on read, so a returned array is never shared with mutable state.

  RTL-only by ratified constraint: no mORMot, no webview unit, no
  platform identifier, no platform conditional (this unit is on the
  CAP-7F zero-conditional core list). TAllowAllCapabilityPolicy in the
  frozen pweb.capabilities unit remains byte-identical and in use by the
  earlier-phase examples; this unit is the Phase-8 swap-in.
}
unit pweb.capabilities.policy;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Classes,
  SyncObjs,
  pweb.rpc.intf,
  pweb.rpc.support;

const
  { Upper bound of one capability identifier, in bytes (ratified D2).
    The grammar mandates a bound so no unbounded attacker-influenced
    string ever reaches the comparison loops. }
  PWEB_CAPABILITY_MAX_BYTES = 128;

type
  /// raised by the builder (and only by the builder) on any malformed,
  // duplicate or contradictory configuration row - construction fails
  // atomically and the host fails to start
  EPWebCapabilityConfig = class(Exception);

  /// one optional intersection factor with the ratified absent-vs-empty
  // distinction made explicit in the representation:
  // - Present=False : factor absent/unconfigured = unrestricted
  // - Present=True  : Caps is the explicit set; empty = no rights
  TPWebCapabilityFactor = record
    Present: Boolean;
    Caps: TPWebCapabilities; // canonical (byte-sorted, unique); valid iff Present
  end;

/// exact capability-identifier grammar predicate (D2):
// [a-z0-9]+(\.[a-z0-9]+)*, 1..PWEB_CAPABILITY_MAX_BYTES bytes
function PWebValidCapability(const ACapability: Utf8String): Boolean;

/// canonical set constructor: validates every identifier against the
// grammar, refuses duplicates, returns a byte-sorted unique deep copy.
// Raises EPWebCapabilityConfig on any violation - this is the one
// entrance through which configuration capability lists are admitted.
function PWebCapabilitySetOf(
  const ACaps: array of Utf8String): TPWebCapabilities;

/// exact membership over a CANONICAL (sorted unique) set
function PWebCapabilityIn(const ASet: TPWebCapabilities;
  const ACapability: Utf8String): Boolean;

/// exact intersection of two canonical sets (result is canonical)
function PWebCapabilityIntersect(
  const A, B: TPWebCapabilities): TPWebCapabilities;

/// the absent factor (unrestricted)
function PWebFactorAbsent: TPWebCapabilityFactor;

/// an explicit factor from a raw list (validated via PWebCapabilitySetOf;
// an empty list is the ratified explicit-empty = no rights)
function PWebFactorOf(
  const ACaps: array of Utf8String): TPWebCapabilityFactor;

/// factor intersection under the ratified defaults: absent is the
// neutral element; two explicit sets intersect exactly
function PWebFactorIntersect(
  const A, B: TPWebCapabilityFactor): TPWebCapabilityFactor;

type
  TPWebCapabilityPolicy = class;

  /// native Pascal configuration builder - the ONLY way to construct a
  // production policy. Every setter validates at the call site; Build
  // re-validates the whole and raises EPWebCapabilityConfig atomically,
  // so a policy either exists complete and valid or not at all.
  // The builder stays usable after Build (each Build yields a fresh
  // immutable policy from the state at that moment).
  TPWebCapabilityPolicyBuilder = class
  private
    FAppMaximum: TPWebCapabilityFactor;
    FPrincipalNames: array of Utf8String; // parallel to FPrincipalCaps
    FPrincipalCaps: array of TPWebCapabilities;
    FWindowNames: array of Utf8String;    // parallel to FWindowCaps
    FWindowCaps: array of TPWebCapabilities;
    FMethods: array of Utf8String;        // parallel to FRequired
    FRequired: array of TPWebCapabilities; // empty = explicit zero-cap row
    function MethodIndex(const AMethod: Utf8String): Integer;
    procedure AddMethodRow(const AMethod: Utf8String;
      const ARequired: TPWebCapabilities);
  public
    { The mandatory explicit ceiling. Exactly one call; an explicitly
      empty ceiling is legal (an app with no capabilities - only
      zero-cap methods can then be mapped). }
    procedure SetAppMaximum(const ACaps: array of Utf8String);

    { Explicit static set of one principal id. At most one row per id;
      an empty list is the explicit-empty = no rights; an id never
      configured stays an absent factor = unrestricted. }
    procedure SetPrincipalCapabilities(const APrincipalId: Utf8String;
      const ACaps: array of Utf8String);

    { Explicit static set of one window id - same rules as principals. }
    procedure SetWindowCapabilities(const AWindowId: Utf8String;
      const ACaps: array of Utf8String);

    { Map one canonical Service.Method to its required capability set
      (all-of). The set must be non-empty here: an explicitly
      capability-free method is registered through
      RegisterZeroCapMethod so an empty list can never be an accident. }
    procedure MapMethod(const AMethod: Utf8String;
      const ARequired: array of Utf8String);

    { Explicit zero-capability registration: the method is KNOWN and
      requires no capability (context identity is still validated at
      IsAllowed). Distinct, by design, from an unmapped method, which
      is always denied. }
    procedure RegisterZeroCapMethod(const AMethod: Utf8String);

    { Validate the whole configuration and produce the immutable
      policy. Raises EPWebCapabilityConfig when AppMaximum was never
      set, or when any mapped row requires a capability outside
      AppMaximum (a contradictory row that could never be satisfied -
      almost always a typo, refused loudly at startup). }
    function Build: TPWebCapabilityPolicy;
  end;

  /// the immutable production ICapabilityPolicy (build via the builder
  // above; a directly constructed instance is a safe deny-everything
  // policy with no configuration). Also carries the thread-safe
  // runtime-grant store and the SnapshotCapabilities entry point the
  // host uses for native context construction (D1/D9).
  TPWebCapabilityPolicy = class(TInterfacedObject, ICapabilityPolicy)
  private
    // immutable after Build - read lock-free by worker threads
    FAppMaximum: TPWebCapabilities;
    FPrincipalNames: array of Utf8String;
    FPrincipalCaps: array of TPWebCapabilities;
    FWindowNames: array of Utf8String;
    FWindowCaps: array of TPWebCapabilities;
    FMethods: array of Utf8String;
    FRequired: array of TPWebCapabilities;
    // mutable runtime-grant store, guarded by FGrantLock
    FGrantLock: TCriticalSection;
    FGrantNames: array of Utf8String;
    FGrantCaps: array of TPWebCapabilities;
    function MethodIndex(const AMethod: Utf8String): Integer;
    function GrantIndex(const APrincipalId: Utf8String): Integer;
    function StaticFactor(const ANames: array of Utf8String;
      const ASets: array of TPWebCapabilities;
      const AName: Utf8String): TPWebCapabilityFactor;
    function GrantFactorLocked(
      const APrincipalId: Utf8String): TPWebCapabilityFactor;
  public
    constructor Create;
    destructor Destroy; override;

    // ICapabilityPolicy (frozen): never raises, fails closed on every
    // malformed input; called concurrently on worker threads
    function IsAllowed(const Context: TInvocationContext;
      const Method: Utf8String): Boolean;

    { The per-invocation effective snapshot for native context
      construction (D1): AppMaximum INTERSECT Principal INTERSECT
      Window INTERSECT RuntimeGrants, copy-on-read. AWindowId = ''
      means the window factor is not applicable (absent). An empty
      APrincipalId is a host defect and yields the empty set - fail
      closed, never unrestricted. }
    function SnapshotCapabilities(const APrincipalId: Utf8String;
      const AWindowId: Utf8String = ''): TPWebCapabilities;

    { Replace the runtime-grant factor of one principal with an
      explicit set (empty = explicit no rights). Grants are an
      INTERSECTION factor: they can only ever narrow the static
      configuration, never widen it. Raises EPWebCapabilityConfig on
      an empty principal id, an invalid/duplicate capability, or a
      capability OUTSIDE AppMaximum - the same contradictory-row
      refusal the builder applies to mapping rows: an out-of-ceiling
      grant could never take effect, so accepting it silently would
      only hide a host typo. Native misuse is loud. }
    procedure SetRuntimeGrants(const APrincipalId: Utf8String;
      const ACaps: array of Utf8String);

    { Remove one capability from the principal's grant factor. If the
      principal had NO explicit grant entry (absent = unrestricted),
      the entry becomes the explicit EMPTY set: revoking from an
      unrestricted factor cannot be represented as "everything minus
      one", so it fails closed to nothing - documented, deterministic. }
    procedure RevokeRuntimeGrant(const APrincipalId: Utf8String;
      const ACapability: Utf8String);

    { Remove the principal's grant entry entirely - back to the absent
      factor (unrestricted, i.e. the static configuration alone). }
    procedure ClearRuntimeGrants(const APrincipalId: Utf8String);
  end;

implementation

{ ---------------- grammar ---------------- }

function PWebValidCapability(const ACapability: Utf8String): Boolean;
var
  i, len: Integer;
  prevDot: Boolean;
  c: AnsiChar;
begin
  Result := False;
  len := Length(ACapability);
  if (len < 1) or (len > PWEB_CAPABILITY_MAX_BYTES) then
    exit;
  prevDot := True; // a leading dot must fail like an empty segment
  for i := 1 to len do
  begin
    c := AnsiChar(ACapability[i]);
    if c = '.' then
    begin
      if prevDot then
        exit; // empty segment ('..' or leading '.')
      prevDot := True;
    end
    else if c in ['a'..'z', '0'..'9'] then
      prevDot := False
    else
      exit; // uppercase, underscore, space, NUL, non-ASCII... - refused
  end;
  if prevDot then
    exit; // trailing dot
  Result := True;
end;

{ ---------------- canonical sets ---------------- }

function CopyCaps(const ACaps: TPWebCapabilities): TPWebCapabilities;
var
  i: Integer;
begin
  Result := Copy(ACaps);
  for i := 0 to High(Result) do
    UniqueString(Result[i]); // the copy shares no heap with the source
end;

function PWebCapabilitySetOf(
  const ACaps: array of Utf8String): TPWebCapabilities;
var
  i, j: Integer;
  cap: Utf8String;
begin
  Result := nil; // explicit: SetLength must never see caller garbage
  SetLength(Result, Length(ACaps));
  for i := 0 to High(ACaps) do
  begin
    cap := ACaps[i];
    if not PWebValidCapability(cap) then
      raise EPWebCapabilityConfig.CreateFmt(
        'invalid capability identifier: "%s"', [cap]);
    UniqueString(cap);
    // byte-wise insertion sort; an equal neighbour is a duplicate row
    j := i - 1;
    while (j >= 0) and (Result[j] > cap) do
    begin
      Result[j + 1] := Result[j];
      Dec(j);
    end;
    if (j >= 0) and (Result[j] = cap) then
      raise EPWebCapabilityConfig.CreateFmt(
        'duplicate capability in set: "%s"', [cap]);
    Result[j + 1] := cap;
  end;
end;

function PWebCapabilityIn(const ASet: TPWebCapabilities;
  const ACapability: Utf8String): Boolean;
var
  lo, hi, mid: Integer;
begin
  // binary search over the canonical byte order - exact compare only
  lo := 0;
  hi := High(ASet);
  while lo <= hi do
  begin
    mid := (lo + hi) div 2;
    if ASet[mid] = ACapability then
      exit(True);
    if ASet[mid] < ACapability then
      lo := mid + 1
    else
      hi := mid - 1;
  end;
  Result := False;
end;

function PWebCapabilityIntersect(
  const A, B: TPWebCapabilities): TPWebCapabilities;
var
  ia, ib, n: Integer;
begin
  Result := nil;
  // pre-sized to the upper bound, trimmed once at the end - no
  // per-element reallocation
  if Length(A) < Length(B) then
    SetLength(Result, Length(A))
  else
    SetLength(Result, Length(B));
  ia := 0;
  ib := 0;
  n := 0;
  while (ia <= High(A)) and (ib <= High(B)) do
    if A[ia] = B[ib] then
    begin
      Result[n] := A[ia];
      UniqueString(Result[n]);
      Inc(n);
      Inc(ia);
      Inc(ib);
    end
    else if A[ia] < B[ib] then
      Inc(ia)
    else
      Inc(ib);
  SetLength(Result, n); // trim to the actual intersection size
end;

function PWebFactorAbsent: TPWebCapabilityFactor;
begin
  Result.Present := False;
  Result.Caps := nil;
end;

function PWebFactorOf(
  const ACaps: array of Utf8String): TPWebCapabilityFactor;
begin
  Result.Present := True;
  Result.Caps := PWebCapabilitySetOf(ACaps);
end;

function PWebFactorIntersect(
  const A, B: TPWebCapabilityFactor): TPWebCapabilityFactor;
begin
  if not A.Present then
  begin
    Result.Present := B.Present;
    Result.Caps := CopyCaps(B.Caps);
    exit;
  end;
  if not B.Present then
  begin
    Result.Present := True;
    Result.Caps := CopyCaps(A.Caps);
    exit;
  end;
  Result.Present := True;
  Result.Caps := PWebCapabilityIntersect(A.Caps, B.Caps);
end;

{ ---------------- TPWebCapabilityPolicyBuilder ---------------- }

function NameIndexOf(const ANames: array of Utf8String;
  const AName: Utf8String): Integer;
begin
  for Result := 0 to High(ANames) do
    if ANames[Result] = AName then
      exit;
  Result := -1;
end;

procedure TPWebCapabilityPolicyBuilder.SetAppMaximum(
  const ACaps: array of Utf8String);
begin
  if FAppMaximum.Present then
    raise EPWebCapabilityConfig.Create(
      'AppMaximum was already configured - one explicit ceiling only');
  FAppMaximum.Caps := PWebCapabilitySetOf(ACaps); // validates first
  FAppMaximum.Present := True;
end;

procedure TPWebCapabilityPolicyBuilder.SetPrincipalCapabilities(
  const APrincipalId: Utf8String; const ACaps: array of Utf8String);
var
  n: Integer;
  id: Utf8String;
begin
  if APrincipalId = '' then
    raise EPWebCapabilityConfig.Create(
      'a principal capability row requires a non-empty principal id');
  if NameIndexOf(FPrincipalNames, APrincipalId) >= 0 then
    raise EPWebCapabilityConfig.CreateFmt(
      'duplicate principal capability row: "%s"', [APrincipalId]);
  id := APrincipalId;
  UniqueString(id);
  n := Length(FPrincipalNames);
  SetLength(FPrincipalNames, n + 1);
  SetLength(FPrincipalCaps, n + 1);
  FPrincipalNames[n] := id;
  FPrincipalCaps[n] := PWebCapabilitySetOf(ACaps);
end;

procedure TPWebCapabilityPolicyBuilder.SetWindowCapabilities(
  const AWindowId: Utf8String; const ACaps: array of Utf8String);
var
  n: Integer;
  id: Utf8String;
begin
  if AWindowId = '' then
    raise EPWebCapabilityConfig.Create(
      'a window capability row requires a non-empty window id');
  if NameIndexOf(FWindowNames, AWindowId) >= 0 then
    raise EPWebCapabilityConfig.CreateFmt(
      'duplicate window capability row: "%s"', [AWindowId]);
  id := AWindowId;
  UniqueString(id);
  n := Length(FWindowNames);
  SetLength(FWindowNames, n + 1);
  SetLength(FWindowCaps, n + 1);
  FWindowNames[n] := id;
  FWindowCaps[n] := PWebCapabilitySetOf(ACaps);
end;

function TPWebCapabilityPolicyBuilder.MethodIndex(
  const AMethod: Utf8String): Integer;
begin
  Result := NameIndexOf(FMethods, AMethod);
end;

procedure TPWebCapabilityPolicyBuilder.AddMethodRow(
  const AMethod: Utf8String; const ARequired: TPWebCapabilities);
var
  n: Integer;
  m: Utf8String;
begin
  if not PWebValidMethod(AMethod) then
    raise EPWebCapabilityConfig.CreateFmt(
      'mapping row refuses non-canonical method: "%s"', [AMethod]);
  if MethodIndex(AMethod) >= 0 then
    raise EPWebCapabilityConfig.CreateFmt(
      'duplicate mapping row for method: "%s"', [AMethod]);
  m := AMethod;
  UniqueString(m);
  n := Length(FMethods);
  SetLength(FMethods, n + 1);
  SetLength(FRequired, n + 1);
  FMethods[n] := m;
  FRequired[n] := ARequired;
end;

procedure TPWebCapabilityPolicyBuilder.MapMethod(const AMethod: Utf8String;
  const ARequired: array of Utf8String);
begin
  if Length(ARequired) = 0 then
    raise EPWebCapabilityConfig.CreateFmt(
      'MapMethod("%s") with no capability - an explicitly ' +
      'capability-free method goes through RegisterZeroCapMethod',
      [AMethod]);
  AddMethodRow(AMethod, PWebCapabilitySetOf(ARequired));
end;

procedure TPWebCapabilityPolicyBuilder.RegisterZeroCapMethod(
  const AMethod: Utf8String);
begin
  AddMethodRow(AMethod, nil);
end;

function TPWebCapabilityPolicyBuilder.Build: TPWebCapabilityPolicy;
var
  i, j: Integer;
begin
  if not FAppMaximum.Present then
    raise EPWebCapabilityConfig.Create(
      'AppMaximum was never configured - an app without an explicit ' +
      'ceiling has no capabilities (security-model.md)');
  // contradictory-row check: a required capability outside the ceiling
  // could never be satisfied; refusing it at startup catches the typo
  for i := 0 to High(FMethods) do
    for j := 0 to High(FRequired[i]) do
      if not PWebCapabilityIn(FAppMaximum.Caps, FRequired[i][j]) then
        raise EPWebCapabilityConfig.CreateFmt(
          'contradictory row: method "%s" requires "%s", which is ' +
          'outside AppMaximum', [FMethods[i], FRequired[i][j]]);
  Result := TPWebCapabilityPolicy.Create;
  try
    // deep copies: the policy is immutable however the builder mutates
    Result.FAppMaximum := CopyCaps(FAppMaximum.Caps);
    SetLength(Result.FPrincipalNames, Length(FPrincipalNames));
    SetLength(Result.FPrincipalCaps, Length(FPrincipalCaps));
    for i := 0 to High(FPrincipalNames) do
    begin
      Result.FPrincipalNames[i] := FPrincipalNames[i];
      UniqueString(Result.FPrincipalNames[i]);
      Result.FPrincipalCaps[i] := CopyCaps(FPrincipalCaps[i]);
    end;
    SetLength(Result.FWindowNames, Length(FWindowNames));
    SetLength(Result.FWindowCaps, Length(FWindowCaps));
    for i := 0 to High(FWindowNames) do
    begin
      Result.FWindowNames[i] := FWindowNames[i];
      UniqueString(Result.FWindowNames[i]);
      Result.FWindowCaps[i] := CopyCaps(FWindowCaps[i]);
    end;
    SetLength(Result.FMethods, Length(FMethods));
    SetLength(Result.FRequired, Length(FRequired));
    for i := 0 to High(FMethods) do
    begin
      Result.FMethods[i] := FMethods[i];
      UniqueString(Result.FMethods[i]);
      Result.FRequired[i] := CopyCaps(FRequired[i]);
    end;
  except
    Result.Free;
    raise;
  end;
end;

{ ---------------- TPWebCapabilityPolicy ---------------- }

constructor TPWebCapabilityPolicy.Create;
begin
  inherited Create;
  FGrantLock := TCriticalSection.Create;
  // a raw instance has no AppMaximum, no rows: IsAllowed denies
  // everything and SnapshotCapabilities yields the empty set - a
  // misused constructor fails closed, never open
end;

destructor TPWebCapabilityPolicy.Destroy;
begin
  FGrantLock.Free;
  inherited Destroy;
end;

function TPWebCapabilityPolicy.MethodIndex(
  const AMethod: Utf8String): Integer;
begin
  Result := NameIndexOf(FMethods, AMethod);
end;

function TPWebCapabilityPolicy.GrantIndex(
  const APrincipalId: Utf8String): Integer;
begin
  Result := NameIndexOf(FGrantNames, APrincipalId);
end;

function TPWebCapabilityPolicy.StaticFactor(
  const ANames: array of Utf8String;
  const ASets: array of TPWebCapabilities;
  const AName: Utf8String): TPWebCapabilityFactor;
var
  i: Integer;
begin
  i := NameIndexOf(ANames, AName);
  if i < 0 then
    Result := PWebFactorAbsent // unconfigured = unrestricted
  else
  begin
    Result.Present := True;
    Result.Caps := ASets[i]; // immutable; callers never hand it out raw
  end;
end;

function TPWebCapabilityPolicy.GrantFactorLocked(
  const APrincipalId: Utf8String): TPWebCapabilityFactor;
var
  i: Integer;
begin
  i := GrantIndex(APrincipalId);
  if i < 0 then
    Result := PWebFactorAbsent
  else
  begin
    Result.Present := True;
    Result.Caps := CopyCaps(FGrantCaps[i]); // copy-on-read under the lock
  end;
end;

function TPWebCapabilityPolicy.IsAllowed(const Context: TInvocationContext;
  const Method: Utf8String): Boolean;
var
  row, i: Integer;
  cap: Utf8String;
  held: Boolean;
  j: Integer;
begin
  Result := False;
  // D5/D6 context-identity checks, re-done here as defense in depth
  // (the enqueue gate validates less: it does not know PrincipalId or
  // TrustedContent semantics)
  if Context.PrincipalId = '' then
    exit;
  case Context.PrincipalKind of
    pkWindow:
      if (Context.WindowId = '') or not Context.TrustedContent then
        exit; // externally navigated content never holds the bridge
    pkPlugin:
      if Context.PluginId = '' then
        exit;
    pkSystem, pkQuickJS:
      ; // no extra identity fields for these principals
  else
    exit; // out-of-range/unknown principal-kind ordinal: fail closed -
          // a future enum member gets identity rules here BEFORE it can
          // ever be authorized, never silently waved through
  end;
  row := MethodIndex(Method);
  if row < 0 then
    exit; // unknown/unmapped => deny, fail closed, always
  // all-of: required SUBSETOF AppMaximum INTERSECT Context.Capabilities.
  // Context.Capabilities is the input effective set (unsorted, linear
  // exact scan); AppMaximum is re-applied on purpose (D1 defense in
  // depth). A zero-cap row passes vacuously - context was validated.
  for i := 0 to High(FRequired[row]) do
  begin
    cap := FRequired[row][i];
    if not PWebCapabilityIn(FAppMaximum, cap) then
      exit;
    held := False;
    for j := 0 to High(Context.Capabilities) do
      if Context.Capabilities[j] = cap then
      begin
        held := True;
        break;
      end;
    if not held then
      exit;
  end;
  Result := True;
end;

function TPWebCapabilityPolicy.SnapshotCapabilities(
  const APrincipalId: Utf8String;
  const AWindowId: Utf8String): TPWebCapabilities;
var
  factor: TPWebCapabilityFactor;
  grants: TPWebCapabilityFactor;
begin
  if APrincipalId = '' then
    exit(nil); // host defect: fail closed to the empty set, never open
  // AppMaximum is the mandatory explicit base of the intersection
  factor.Present := True;
  factor.Caps := FAppMaximum;
  factor := PWebFactorIntersect(factor,
    StaticFactor(FPrincipalNames, FPrincipalCaps, APrincipalId));
  if AWindowId <> '' then
    factor := PWebFactorIntersect(factor,
      StaticFactor(FWindowNames, FWindowCaps, AWindowId));
  FGrantLock.Enter;
  try
    grants := GrantFactorLocked(APrincipalId);
  finally
    FGrantLock.Leave;
  end;
  factor := PWebFactorIntersect(factor, grants);
  Result := CopyCaps(factor.Caps); // fresh array per invocation snapshot
end;

procedure TPWebCapabilityPolicy.SetRuntimeGrants(
  const APrincipalId: Utf8String; const ACaps: array of Utf8String);
var
  caps: TPWebCapabilities;
  i, n: Integer;
  id: Utf8String;
begin
  if APrincipalId = '' then
    raise EPWebCapabilityConfig.Create(
      'SetRuntimeGrants requires a non-empty principal id');
  caps := PWebCapabilitySetOf(ACaps); // validates BEFORE taking the lock
  // the builder's contradictory-row refusal, applied to grants too: an
  // out-of-ceiling grant is inert by construction (intersection), so
  // accepting it silently would only hide a host typo
  for i := 0 to High(caps) do
    if not PWebCapabilityIn(FAppMaximum, caps[i]) then
      raise EPWebCapabilityConfig.CreateFmt(
        'SetRuntimeGrants refuses "%s": outside AppMaximum', [caps[i]]);
  FGrantLock.Enter;
  try
    i := GrantIndex(APrincipalId);
    if i >= 0 then
      FGrantCaps[i] := caps
    else
    begin
      id := APrincipalId;
      UniqueString(id);
      n := Length(FGrantNames);
      SetLength(FGrantNames, n + 1);
      SetLength(FGrantCaps, n + 1);
      FGrantNames[n] := id;
      FGrantCaps[n] := caps;
    end;
  finally
    FGrantLock.Leave;
  end;
end;

procedure TPWebCapabilityPolicy.RevokeRuntimeGrant(
  const APrincipalId: Utf8String; const ACapability: Utf8String);
var
  i, j, k, n: Integer;
  caps: TPWebCapabilities;
  id: Utf8String;
begin
  if APrincipalId = '' then
    raise EPWebCapabilityConfig.Create(
      'RevokeRuntimeGrant requires a non-empty principal id');
  if not PWebValidCapability(ACapability) then
    raise EPWebCapabilityConfig.CreateFmt(
      'RevokeRuntimeGrant refuses invalid capability: "%s"',
      [ACapability]);
  FGrantLock.Enter;
  try
    i := GrantIndex(APrincipalId);
    if i < 0 then
    begin
      // revoking from an ABSENT (unrestricted) factor: "everything
      // minus one" is unrepresentable, so the factor becomes the
      // explicit EMPTY set - fail closed (see the declaration comment)
      id := APrincipalId;
      UniqueString(id);
      n := Length(FGrantNames);
      SetLength(FGrantNames, n + 1);
      SetLength(FGrantCaps, n + 1);
      FGrantNames[n] := id;
      FGrantCaps[n] := nil;
      exit;
    end;
    if not PWebCapabilityIn(FGrantCaps[i], ACapability) then
      exit; // nothing to remove; the set is already without it
    SetLength(caps, Length(FGrantCaps[i]) - 1);
    k := 0;
    for j := 0 to High(FGrantCaps[i]) do
      if FGrantCaps[i][j] <> ACapability then
      begin
        caps[k] := FGrantCaps[i][j];
        Inc(k);
      end;
    FGrantCaps[i] := caps; // still canonical: removal keeps the order
  finally
    FGrantLock.Leave;
  end;
end;

procedure TPWebCapabilityPolicy.ClearRuntimeGrants(
  const APrincipalId: Utf8String);
var
  i, j: Integer;
begin
  if APrincipalId = '' then
    raise EPWebCapabilityConfig.Create(
      'ClearRuntimeGrants requires a non-empty principal id');
  FGrantLock.Enter;
  try
    i := GrantIndex(APrincipalId);
    if i < 0 then
      exit; // already absent = unrestricted
    for j := i to High(FGrantNames) - 1 do
    begin
      FGrantNames[j] := FGrantNames[j + 1];
      FGrantCaps[j] := FGrantCaps[j + 1];
    end;
    SetLength(FGrantNames, Length(FGrantNames) - 1);
    SetLength(FGrantCaps, Length(FGrantCaps) - 1);
  finally
    FGrantLock.Leave;
  end;
end;

end.
