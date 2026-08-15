program uri_oracle;

{ CAP-7M0 PROBE F oracle (M11/M12): the ONE authority on a pweb:// URI,
  applied to the exact strings a real WKWebView handed the scheme handler.

  test/cap7m/cap7m_probe.mm deliberately contains NO URI parser. It serves an
  exact full-string allowlist and refuses everything else, and it prints every
  URL it observed, verbatim, as

      CAP7M_URI cycle=N verdict=serve|refuse url=<the whole URI>

  This program reads those URIs (one per line on stdin) and renders the only
  verdict this project recognises, by calling the shared, portable, frozen
  routine that Windows and Linux already call:

      pweb.assets.support.PWebParseAppUri

  Nothing here re-implements, mirrors or approximates that routine. That is
  the point: a macOS-specific copy of the authority check is exactly the
  defect the "whole URI, always" rule exists to prevent, and a second
  validator would drift long before anyone noticed.

  test/cap7m/run_cap7m_probes.sh then cross-checks the two streams, and the
  finding that matters is an agreement failure: a URI the probe SERVED that
  the shared routine REJECTS would mean a wrong authority could reach
  IAssetStore.

  Blank lines and lines beginning with '#' are ignored so the caller can
  concatenate the observed URIs with the canonical hostile-vector list -
  a vector WebKit normalised or refused before the handler still has to be
  proven refused by the routine itself.

    uri_oracle < uris.txt }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  pweb.assets.support;

var
  line: string;
  uri, logical: RawUtf8;
  accepted, rejected: PtrInt;

begin
  accepted := 0;
  rejected := 0;
  while not Eof(Input) do
  begin
    ReadLn(Input, line);
    line := TrimRight(line);
    if (line = '') or (line[1] = '#') then
      continue;
    uri := RawUtf8(line);
    logical := '';
    if PWebParseAppUri(uri, logical) then
    begin
      inc(accepted);
      WriteLn('CAP7M_ORACLE verdict=accept path=', logical, ' url=', uri);
    end
    else
    begin
      inc(rejected);
      WriteLn('CAP7M_ORACLE verdict=reject path=- url=', uri);
    end;
  end;
  WriteLn('CAP7M_ORACLE_SUMMARY accepted=', accepted, ' rejected=', rejected);
end.
