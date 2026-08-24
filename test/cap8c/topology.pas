program topology;

{ CAP-8C Phase A: the multi-WebView topology probe.

  MEASUREMENT ONLY - this host gates nothing and no verdict it prints is
  policy. It exists because the CAP-8C spec forbids designing the
  multi-principal production harness on suspicion: whether one pinned engine
  can hold TWO simultaneously live WebViews in one process is an UNKNOWN
  fact per target (the global GetMessage/gtk_main/NSApp loops upstream uses
  are suspicion, not evidence), and Checkpoint 1 presents what was MEASURED,
  through the frozen 17-export public ABI only - no upstream patch, no new
  export, no engine internals.

  WHAT IT MEASURES, per target, as recorded facts (never inferred):
    1. can a second WebView be created before the loop runs?
    2. are both views live concurrently (both pages load and complete a
       full JS->native->JS round trip) while ONE webview_run pumps?
    3. which instance owns webview_run - i.e. does running the first
       instance's loop serve the second instance's events?
    4. does "closing one" stop the loop - measured BOTH ways: a
       webview_terminate on the second instance, then a webview_destroy of
       the second instance while the loop runs;
    5. is binding userdata independent per instance (same bound name on
       both views, distinct arg pointers, every callback receives the exact
       pointer registered on ITS view)?
    6. does each handler receive only its own view's payloads (the payload
       self-declares its view tag; a tag arriving on the other slot is a
       cross delivery)?
    7. can invocations be outstanding on both views at the same time (two
       unresolved binding calls held natively, then both resolved)?
    8. is the surviving view still functional after the other is closed
       (an eval round trip on the survivor)?

  ROBUSTNESS RULES, because a crash IS a result on a measurement probe:
  the facts JSON (build/cap8c/topology-<target>.json) is rewritten after
  every recorded event, and a crash_guard field names the step in flight -
  so a probe that dies mid-experiment leaves every fact measured up to the
  dying step, attributed. A phase-deadline helper thread force-advances any
  phase that stalls (a view that never loads is a FACT, not a hang), and a
  navmatrix-style watchdog bounds the whole run. If webview_run returns
  early during an experiment - the very outcome the loop-ownership question
  exists to observe - the probe RECORDS it and re-enters the loop (bounded)
  to finish the remaining experiments.

  The exit code is 0 whenever a facts JSON was written, complete or not;
  only a probe that could not even start measuring exits 1. The canonical
  marker (grepped by run_topology.ps1/.sh from the constant below):

      topology: TOPOLOGY MEASURED

  Construction mirrors test/cap8b/navmatrix.pas where the platforms differ
  (Cocoa FPU preflight, GTK display preflight, watchdog + RTLEvent shape),
  because those are the measured prerequisites of opening ANY WebView from
  this runtime - not part of the question under measurement. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  pweb.lib.webview,
  pweb.lib.webview.types,
  pweb.lib.webview.errors,
  {$ifdef DARWIN}
  pweb.platform.cocoa
  {$else}
  {$ifdef LINUX}
  pweb.platform.webkitgtk
  {$else}
  pweb.platform.webview2
  {$endif LINUX}
  {$endif DARWIN}
  ;

const
  LOG_PREFIX = 'topology';
  MARKER_DONE = 'topology: TOPOLOGY MEASURED';
  MARKER_FAIL = 'topology: TOPOLOGY PROBE FAILED';
  {$ifdef DARWIN}
    {$ifdef CPUAARCH64}
    TARGET_ID = 'macos-arm64';
    {$else}
    TARGET_ID = 'macos-x86_64';
    {$endif CPUAARCH64}
  {$else}
  {$ifdef LINUX}
  TARGET_ID = 'linux-x86_64';
  {$else}
  TARGET_ID = 'windows-x86_64';
  {$endif LINUX}
  {$endif DARWIN}

  // the whole-run watchdog: generous, because a wedged engine is bounded by
  // the CI step timeout anyway - this only exists so a local run cannot idle
  DEFAULT_TIMEOUT_MS = 90000;
  MAX_TIMEOUT_MS = 180000;
  // per-phase deadline: a phase that records nothing for this long is
  // force-advanced, and the missing event becomes a measured fact
  DEFAULT_PHASE_MS = 12000;
  MAX_PHASE_MS = 60000;
  CLOSER_WAIT_MARGIN_MS = 10000;

  // phases, monotonic
  PH_LIVENESS = 0;   // both pages load + both holds resolved
  PH_TERM2    = 1;   // webview_terminate on the second instance
  PH_DESTROY2 = 2;   // webview_destroy of the second instance, loop running
  PH_SHUTDOWN = 3;   // webview_terminate on the first (run-owning) instance
  PH_DONE     = 4;

  // bounded re-entries of webview_run after an experiment stopped the loop
  MAX_REENTRIES = 3;

  // dispatched actions (FPC has no closures; arg encodes the request)
  ACT_FORCE_ADVANCE  = 1;
  ACT_ENTER_DESTROY2 = 2;
  ACT_EVAL_CANARY_D  = 3;

  // sentinel for "this call was never attempted" - rendered as JSON null
  CODE_NONE = -9999;

type
  TTri = (triUnknown, triTrue, triFalse);

  TSlot = record
    Tag: AnsiChar;          // 'A' (first view) or 'B' (second view)
    Handle: webview_t;      // the instance this slot's bindings belong to
    HoldId: RawUtf8;        // copied binding id of the unresolved hold call
    HoldPending: Boolean;
  end;
  PSlot = ^TSlot;

  TFacts = record
    EngineVersion: RawUtf8;
    SecondCreateOk: TTri;
    DistinctHandles: TTri;
    PrerunWindowFirst: TTri;      // webview_get_window non-nil before run?
    PrerunWindowSecond: TTri;
    PrerunWindowsDistinct: TTri;
    LiveWindowFirst: TTri;        // and again once the liveness phase ends
    LiveWindowSecond: TTri;
    BindPostFirstCode: Integer;
    BindHoldFirstCode: Integer;
    BindPostSecondCode: Integer;
    BindHoldSecondCode: Integer;
    SetHtmlFirstCode: Integer;
    SetHtmlSecondCode: Integer;
    FirstLoaded: TTri;
    SecondLoaded: TTri;
    PostArrivals: Integer;
    CrossDeliveries: Integer;
    UnknownUserdata: Integer;
    UnexpectedArrivals: Integer;
    ConcurrentHolds: TTri;
    HoldReturnFirstCode: Integer;
    HoldReturnSecondCode: Integer;
    FirstResolved: TTri;
    SecondResolved: TTri;
    LivenessTimeout: Boolean;
    TerminateSecondCode: Integer;
    TerminateSecondStopped: TTri;
    RunReentries: Integer;
    DestroySecondCode: Integer;
    LoopSurvivedSecondDestroy: TTri;
    SurvivorFunctional: TTri;
    TerminateFirstCode: Integer;
    TerminateFirstStopped: TTri;
    DestroySecondPostrunCode: Integer;
    DestroyFirstPostrunCode: Integer;
    PrematureExitPhase: Integer;  // -1 = the loop never exited prematurely
    RunCodes: array of Integer;
    CrashGuard: RawUtf8;          // step in flight; '' when all clear
  end;

var
  W1, W2: webview_t;
  SlotA, SlotB: TSlot;
  TwoViewMode: Boolean;
  Facts: TFacts;
  Timeline: array of RawUtf8;
  StartTick: QWord;
  OutFile: TFileName;
  // true from the moment the first view exists: before that, SaveFacts is a
  // no-op so an engine-less runner leaves no half-record (see SaveFacts)
  JsonEnabled: Boolean;
  PhaseNo: LongInt;
  PhaseEvent: PRTLEvent;
  PhaseTimeoutMs: Integer;
  HelperStop: LongInt;
  WatchdogEvent: PRTLEvent;
  AutoCloseHandle: Pointer;

{ ---- recording ----------------------------------------------------------- }

function JsonSafeText(const AValue: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  // timeline entries and guard names go into JSON strings: quotes,
  // backslashes and control bytes are flattened rather than escaped - they
  // are diagnostics, not data anyone parses back
  Result := AValue;
  for i := 1 to Length(Result) do
    if (Result[i] = '"') or (Result[i] = '\') or (Result[i] < #$20) then
      Result[i] := '''';
end;

function TriJson(const AValue: TTri): RawUtf8;
begin
  case AValue of
    triTrue: Result := 'true';
    triFalse: Result := 'false';
  else
    Result := 'null';
  end;
end;

function CodeJson(const AValue: Integer): RawUtf8;
begin
  if AValue = CODE_NONE then
    Result := 'null'
  else
    Result := RawUtf8(IntToStr(AValue));
end;

function BoolJson(const AValue: Boolean): RawUtf8;
begin
  if AValue then
    Result := 'true'
  else
    Result := 'false';
end;

procedure SaveFacts;
var
  json, tl, runs: RawUtf8;
  i: PtrInt;
  stream: TFileStream;
  completed: Boolean;
begin
  // no record before the FIRST view exists: a runner with no usable engine
  // (webview_create nil) must leave NO json, so run_topology.ps1 can record
  // its honest SKIP instead of mistaking the preflight for a measurement
  if (OutFile = '') or not JsonEnabled then
    exit;
  completed := PhaseNo >= PH_DONE;
  tl := '[';
  for i := 0 to High(Timeline) do
  begin
    if i > 0 then
      tl := tl + ',';
    tl := tl + #10'    "' + JsonSafeText(Timeline[i]) + '"';
  end;
  tl := tl + #10'  ]';
  runs := '[';
  for i := 0 to High(Facts.RunCodes) do
  begin
    if i > 0 then
      runs := runs + ',';
    runs := runs + RawUtf8(IntToStr(Facts.RunCodes[i]));
  end;
  runs := runs + ']';
  json := '{' + #10 +
    '  "schema": 1,' + #10 +
    '  "probe": "cap8c-topology",' + #10 +
    '  "target": "' + TARGET_ID + '",' + #10 +
    '  "engine": "' + JsonSafeText(Facts.EngineVersion) + '",' + #10;
  if completed then
    json := json + '  "overall": "COMPLETE",' + #10
  else
    json := json + '  "overall": "PARTIAL",' + #10;
  json := json + '  "completed": ' + BoolJson(completed) + ',' + #10;
  if Facts.CrashGuard = '' then
    json := json + '  "crash_guard": null,' + #10
  else
    json := json + '  "crash_guard": "' + JsonSafeText(Facts.CrashGuard) +
      '",' + #10;
  json := json +
    '  "facts": {' + #10 +
    '    "second_create_before_run_ok": ' + TriJson(Facts.SecondCreateOk) + ',' + #10 +
    '    "distinct_instance_handles": ' + TriJson(Facts.DistinctHandles) + ',' + #10 +
    '    "prerun_window_first_nonnil": ' + TriJson(Facts.PrerunWindowFirst) + ',' + #10 +
    '    "prerun_window_second_nonnil": ' + TriJson(Facts.PrerunWindowSecond) + ',' + #10 +
    '    "prerun_windows_distinct": ' + TriJson(Facts.PrerunWindowsDistinct) + ',' + #10 +
    '    "live_window_first_nonnil": ' + TriJson(Facts.LiveWindowFirst) + ',' + #10 +
    '    "live_window_second_nonnil": ' + TriJson(Facts.LiveWindowSecond) + ',' + #10 +
    '    "bind_post_first_code": ' + CodeJson(Facts.BindPostFirstCode) + ',' + #10 +
    '    "bind_hold_first_code": ' + CodeJson(Facts.BindHoldFirstCode) + ',' + #10 +
    '    "bind_post_second_code": ' + CodeJson(Facts.BindPostSecondCode) + ',' + #10 +
    '    "bind_hold_second_code": ' + CodeJson(Facts.BindHoldSecondCode) + ',' + #10 +
    '    "set_html_first_code": ' + CodeJson(Facts.SetHtmlFirstCode) + ',' + #10 +
    '    "set_html_second_code": ' + CodeJson(Facts.SetHtmlSecondCode) + ',' + #10 +
    '    "first_view_loaded": ' + TriJson(Facts.FirstLoaded) + ',' + #10 +
    '    "second_view_loaded_during_first_run": ' + TriJson(Facts.SecondLoaded) + ',' + #10 +
    '    "post_arrivals": ' + RawUtf8(IntToStr(Facts.PostArrivals)) + ',' + #10 +
    '    "cross_deliveries": ' + RawUtf8(IntToStr(Facts.CrossDeliveries)) + ',' + #10 +
    '    "unknown_userdata": ' + RawUtf8(IntToStr(Facts.UnknownUserdata)) + ',' + #10 +
    '    "unexpected_arrivals": ' + RawUtf8(IntToStr(Facts.UnexpectedArrivals)) + ',' + #10;
  // computed, never stored: isolation holds when arrivals exist and no
  // arrival carried the wrong slot pointer or the wrong view tag
  if Facts.PostArrivals = 0 then
    json := json + '    "userdata_isolated": null,' + #10
  else
    json := json + '    "userdata_isolated": ' +
      BoolJson((Facts.CrossDeliveries = 0) and (Facts.UnknownUserdata = 0)) +
      ',' + #10;
  json := json +
    '    "concurrent_holds_observed": ' + TriJson(Facts.ConcurrentHolds) + ',' + #10 +
    '    "hold_return_first_code": ' + CodeJson(Facts.HoldReturnFirstCode) + ',' + #10 +
    '    "hold_return_second_code": ' + CodeJson(Facts.HoldReturnSecondCode) + ',' + #10 +
    '    "first_view_resolved": ' + TriJson(Facts.FirstResolved) + ',' + #10 +
    '    "second_view_resolved": ' + TriJson(Facts.SecondResolved) + ',' + #10 +
    '    "liveness_timeout": ' + BoolJson(Facts.LivenessTimeout) + ',' + #10 +
    '    "run_entered_on": "first",' + #10 +
    '    "terminate_second_code": ' + CodeJson(Facts.TerminateSecondCode) + ',' + #10 +
    '    "terminate_second_stopped_run": ' + TriJson(Facts.TerminateSecondStopped) + ',' + #10 +
    '    "run_reentries": ' + RawUtf8(IntToStr(Facts.RunReentries)) + ',' + #10 +
    '    "destroy_second_code": ' + CodeJson(Facts.DestroySecondCode) + ',' + #10 +
    '    "loop_survived_second_destroy": ' + TriJson(Facts.LoopSurvivedSecondDestroy) + ',' + #10 +
    '    "survivor_functional_after_close": ' + TriJson(Facts.SurvivorFunctional) + ',' + #10 +
    '    "terminate_first_code": ' + CodeJson(Facts.TerminateFirstCode) + ',' + #10 +
    '    "terminate_first_stopped_run": ' + TriJson(Facts.TerminateFirstStopped) + ',' + #10 +
    '    "destroy_second_postrun_code": ' + CodeJson(Facts.DestroySecondPostrunCode) + ',' + #10 +
    '    "destroy_first_postrun_code": ' + CodeJson(Facts.DestroyFirstPostrunCode) + ',' + #10;
  if Facts.PrematureExitPhase < 0 then
    json := json + '    "premature_exit_phase": null,' + #10
  else
    json := json + '    "premature_exit_phase": ' +
      RawUtf8(IntToStr(Facts.PrematureExitPhase)) + ',' + #10;
  json := json +
    '    "run_return_codes": ' + runs + #10 +
    '  },' + #10 +
    '  "timeline": ' + tl + #10 +
    '}' + #10;
  stream := TFileStream.Create(OutFile, fmCreate);
  try
    if json <> '' then
      stream.WriteBuffer(json[1], Length(json));
  finally
    stream.Free;
  end;
end;

procedure Note(const AEvent: RawUtf8);
var
  entry: RawUtf8;
begin
  // single writer by construction: every Note runs on the thread that owns
  // the loop (bind callbacks and dispatches execute inside webview_run on
  // the main thread; before and after run it IS the main thread). The
  // helper threads never record - they only dispatch.
  entry := RawUtf8(IntToStr(Int64(GetTickCount64 - StartTick))) + 'ms ' +
    AEvent;
  SetLength(Timeline, Length(Timeline) + 1);
  Timeline[High(Timeline)] := entry;
  WriteLn(LOG_PREFIX, ': ', entry);
  SaveFacts;
end;

procedure CrashGuard(const AStep: RawUtf8);
begin
  Facts.CrashGuard := AStep;
  SaveFacts;
end;

procedure CrashGuardClear;
begin
  Facts.CrashGuard := '';
  SaveFacts;
end;

{ ---- plumbing ------------------------------------------------------------ }

function RepoRootFromExecutable: TFileName;
var
  dir, parent: TFileName;
  i: Integer;
begin
  dir := Executable.ProgramFilePath;
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

function ExtractSingleString(const AReq: RawUtf8): RawUtf8;
var
  first, last: PtrInt;
begin
  // the request is the JSON argument array of a binding call; every probe
  // payload is one string, so the bytes between the first and last double
  // quote are the payload (escapes inside a jserror message are tolerated
  // as-is - they end up flattened in the timeline, never parsed back)
  Result := '';
  first := Pos('"', AReq);
  if first = 0 then
    exit;
  last := Length(AReq);
  while (last > first) and (AReq[last] <> '"') do
    Dec(last);
  if last <= first then
    exit;
  Result := copy(AReq, first + 1, last - first - 1);
end;

function BuildPageHtml(const ATag: AnsiChar): RawUtf8;
begin
  // the shared page: report load, hold an unresolved invocation open, then
  // report the resolution - every step a full JS->native->JS round trip
  Result :=
    '<!doctype html><html><head><meta charset="utf-8"></head><body>' +
    '<div>CAP-8C topology probe view ' + ATag + '</div><script>' +
    '(function(){var T="' + ATag + '";' +
    'function post(m){return window.__cap8c_post(T+":"+m);}' +
    'post("loaded")' +
    '.then(function(){return window.__cap8c_hold(T);})' +
    '.then(function(r){return post("resolved:"+String(r));})' +
    '.catch(function(e){try{post("jserror:"+String(e));}catch(x){}});' +
    '})();</script></body></html>';
end;

procedure TerminateOnGuiThread(w: webview_t; arg: Pointer); cdecl;
begin
  try
    webview_terminate(w);
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

procedure RequestTerminate;
var
  handle: Pointer;
begin
  handle := InterlockedExchange(AutoCloseHandle, nil);
  if handle <> nil then
    webview_dispatch(webview_t(handle), @TerminateOnGuiThread, nil);
end;

procedure EvalCanary(const AKind: AnsiChar);
var
  js: RawUtf8;
  code: Integer;
begin
  // a full eval->page->binding->native round trip on the FIRST view: its
  // arrival proves the loop pumps and the survivor still executes JS
  js := 'window.__cap8c_post && window.__cap8c_post("A:canary_' + AKind +
    '");';
  code := webview_eval(W1, PAnsiChar(js));
  Note('eval canary_' + AKind + ' issued (code ' +
    RawUtf8(IntToStr(code)) + ')');
end;

procedure ResolveHold(var ASlot: TSlot; const AResult: RawUtf8);
var
  code: Integer;
begin
  if not ASlot.HoldPending then
    exit;
  ASlot.HoldPending := False;
  code := webview_return(ASlot.Handle, PAnsiChar(ASlot.HoldId), 0,
    PAnsiChar(AResult));
  if ASlot.Tag = 'A' then
    Facts.HoldReturnFirstCode := code
  else
    Facts.HoldReturnSecondCode := code;
  Note('hold on view ' + ASlot.Tag + ' resolved with ' + AResult +
    ' (code ' + RawUtf8(IntToStr(code)) + ')');
end;

{ ---- the phase machine (loop thread only) -------------------------------- }

procedure EnterPhase(APhase: LongInt); forward;

procedure RecordLiveWindows;
begin
  if webview_get_window(W1) <> nil then
    Facts.LiveWindowFirst := triTrue
  else
    Facts.LiveWindowFirst := triFalse;
  if TwoViewMode and (W2 <> nil) then
  begin
    if webview_get_window(W2) <> nil then
      Facts.LiveWindowSecond := triTrue
    else
      Facts.LiveWindowSecond := triFalse;
  end;
end;

procedure EnterPhase(APhase: LongInt);
begin
  if APhase <= PhaseNo then
    exit; // monotonic: a stale advance can never rewind an experiment
  InterlockedExchange(PhaseNo, APhase);
  RTLEventSetEvent(PhaseEvent); // re-arm the phase deadline
  case APhase of
    PH_TERM2:
      begin
        RecordLiveWindows;
        if not TwoViewMode or (W2 = nil) then
        begin
          Note('single view only - skipping the close-one experiments');
          EnterPhase(PH_SHUTDOWN);
          exit;
        end;
        Note('experiment: webview_terminate on the second instance');
        CrashGuard('terminate-second');
        Facts.TerminateSecondCode := webview_terminate(W2);
        CrashGuardClear;
        Note('terminate(second) returned ' +
          RawUtf8(IntToStr(Facts.TerminateSecondCode)));
        EvalCanary('T');
      end;
    PH_DESTROY2:
      begin
        if not TwoViewMode or (W2 = nil) then
        begin
          EnterPhase(PH_SHUTDOWN);
          exit;
        end;
        Note('experiment: webview_destroy of the second instance');
        CrashGuard('destroy-second');
        Facts.DestroySecondCode := webview_destroy(W2);
        W2 := nil;
        CrashGuardClear;
        Note('destroy(second) returned ' +
          RawUtf8(IntToStr(Facts.DestroySecondCode)));
        EvalCanary('D');
      end;
    PH_SHUTDOWN:
      begin
        Note('shutdown: webview_terminate on the first instance');
        Facts.TerminateFirstCode := webview_terminate(W1);
        SaveFacts;
      end;
  end;
end;

procedure CheckLivenessComplete;
begin
  if PhaseNo <> PH_LIVENESS then
    exit;
  if (Facts.FirstLoaded = triTrue) and (Facts.FirstResolved = triTrue) and
     ((not TwoViewMode) or
      ((Facts.SecondLoaded = triTrue) and (Facts.SecondResolved = triTrue))) then
    EnterPhase(PH_TERM2);
end;

procedure ForceAdvance;
begin
  // dispatched by the phase-deadline helper; executing HERE proves the loop
  // is pumping, which is itself evidence in the two close-one phases
  case PhaseNo of
    PH_LIVENESS:
      begin
        Facts.LivenessTimeout := True;
        Note('liveness deadline: forcing (loaded A=' +
          TriJson(Facts.FirstLoaded) + ' B=' + TriJson(Facts.SecondLoaded) +
          ', resolved A=' + TriJson(Facts.FirstResolved) + ' B=' +
          TriJson(Facts.SecondResolved) + ')');
        ResolveHold(SlotA, '"forced"');
        ResolveHold(SlotB, '"forced"');
        EnterPhase(PH_TERM2);
      end;
    PH_TERM2:
      begin
        // the force ran on the loop => terminate(second) did NOT stop it,
        // even though the canary round trip never came back (first writer
        // wins: a stop already measured by an early run return stands)
        if Facts.TerminateSecondStopped = triUnknown then
          Facts.TerminateSecondStopped := triFalse;
        Note('terminate-second deadline: loop alive, canary_T never arrived');
        EnterPhase(PH_DESTROY2);
      end;
    PH_DESTROY2:
      begin
        if Facts.LoopSurvivedSecondDestroy = triUnknown then
          Facts.LoopSurvivedSecondDestroy := triTrue;
        if Facts.SurvivorFunctional = triUnknown then
          Facts.SurvivorFunctional := triFalse;
        Note('destroy-second deadline: loop alive, canary_D never arrived');
        EnterPhase(PH_SHUTDOWN);
      end;
    PH_SHUTDOWN:
      begin
        Note('shutdown deadline: terminating the first instance again');
        webview_terminate(W1);
      end;
  end;
end;

procedure DispatchAction(w: webview_t; arg: Pointer); cdecl;
begin
  try
    case PtrUInt(arg) of
      ACT_FORCE_ADVANCE:
        ForceAdvance;
      ACT_ENTER_DESTROY2:
        EnterPhase(PH_DESTROY2);
      ACT_EVAL_CANARY_D:
        EvalCanary('D');
    end;
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

{ ---- binding callbacks (loop thread) ------------------------------------- }

function ValidSlot(arg: Pointer): PSlot;
begin
  if (arg = @SlotA) or (arg = @SlotB) then
    Result := PSlot(arg)
  else
    Result := nil;
end;

procedure PostCallback(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  slot: PSlot;
  req8, payload, rest: RawUtf8;
  tag: AnsiChar;
begin
  try
    slot := ValidSlot(arg);
    if slot = nil then
    begin
      Inc(Facts.UnknownUserdata);
      Note('post arrival with UNKNOWN userdata pointer');
      exit;
    end;
    Inc(Facts.PostArrivals);
    if req = nil then
      req8 := ''
    else
      FastSetString(req8, req, StrLen(req));
    payload := ExtractSingleString(req8);
    // answer first: the page awaits every post
    webview_return(slot^.Handle, id, 0, '"ok"');
    tag := #0;
    if (Length(payload) >= 2) and (payload[2] = ':') then
      tag := payload[1];
    if tag <> slot^.Tag then
    begin
      Inc(Facts.CrossDeliveries);
      Note('CROSS DELIVERY: payload "' + payload + '" arrived on slot ' +
        slot^.Tag);
    end;
    rest := copy(payload, 3, MaxInt);
    if rest = 'loaded' then
    begin
      if slot^.Tag = 'A' then
        Facts.FirstLoaded := triTrue
      else
        Facts.SecondLoaded := triTrue;
      Note('view ' + slot^.Tag + ' loaded (JS->native round trip up)');
      CheckLivenessComplete;
    end
    else if copy(rest, 1, 9) = 'resolved:' then
    begin
      if slot^.Tag = 'A' then
        Facts.FirstResolved := triTrue
      else
        Facts.SecondResolved := triTrue;
      Note('view ' + slot^.Tag + ' saw its hold resolution (' + rest + ')');
      CheckLivenessComplete;
    end
    else if rest = 'canary_T' then
    begin
      // FIRST WRITER WINS: when the run already returned during this
      // experiment (measured on Windows: the posted quit can surface before
      // the canary round trip lands), the stop is the fact and a canary
      // arriving after the re-entry must not overwrite it
      if Facts.TerminateSecondStopped = triUnknown then
      begin
        Facts.TerminateSecondStopped := triFalse;
        Note('canary_T arrived: the loop survived terminate(second)');
      end
      else
        Note('canary_T arrived after the re-entry (stop already measured)');
      EnterPhase(PH_DESTROY2);
    end
    else if rest = 'canary_D' then
    begin
      if Facts.LoopSurvivedSecondDestroy = triUnknown then
        Facts.LoopSurvivedSecondDestroy := triTrue;
      Facts.SurvivorFunctional := triTrue;
      Note('canary_D arrived: survivor functional after destroy(second)');
      EnterPhase(PH_SHUTDOWN);
    end
    else if copy(rest, 1, 8) = 'jserror:' then
      Note('view ' + slot^.Tag + ' reported a JS error: ' + rest)
    else
    begin
      Inc(Facts.UnexpectedArrivals);
      Note('unexpected payload "' + payload + '" on slot ' + slot^.Tag);
    end;
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

procedure HoldCallback(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  slot: PSlot;
begin
  try
    slot := ValidSlot(arg);
    if slot = nil then
    begin
      Inc(Facts.UnknownUserdata);
      Note('hold arrival with UNKNOWN userdata pointer');
      exit;
    end;
    // the id is only valid for the duration of the callback - copy it
    if id = nil then
      slot^.HoldId := ''
    else
      FastSetString(slot^.HoldId, id, StrLen(id));
    slot^.HoldPending := True;
    Note('hold arrived from view ' + slot^.Tag);
    if not TwoViewMode then
      // no partner to overlap with: resolve immediately, the concurrency
      // fact stays unknown/false by construction
      ResolveHold(slot^, '"solo"')
    else if SlotA.HoldPending and SlotB.HoldPending then
    begin
      Facts.ConcurrentHolds := triTrue;
      Note('both holds outstanding CONCURRENTLY - resolving both');
      ResolveHold(SlotA, '"both"');
      ResolveHold(SlotB, '"both"');
    end;
  except
    { Pascal exceptions never cross a C callback. }
  end;
end;

{ ---- helper threads ------------------------------------------------------ }

function WatchdogThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  RTLEventWaitFor(WatchdogEvent, PtrInt(Param));
  RequestTerminate; // no-op when the handle was already cleared
end;

function PhaseHelperThread(Param: Pointer): PtrInt;
var
  seen: LongInt;
  handle: Pointer;
begin
  Result := 0;
  repeat
    seen := PhaseNo;
    RTLEventWaitFor(PhaseEvent, PhaseTimeoutMs);
    RTLEventResetEvent(PhaseEvent);
    if HelperStop <> 0 then
      exit;
    if (PhaseNo = seen) and (PhaseNo < PH_DONE) then
    begin
      // the phase made no progress for a whole deadline: force it forward
      // ON the loop thread (dispatch is the one documented thread-safe way
      // in). A dead loop ignores this - the watchdog and the runner bound
      // that case, and the JSON already holds every fact measured so far.
      handle := AutoCloseHandle;
      if handle <> nil then
        webview_dispatch(webview_t(handle), @DispatchAction,
          Pointer(PtrUInt(ACT_FORCE_ADVANCE)));
    end;
  until PhaseNo >= PH_DONE;
end;

{ ---- platform preflight (measured prerequisites, not the measurement) ---- }

{$ifdef DARWIN}
procedure CheckCocoaRuntimeUsable;
begin
  if PWebCocoaFpuTrapsMasked then
    exit;
  WriteLn(StdErr, LOG_PREFIX,
    ': COCOA RUNTIME UNUSABLE (fpu traps still enabled)');
  raise Exception.Create('FPU traps could not be masked - no WebView created');
end;
{$endif DARWIN}

{$ifdef LINUX}
procedure CheckGtkDisplayUsable;
var
  reason: RawUtf8;
begin
  reason := PWebGtkDisplayUnavailableReason;
  if reason = '' then
    exit;
  WriteLn(StdErr, LOG_PREFIX, ': GTK DISPLAY UNAVAILABLE (', reason, ')');
  raise Exception.Create('no usable display - no WebView was created');
end;
{$endif LINUX}

{ ---- main ---------------------------------------------------------------- }

procedure InitFacts;
begin
  Facts := Default(TFacts);
  Facts.BindPostFirstCode := CODE_NONE;
  Facts.BindHoldFirstCode := CODE_NONE;
  Facts.BindPostSecondCode := CODE_NONE;
  Facts.BindHoldSecondCode := CODE_NONE;
  Facts.SetHtmlFirstCode := CODE_NONE;
  Facts.SetHtmlSecondCode := CODE_NONE;
  Facts.HoldReturnFirstCode := CODE_NONE;
  Facts.HoldReturnSecondCode := CODE_NONE;
  Facts.TerminateSecondCode := CODE_NONE;
  Facts.DestroySecondCode := CODE_NONE;
  Facts.TerminateFirstCode := CODE_NONE;
  Facts.DestroySecondPostrunCode := CODE_NONE;
  Facts.DestroyFirstPostrunCode := CODE_NONE;
  Facts.PrematureExitPhase := -1;
end;

function ReadTimeoutEnv(const AName: string;
  ADefault, AMax: Integer): Integer;
begin
  Result := StrToIntDef(GetEnvironmentVariable(AName), ADefault);
  if (Result <= 0) or (Result > AMax) then
    Result := ADefault;
end;

var
  root: TFileName;
  timeoutMs: Integer;
  debugFlag: Integer;
  verinfo: Pwebview_version_info_t;
  win1, win2: Pointer;
  html: RawUtf8;
  watchdogId, helperId: system.TThreadID;
  watchdogHandle, helperHandle: system.TThreadID;
  watchdogStarted, helperStarted, safeToDestroy: Boolean;
  runCode: Integer;
  currentPhase: LongInt;

begin
  ExitCode := 0;
  W1 := nil;
  W2 := nil;
  TwoViewMode := False;
  watchdogStarted := False;
  helperStarted := False;
  safeToDestroy := True;
  JsonEnabled := False;
  PhaseNo := PH_LIVENESS;
  StartTick := GetTickCount64;
  InitFacts;
  try
    root := RepoRootFromExecutable;
    if root = '' then
      raise Exception.Create(
        'repository root (webview.lock marker) not found from ' +
        string(Executable.ProgramFilePath));
    OutFile := root + 'build' + PathDelim + 'cap8c' + PathDelim +
      'topology-' + TARGET_ID + '.json';
    if not ForceDirectories(ExtractFilePath(OutFile)) then
      raise Exception.Create('unable to create ' +
        string(ExtractFilePath(OutFile)));

    timeoutMs := ReadTimeoutEnv('PWEB_TOPOLOGY_TIMEOUT_MS',
      DEFAULT_TIMEOUT_MS, MAX_TIMEOUT_MS);
    PhaseTimeoutMs := ReadTimeoutEnv('PWEB_TOPOLOGY_PHASE_MS',
      DEFAULT_PHASE_MS, MAX_PHASE_MS);

    {$ifdef DARWIN}
    CheckCocoaRuntimeUsable;
    {$endif DARWIN}
    {$ifdef LINUX}
    CheckGtkDisplayUsable;
    {$endif LINUX}

    verinfo := webview_version();
    if verinfo <> nil then
      FastSetString(Facts.EngineVersion,
        PAnsiChar(@verinfo^.version_number[0]),
        StrLen(PAnsiChar(@verinfo^.version_number[0])));

    if GetEnvironmentVariable('PWEB_TOPOLOGY_DEBUG') = '1' then
      debugFlag := 1
    else
      debugFlag := 0;

    // ---- create the first view; its nil-create is the runner's SKIP ----
    CrashGuard('create-first'); // stdout only: JsonEnabled is still false
    W1 := WebViewCheckCreated(webview_create(debugFlag, nil));
    JsonEnabled := True;
    CrashGuardClear;
    Note('first webview created');

    // ---- QUESTION 1: a second view, before any loop runs ----
    CrashGuard('create-second');
    W2 := webview_create(debugFlag, nil);
    CrashGuardClear;
    if W2 = nil then
    begin
      Facts.SecondCreateOk := triFalse;
      Note('second webview_create returned nil - single-view mode');
    end
    else
    begin
      Facts.SecondCreateOk := triTrue;
      TwoViewMode := True;
      if W2 <> W1 then
        Facts.DistinctHandles := triTrue
      else
        Facts.DistinctHandles := triFalse;
      Note('second webview created before the loop');
    end;

    win1 := webview_get_window(W1);
    if win1 <> nil then
      Facts.PrerunWindowFirst := triTrue
    else
      Facts.PrerunWindowFirst := triFalse;
    if TwoViewMode then
    begin
      win2 := webview_get_window(W2);
      if win2 <> nil then
        Facts.PrerunWindowSecond := triTrue
      else
        Facts.PrerunWindowSecond := triFalse;
      if (win1 <> nil) and (win2 <> nil) then
      begin
        if win1 <> win2 then
          Facts.PrerunWindowsDistinct := triTrue
        else
          Facts.PrerunWindowsDistinct := triFalse;
      end;
    end;
    SaveFacts;

    // ---- QUESTIONS 5/6 setup: same names, distinct userdata ----
    SlotA.Tag := 'A';
    SlotA.Handle := W1;
    Facts.BindPostFirstCode := webview_bind(W1, '__cap8c_post',
      @PostCallback, @SlotA);
    Facts.BindHoldFirstCode := webview_bind(W1, '__cap8c_hold',
      @HoldCallback, @SlotA);
    Note('first view bound (post=' +
      RawUtf8(IntToStr(Facts.BindPostFirstCode)) + ' hold=' +
      RawUtf8(IntToStr(Facts.BindHoldFirstCode)) + ')');
    if TwoViewMode then
    begin
      SlotB.Tag := 'B';
      SlotB.Handle := W2;
      Facts.BindPostSecondCode := webview_bind(W2, '__cap8c_post',
        @PostCallback, @SlotB);
      Facts.BindHoldSecondCode := webview_bind(W2, '__cap8c_hold',
        @HoldCallback, @SlotB);
      Note('second view bound, same names (post=' +
        RawUtf8(IntToStr(Facts.BindPostSecondCode)) + ' hold=' +
        RawUtf8(IntToStr(Facts.BindHoldSecondCode)) + ')');
    end;

    webview_set_title(W1, 'PWeb CAP-8C topology A');
    webview_set_size(W1, 480, 360, WEBVIEW_HINT_NONE);
    html := BuildPageHtml('A');
    Facts.SetHtmlFirstCode := webview_set_html(W1, PAnsiChar(html));
    if TwoViewMode then
    begin
      webview_set_title(W2, 'PWeb CAP-8C topology B');
      webview_set_size(W2, 480, 360, WEBVIEW_HINT_NONE);
      html := BuildPageHtml('B');
      Facts.SetHtmlSecondCode := webview_set_html(W2, PAnsiChar(html));
    end;
    SaveFacts;

    // ---- watchdog + phase deadline, then the loop ----
    AutoCloseHandle := Pointer(W1);
    WatchdogEvent := RTLEventCreate;
    watchdogHandle := BeginThread(@WatchdogThread,
      Pointer(PtrInt(timeoutMs)), watchdogId);
    watchdogStarted := watchdogHandle <> system.TThreadID(0);
    if not watchdogStarted then
      raise Exception.Create('unable to start the watchdog thread');
    PhaseEvent := RTLEventCreate;
    helperHandle := BeginThread(@PhaseHelperThread, nil, helperId);
    helperStarted := helperHandle <> system.TThreadID(0);
    if not helperStarted then
      raise Exception.Create('unable to start the phase-deadline thread');

    // ---- QUESTIONS 2/3/4/7/8: run the loop ON THE FIRST INSTANCE ----
    // and re-enter it (bounded) whenever an experiment stops it: that
    // early return is itself the loop-ownership fact under measurement
    Note('entering webview_run on the FIRST instance');
    repeat
      runCode := webview_run(W1);
      SetLength(Facts.RunCodes, Length(Facts.RunCodes) + 1);
      Facts.RunCodes[High(Facts.RunCodes)] := runCode;
      currentPhase := PhaseNo;
      Note('webview_run returned ' + RawUtf8(IntToStr(runCode)) +
        ' during phase ' + RawUtf8(IntToStr(currentPhase)));
      if currentPhase >= PH_SHUTDOWN then
      begin
        Facts.TerminateFirstStopped := triTrue;
        InterlockedExchange(PhaseNo, PH_DONE);
        RTLEventSetEvent(PhaseEvent);
        break;
      end;
      case currentPhase of
        PH_TERM2:
          begin
            // terminate(second) took the FIRST instance's loop down: the
            // loop is process-global on this engine
            Facts.TerminateSecondStopped := triTrue;
            Note('terminate(second) STOPPED the first instance''s run');
            if Facts.RunReentries >= MAX_REENTRIES then
            begin
              Facts.PrematureExitPhase := currentPhase;
              break;
            end;
            Inc(Facts.RunReentries);
            webview_dispatch(W1, @DispatchAction,
              Pointer(PtrUInt(ACT_ENTER_DESTROY2)));
            Note('re-entering webview_run (' +
              RawUtf8(IntToStr(Facts.RunReentries)) + ')');
          end;
        PH_DESTROY2:
          begin
            Facts.LoopSurvivedSecondDestroy := triFalse;
            Note('destroy(second) STOPPED the first instance''s run');
            if Facts.RunReentries >= MAX_REENTRIES then
            begin
              Facts.PrematureExitPhase := currentPhase;
              break;
            end;
            Inc(Facts.RunReentries);
            webview_dispatch(W1, @DispatchAction,
              Pointer(PtrUInt(ACT_EVAL_CANARY_D)));
            Note('re-entering webview_run (' +
              RawUtf8(IntToStr(Facts.RunReentries)) + ')');
          end;
      else
        // the loop died during liveness: nothing terminated anything yet,
        // so this is an engine fact worth recording, not worth retrying
        Facts.PrematureExitPhase := currentPhase;
        Note('premature loop exit during phase ' +
          RawUtf8(IntToStr(currentPhase)));
        break;
      end;
    until False;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, LOG_PREFIX, ': FAIL ', E.ClassName, ': ', E.Message);
      WriteLn(StdErr, MARKER_FAIL, ' (', E.Message, ')');
      ExitCode := 1;
    end;
  end;

  // ---- teardown: helper first (it dispatches into the loop), then the
  // watchdog, then the instances - post-run destroy is the documented order
  if helperStarted then
  begin
    InterlockedExchange(HelperStop, 1);
    RTLEventSetEvent(PhaseEvent);
    if WaitForThreadTerminate(helperHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
    begin
      WriteLn(StdErr, LOG_PREFIX, ': FAIL phase helper did not terminate');
      safeToDestroy := False;
      ExitCode := 1;
    end;
    CloseThread(helperHandle);
  end;
  if PhaseEvent <> nil then
  begin
    if safeToDestroy then
      RTLEventDestroy(PhaseEvent);
    PhaseEvent := nil;
  end;
  if watchdogStarted then
  begin
    InterlockedExchange(AutoCloseHandle, nil);
    RTLEventSetEvent(WatchdogEvent);
    if WaitForThreadTerminate(watchdogHandle, CLOSER_WAIT_MARGIN_MS) <> 0 then
    begin
      WriteLn(StdErr, LOG_PREFIX, ': FAIL watchdog did not terminate');
      safeToDestroy := False;
      ExitCode := 1;
    end;
    CloseThread(watchdogHandle);
  end;
  if WatchdogEvent <> nil then
  begin
    if safeToDestroy then
      RTLEventDestroy(WatchdogEvent);
    WatchdogEvent := nil;
  end;
  InterlockedExchange(AutoCloseHandle, nil);

  if JsonEnabled and safeToDestroy then
  begin
    if W2 <> nil then
    begin
      CrashGuard('destroy-second-postrun');
      Facts.DestroySecondPostrunCode := webview_destroy(W2);
      W2 := nil;
      CrashGuardClear;
      Note('post-run destroy(second) returned ' +
        RawUtf8(IntToStr(Facts.DestroySecondPostrunCode)));
    end;
    if W1 <> nil then
    begin
      CrashGuard('destroy-first-postrun');
      Facts.DestroyFirstPostrunCode := webview_destroy(W1);
      W1 := nil;
      CrashGuardClear;
      Note('post-run destroy(first) returned ' +
        RawUtf8(IntToStr(Facts.DestroyFirstPostrunCode)));
    end;
  end;

  if JsonEnabled then
  begin
    SaveFacts;
    if PhaseNo >= PH_DONE then
      WriteLn(LOG_PREFIX, ': OVERALL COMPLETE')
    else
      WriteLn(LOG_PREFIX, ': OVERALL PARTIAL (phase ',
        PhaseNo, ' at exit)');
    WriteLn(MARKER_DONE);
  end
  else if ExitCode = 0 then
  begin
    // no JSON and no recorded exception: refuse to look like a measurement
    WriteLn(StdErr, MARKER_FAIL, ' (no facts were recorded)');
    ExitCode := 1;
  end;
end.
