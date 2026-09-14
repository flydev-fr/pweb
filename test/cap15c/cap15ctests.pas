program cap15ctests;

{ CAP-15C suite runner over the native socket door (mormot.core.test).

  Headless on all four targets, and NOT ONE SOCKET: the wss authorisation
  rule, the handshake allowlists, the traffic contract, the bounded queue and
  its backpressure, ownership, the lifecycle and the capability wiring are
  driven through the INJECTED transport. The transports themselves are
  measured LIVE by test/cap15c/socketlive.pas against test/cap15c/ws_server.js
  and, on Darwin, by the probe.

  A SEPARATE program from test/core/pwebtests.pas for 15B's reason: the CAP-8A
  capability corpus pwebtests owns must not gain a row, or
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
  pweb.test.socket;

type
  TPWebSocketTests = class(TSynTests)
  published
    procedure UrlAuthority;
    procedure Handshake;
    procedure Traffic;
    procedure Queue;
    procedure Ownership;
    procedure Lifecycle;
    procedure CapabilityWiring;
  end;

procedure TPWebSocketTests.UrlAuthority;
begin
  AddCase([TTestPWebSocketUrl]);
end;

procedure TPWebSocketTests.Handshake;
begin
  AddCase([TTestPWebSocketHandshake]);
end;

procedure TPWebSocketTests.Traffic;
begin
  AddCase([TTestPWebSocketTraffic]);
end;

procedure TPWebSocketTests.Queue;
begin
  AddCase([TTestPWebSocketQueue]);
end;

procedure TPWebSocketTests.Ownership;
begin
  AddCase([TTestPWebSocketOwnership]);
end;

procedure TPWebSocketTests.Lifecycle;
begin
  AddCase([TTestPWebSocketLifecycle]);
end;

procedure TPWebSocketTests.CapabilityWiring;
begin
  AddCase([TTestPWebSocketPolicy]);
end;

begin
  TPWebSocketTests.RunAsConsole('PWeb CAP-15C tests (wss authority + ' +
    'handshake + traffic + queue + ownership + lifecycle + capability wiring)');
end.
