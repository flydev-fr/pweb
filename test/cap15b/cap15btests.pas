program cap15btests;

{ CAP-15B suite runner over the native outbound door (mormot.core.test).

  Headless on all four targets, and NOT ONE SOCKET: the whole §4 request
  contract, the §5 envelope, the origin grammar and the capability wiring
  are driven through the INJECTED transport that §1 exists to make
  injectable. The transports themselves - mORMot on Windows and Linux,
  NSURLSession on Darwin - are measured LIVE against a local server by
  test/cap15b/fetchlive.pas and by test/cap15b/darwinprobe.pas, because a
  transport is the one thing a fake transport cannot stand in for.

  It is a SEPARATE program from test/core/pwebtests.pas for the reason
  test/cap10a/clitests.pas is: this suite drives a decorator whose whole
  point is that it has an injected seam, and the CAP-8A capability corpus
  that pwebtests owns is FROZEN by this shard's own acceptance conditions -
  a new row there would move capability_policy_digest.

  Exit code 0 = every assertion of every case passed; 1 otherwise. Pass
  /noenter in scripts and CI so no ENTER key is awaited on exit. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  mormot.core.test,
  pweb.test.fetch;

type
  TPWebFetchTests = class(TSynTests)
  published
    procedure OriginGrammar;
    procedure RequestContract;
    procedure ResponseEnvelope;
    procedure CapabilityWiring;
  end;

procedure TPWebFetchTests.OriginGrammar;
begin
  // G1-G14: the ONE origin grammar of this product - the same function the
  // descriptor reader, the doctor, the build refusal and the running
  // decorator all call, so a rule proved here is proved for all four
  AddCase([TTestPWebFetchGrammar]);
end;

procedure TPWebFetchTests.RequestContract;
begin
  // R1-R24: every row of §4, through the injected transport, with the
  // transport ENTRY COUNT asserted on each one - a refusal that reached a
  // socket would fail here rather than pass quietly
  AddCase([TTestPWebFetchRequest]);
end;

procedure TPWebFetchTests.ResponseEnvelope;
begin
  // E1-E12: §5's envelope, the response-header allowlist including
  // `location` and excluding `set-cookie`, the two inline caps and the
  // three typed refusals
  AddCase([TTestPWebFetchResponse]);
end;

procedure TPWebFetchTests.CapabilityWiring;
begin
  // P1-P5: the REAL TPWebCapabilityPolicy and the REAL scheduler, so
  // "forbidden with zero transport" is a measurement. The CAP-8A corpus is
  // frozen by this shard and gains nothing; this is how that freeze avoids
  // becoming a coverage hole
  AddCase([TTestPWebFetchPolicy]);
end;

begin
  TPWebFetchTests.RunAsConsole('PWeb CAP-15B tests (origin grammar + ' +
    'request contract + response envelope + capability wiring)');
end.
