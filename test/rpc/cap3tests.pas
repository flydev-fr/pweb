program cap3tests;

{ WebView-free CAP-3 headless gate. The same cases are conditionally
  registered in pwebtests when the CAP-3U define is active; this runner keeps
  CI independent of webview.dll and runs only the real mORMot bridge matrix. }

{$I mormot.defines.inc}

{$ifndef PWEB_CALLMETHOD_UNWIND_PROBE}
  {$fatal CAP-3 headless tests require prepared CAP-3U}
{$endif}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.mormot.bridge,
  pweb.test.mormot.routing,
  pweb.test.mormot.integration;

type
  TCap3Tests = class(TSynTests)
  published
    procedure MormotBridge;
  end;

procedure TCap3Tests.MormotBridge;
begin
  AddCase([TTestMormotBridge, TTestMormotRouting,
    TTestMormotIntegration]);
end;

begin
  TCap3Tests.RunAsConsole('PWeb CAP-3 real in-process mORMot bridge');
end.
