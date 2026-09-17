program cap16tests;

{ CAP-16 suite runner over the native signal channel (mormot.core.test).

  Headless on all four targets: the one script and its encoder, the channel
  through a fake view, the socket door sitting on the channel, and the
  caller principal a bridged mORMot service reads (ledger 12-5). The engines
  are measured live by test/cap16/evalprobe.pas and test/cap16/signallive.pas.

  A SEPARATE program from test/core/pwebtests.pas for 15B's reason: the
  CAP-8A capability corpus pwebtests owns must not gain a row, or
  capability_policy_digest would move.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.signal;

type
  TPWebSignalTests = class(TSynTests)
  published
    procedure Script;
    procedure Channel;
    procedure Socket;
    procedure CallerPrincipal;
  end;

procedure TPWebSignalTests.Script;
begin
  AddCase([TTestPWebSignalScript]);
end;

procedure TPWebSignalTests.Channel;
begin
  AddCase([TTestPWebSignalChannel]);
end;

procedure TPWebSignalTests.Socket;
begin
  AddCase([TTestPWebSignalSocket]);
end;

procedure TPWebSignalTests.CallerPrincipal;
begin
  AddCase([TTestPWebCallerPrincipal]);
end;

begin
  TPWebSignalTests.RunAsConsole('PWeb CAP-16 tests (script + channel + ' +
    'socket door on the channel + caller principal)');
end.
