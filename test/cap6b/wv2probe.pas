program wv2probe;

{ CAP-6b0 host WebView2 detection probe.

  Prints the structured PWebWv2Detect result of THIS machine as one
  stable machine-parsable WV2DETECT line plus its diagnostic. CI runs
  it as a diagnostic gate: the runner's detected version goes to the
  step summary as evidence; an unavailable runtime is a SKIP, never a
  failure - only a crash (contract violation: the detector must never
  raise) or a missing WV2DETECT line fails the gate. CI never
  downloads or installs a runtime because of what this prints.

  Exit code 0 = a structured result was produced; 1 = the probe
  crashed, which the detector contract forbids. }

{$mode ObjFPC}{$H+}

{$apptype console}

uses
  sysutils,
  mormot.core.base,
  pweb.platform.webview2.runtime;

var
  detection: TPWebWv2DetectionResult;
begin
  ExitCode := 1;
  try
    detection := PWebWv2Detect;
    writeln('WV2DETECT status=', PWebWv2StatusText(detection.Status),
      ' channel=', PWebWv2ChannelText(detection.Channel),
      ' raw="', detection.RawVersion,
      '" parsed=', PWebWv2VersionText(detection.Parsed),
      ' parsedok=', BoolToStr(detection.ParsedOk, 'true', 'false'),
      ' minbuild=', PWEB_WV2_MIN_BUILD,
      ' usable=', BoolToStr(PWebWv2DetectionUsable(detection),
        'true', 'false'),
      ' decision=', PWebWv2DecisionText(
        PWebWv2ProvisioningDecide(detection)));
    writeln('WV2DETECT_DIAG ', detection.Diagnostic);
    ExitCode := 0;
  except
    // PWebWv2Detect never raises by contract - reaching this handler
    // is itself the failure CI must surface
    on E: Exception do
      writeln('WV2DETECT_CRASH ', E.ClassName, ': ', E.Message);
  end;
end.
