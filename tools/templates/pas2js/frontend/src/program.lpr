program {{PASCAL_PROGRAM}}app;

{ {{PROJECT_NAME}} - the browser entry point.

  Deliberately three lines of behaviour. Everything the application does
  lives in app.pas, and this file exists because a Pas2JS program needs a
  program: keeping it empty is what makes "the frontend is real Pascal"
  a statement about app.pas rather than about a bootstrap.

  -Jc compiles this into one JavaScript file that declares `rtl` without
  starting it, so the page loads assets/app.js and then a one-line
  assets/boot.js containing rtl.run(). No inline script anywhere: the
  native Content-Security-Policy carries script-src 'self' with no
  'unsafe-inline', and an inline <script> is exactly what that forbids. }

{$mode objfpc}

uses
  app;

begin
  RunApp;
end.
