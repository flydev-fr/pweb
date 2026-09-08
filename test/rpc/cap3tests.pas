program cap3tests;

{ WebView-free CAP-3 headless gate: the real mORMot bridge matrix, plus the
  CAP-8A capability integration gates on Windows. It keeps CI independent of
  webview.dll, and it is where the Windows leg registers the cases the POSIX
  suites take through pwebtests.

  Until the 2026-09-08 mORMot pin move this program refused to compile
  without PWEB_CALLMETHOD_UNWIND_PROBE, the define that selected the CAP-3U
  patched trampoline: a CAP-3 gate built against an unpatched Win64 mORMot
  would have died mid-suite rather than reported. The pin now carries
  upstream 896f1c1c and 790154af, there is no trampoline to select, and the
  guard would only assert that a removed patch had been applied. What keeps
  the property honest instead is test/cap3u, which measures the unwind
  metadata and the Currency matrix directly. }

{$I mormot.defines.inc}

{$ifdef PWEB_CALLMETHOD_UNWIND_PROBE}
  {$fatal PWEB_CALLMETHOD_UNWIND_PROBE named the removed CAP-3U patch; nothing selects a trampoline any more}
{$endif}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.mormot.bridge,
  pweb.test.mormot.routing,
  pweb.test.mormot.integration,
  pweb.test.capabilities.integration;

type
  TCap3Tests = class(TSynTests)
  published
    procedure MormotBridge;
    procedure CapabilityPolicyIntegration;
  end;

procedure TCap3Tests.MormotBridge;
begin
  AddCase([TTestMormotBridge, TTestMormotRouting,
    TTestMormotIntegration]);
end;

procedure TCap3Tests.CapabilityPolicyIntegration;
begin
  // CAP-8A gates I1-I10 on Windows: this runner is where they register,
  // because the Windows pwebtests compile is deliberately handed no
  // mORMot ORM/REST/SOA unit paths; the POSIX targets run the same unit
  // through pwebtests, which is handed the full set
  AddCase([TTestCapabilityPolicyIntegration]);
end;

begin
  TCap3Tests.RunAsConsole('PWeb CAP-3 real in-process mORMot bridge + ' +
    'CAP-8A capability integration gates I1-I10');
end.
