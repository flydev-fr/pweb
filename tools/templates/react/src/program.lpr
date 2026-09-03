program {{PASCAL_PROGRAM}};

{ {{PROJECT_NAME}} - a PWeb application.

    {{EXECUTABLE_NAME}} + app.pwb

  This file is the whole of the native entry point, and it is short on
  purpose. Composing a PWeb host - locating the bundle beside the
  executable, checking the platform runtime before a window can exist,
  attaching the pweb://app handler on the proven native seam, installing the
  privileged-navigation guard before the first navigation, binding the
  invocation primitive, and tearing all of it down in the exact reverse
  order - is the SDK's job, and it lives in pweb.webview.host. Copying that
  choreography into every application is how four copies of one decision
  start drifting apart.

  What this file does own is the composition every application owns:

    the service catalogue      one in-process mORMot REST server
    the bridge chain           application -> runtime commands -> mORMot
    the capability policy      app.services.BuildAppPolicy
    the window                 title and size

  THE DATA PATH, end to end:

    React -> @pweb/runtime -> the native invocation primitive
          -> IInvocationScheduler -> ICapabilityPolicy (authoritative)
          -> TPWebRuntimeCommandBridge -> TAppBridge
          -> TMormotInvocationBridge -> TRestServer.Uri()

  There is no HTTP server anywhere in it. Nothing here opens a socket,
  listens on a port or binds an address: the frontend and the backend are
  the same process, and the invocation crosses a function call rather than a
  network. }

{$I mormot.defines.inc}

{$ifdef OSWINDOWS}
  { A console subsystem application, so the diagnostic lines below are
    visible while you are building. Remove this directive when you ship a
    windowed product. }
  {$apptype console}
{$endif OSWINDOWS}

uses
  {$I mormot.uses.inc}
  sysutils,
  mormot.core.base,
  mormot.core.interfaces,
  mormot.rest.memserver,
  mormot.soa.core,
  mormot.soa.server,
  pweb.rpc.intf,
  pweb.rpc.mormot,
  pweb.capabilities.policy,
  pweb.webview.host,
  {$ifdef PWEB_DEV}
  { THE DEVELOPMENT COMPOSITION, and the ONLY place this build's mode is
    selected. PWEB_DEV is defined by the COMPILER COMMAND `pweb dev` builds
    with (-dPWEB_DEV, into its own unit and object directories); no frontend
    file, no descriptor field, no manifest and no environment variable can
    reach it. A release build never defines it, so the unit below is not on
    the release binary's compiled unit set at all.

    Development changes exactly one thing: the asset store is the generation
    the CLI last published, rather than the app.pwb beside this executable.
    The origin stays pweb://app, the CSP is the same bytes, the policy is
    the same policy and the bridge chain is the same chain. }
  pweb.webview.devhost,
  {$endif PWEB_DEV}
  app.services;

const
  APP_NAME = '{{PROJECT_NAME}}';
  APP_VERSION = '{{PROJECT_VERSION}}';
  APP_BUNDLE_ID = '{{BUNDLE_ID}}';
  APP_TITLE = '{{PROJECT_NAME}}';

var
  server: TRestServerFullMemory;
  factory: TServiceFactoryServerAbstract;
  realBridge, bridge: IInvocationBridge;
  policy: TPWebCapabilityPolicy;
  policyRef: ICapabilityPolicy;
  options: TPWebHostOptions;

begin
  ExitCode := 0;
  server := nil;
  try
    WriteLn(APP_NAME, ': ', APP_VERSION, ' (', APP_BUNDLE_ID, ')');
    // MEASURED: FPC block-buffers stdout when it is a PIPE on Linux and
    // macOS, so this line - the first sign of life a supervisor can see -
    // would otherwise arrive only when the process ends
    Flush(Output);

    // the in-process service catalogue. sicShared is one instance for the
    // whole process; the scheduler calls it on worker threads, so keep an
    // implementation that holds state thread-safe or choose another mode
    server := TRestServerFullMemory.CreateWithOwnModel([]);
    factory := server.ServiceRegister(TCalculatorService,
      [TypeInfo(ICalculatorService)], sicShared);
    if factory = nil then
      raise Exception.Create('unable to register CalculatorService');

    // the bridge chain, outermost first. The application decorator sees
    // every arrival, the runtime command layer answers the methods the
    // runtime owns, and everything else reaches mORMot
    realBridge := TMormotInvocationBridge.Create(server, True);
    server := nil; // ownership moved to the bridge
    bridge := TAppBridge.Create(PWebHostRuntimeBridge(realBridge), APP_NAME);

    // the policy is authoritative and runs at the scheduler, BEFORE the
    // bridge chain above is reached
    policy := BuildAppPolicy;
    policyRef := policy;

    options := PWebDefaultHostOptions(APP_TITLE, APP_NAME);
    {$ifdef PWEB_DEV}
    // the development host: --pweb-dev-root=<dir> is REQUIRED, generation 1
    // is opened through the production loader, and every later generation
    // is swapped in and re-navigated to pweb://app without this process
    // restarting
    ExitCode := PWebDevHostRun(options, policy, bridge);
    {$else}
    ExitCode := PWebHostRun(options, policy, bridge);
    {$endif PWEB_DEV}
  except
    on E: Exception do
    begin
      WriteLn(StdErr, APP_NAME, ': FAIL ', E.ClassName, ': ', E.Message);
      ExitCode := 1;
    end;
  end;
  policyRef := nil;
  policy := nil;
  bridge := nil;
  realBridge := nil; // frees the owned server after the workers have drained
  server.Free;
  if ExitCode = 0 then
    WriteLn(APP_NAME, ': clean exit');
end.
