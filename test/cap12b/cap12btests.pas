program cap12btests;

{ CAP-12B suite runner over the blob data plane (mormot.core.test).

  Headless on all four targets, and NOT ONE ENGINE: the store, the ceilings,
  the token and Range grammars, the exchange a handler gets back and the
  three lifecycle releases are all platform-independent by construction -
  IBlobStore names no URI scheme and the translator names no native type -
  so every one of them is provable with no window and no display.

  The ENGINE facts are measured live by test/cap12b/bloblive.pas on four
  targets: that a Range header reaches a handler at all, that a 206 built
  here is honoured by fetch(), that an <img> loads from a blob URL and that a
  typed-array request body arrives byte-exact.

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
  pweb.test.blobs;

type
  TPWebBlobTests = class(TSynTests)
  published
    procedure Store;
    procedure Ceilings;
    procedure Grammar;
    procedure Exchange;
    procedure Lifecycle;
    procedure FetchDoor;
  end;

procedure TPWebBlobTests.Store;
begin
  AddCase([TTestPWebBlobStore]);
end;

procedure TPWebBlobTests.Ceilings;
begin
  AddCase([TTestPWebBlobCeilings]);
end;

procedure TPWebBlobTests.Grammar;
begin
  AddCase([TTestPWebBlobGrammar]);
end;

procedure TPWebBlobTests.Exchange;
begin
  AddCase([TTestPWebBlobExchange]);
end;

procedure TPWebBlobTests.Lifecycle;
begin
  AddCase([TTestPWebBlobLifecycle]);
end;

procedure TPWebBlobTests.FetchDoor;
begin
  AddCase([TTestPWebBlobFetchDoor]);
end;

begin
  TPWebBlobTests.RunAsConsole('PWeb CAP-12B tests (store + ceilings + ' +
    'token and Range grammar + exchange + lifecycle + the fetch door)');
end.
