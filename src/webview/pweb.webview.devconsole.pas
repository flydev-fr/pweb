{
  pweb.webview.devconsole - the DEVELOPMENT console surface (CAP-14B).

  Note for editors, the rule pweb.webview.host's own header states: a
  compiler directive may NOT be written inside a brace comment. FPC reads
  the nested brace as a directive and ends the comment at the next closing
  brace, so every conditional named in prose here is spelled without braces.

  THIS UNIT IS NEVER LINKED INTO A RELEASE. pweb.webview.devhost selects it
  and nothing else does, and the ONE line pweb.webview.host contributes is
  inside an ifdef PWEB_DEV block, so a release compile sees an identical
  token stream and emits identical bytes. test/cap10c2 measures both rather
  than asserting them - a directory listing of the release -FU output, and a
  byte scan of the release executable for the bind name below.

  ---------------------------------------------------------------------------
  THE DEFECT
  ---------------------------------------------------------------------------

  A frontend under `pweb dev` had no voice. Every console.log, console.warn
  and console.error, every uncaught throw and every unhandled rejection died
  inside the engine: the supervisor forwards the HOST's lines and the page is
  not the host. A developer probed blind (TODO.txt #6).

  ---------------------------------------------------------------------------
  THE MECHANISM, AND THE THREE THAT WERE MEASURED AND REFUSED
  ---------------------------------------------------------------------------

  ONE mechanism on four targets: a document-start user script through
  webview_init, delivering through ONE webview_bind channel. Measured on the
  ratified Linux baseline (webkit2gtk-4.1 2.52.6) against a real same-origin
  page under `script-src 'self'`: the user script RUNS while the page's own
  inline script is refused, and window.onerror on a same-origin script gives
  the real `<url>:<line>:<col>`.

  WebKitGTK's enable-write-console-messages-to-stdout works and is refused on
  four measured grounds: no position for an unhandled rejection; written by
  the WebKit WEB PROCESS, so its lines interleave with the host's out of
  order; unbounded - 10000 of 10000 burst lines reached stdout from a page
  loop that took 59 ms, about 170000 lines a second; and it lands on STDOUT,
  which is the stream the CLI reads its one acknowledgement protocol from.

  WebKitGTK's console-message-sent is unreachable from a UI process:
  WebKitConsoleMessage comes only from webkit-web-extension.h, so it would
  mean shipping a second shared library into the dev layout and loading it
  into the WebKit web process.

  WebView2's DevTools protocol delivers Runtime.consoleAPICalled arguments as
  RemoteObject previews, so the native side would have to INTERPRET message
  content; and the pinned ICoreWebView2 vtables live in a release-linked
  unit. WKWebView has no public console API at all, and webview_init IS the
  WKUserScript route there - so macOS needs the shim whatever the others do.

  ---------------------------------------------------------------------------
  WHAT THIS CHANNEL IS, AND WHAT IT CAN NEVER BE
  ---------------------------------------------------------------------------

  It is a DEV-ONLY, ONE-WAY DIAGNOSTIC SINK. It reaches no service: this
  unit's uses clause names no rpc unit, no scheduler, no bridge and no
  capability policy, and that is checked rather than promised. Nothing a page
  sends selects a destination, a bound or any host action. The ONLY effect of
  a message is a bounded line on stderr.

  IT IS NOT A SECOND RPC PATH. It carries no method, no arguments and no
  result; the promise every bound call creates is resolved with a constant
  and nothing is ever routed.

  ---------------------------------------------------------------------------
  THE WIRE, AND WHY NO PARSER MEETS PAGE BYTES
  ---------------------------------------------------------------------------

  One binding call carries ONE argument: base64 of a batch. Records are
  separated by LF, fields inside a record by U+001F:

      level US method US origin US text

  The native side takes the bytes between the FIRST and the LAST quote of the
  parameter array, base64-decodes them (invalid, or past the payload bound,
  and the whole batch is dropped and counted), splits on those two
  separators, looks the level up in a fixed table - anything else is dropped
  and counted - and replaces every byte below $20 and $7F. Base64 was chosen
  over a JSON decode precisely so that no general parser ever meets page
  bytes and no crafted escape can produce a second line.

  THE ONE PLACE A DIGIT IS READ is the `dropped` level, whose text must be
  one to nine ASCII digits: that is a bound the page reports about itself,
  and the `(page)` / `(host)` token beside it is written natively.

  ---------------------------------------------------------------------------
  THE THREE BOUNDS, AND WHAT EACH ONE COVERS
  ---------------------------------------------------------------------------

  MEASURED: a page loop issuing 10000 console.log calls completed in 59 ms,
  so a runaway frontend can produce about 170000 lines a second. Nothing
  downstream survives that unbounded, so the channel is bounded three times:

    in the page   at most PWEB_DEV_CONSOLE_MAX_BATCH records every
                  PWEB_DEV_CONSOLE_FLUSH_MS, over a pending queue of
                  PWEB_DEV_CONSOLE_MAX_PENDING. Overflow drops and counts,
                  and the count travels as a `dropped` record;
    on the wire   PWEB_DEV_CONSOLE_MAX_PAYLOAD base64 bytes per call,
                  refused before a decode is attempted;
    in the host   PWEB_DEV_CONSOLE_MAX_BATCHES queued batches. This is the
                  AUTHORITATIVE bound, because a page can call the binding
                  directly and skip its own.

  THE GUI THREAD NEVER WRITES TO A PIPE. Upstream dispatches every bound
  message onto the GUI thread, so a callback that wrote to stderr would block
  the GUI loop on backpressure - which is the literal "a flood stalls the dev
  loop". The callback decodes, enqueues non-blocking and returns; one writer
  thread formats and emits.

  IT ALWAYS RETURNS. Upstream's init script keeps a promise per bound call
  and resolves it from webview_return, so a callback that never returned
  would leak one promise per console line.

  LINES ARE WRITTEN WHOLE, WITH ONE FileWrite TO StdErrorHandle, and never
  with WriteLn: FPC's text layer is not thread-safe and the generation poller
  already writes to stderr, while a single write below the platform's pipe
  atomicity bound cannot be torn. Every line is capped at
  PWEB_DEV_CONSOLE_LINE_MAX = 3072, which leaves 1024 bytes of headroom under
  the supervisor's own PWEB_CLI_RUN_LINE_MAX of 4096 for the `app: ` prefix
  it prepends and the ` [truncated]` marker it may append.

  ---------------------------------------------------------------------------
  STDERR, AND THE ACKNOWLEDGEMENT IT CANNOT FORGE
  ---------------------------------------------------------------------------

  The channel carries bytes a PAGE authored, so it must not share the stream
  the CLI reads its one protocol from. PWebCliDevParseAck matches
  `: generation <N> loaded` ANYWHERE in a line, so a page logging
  `x: generation 999 loaded` on stdout would advance the CLI's generation
  counter and drive its bounded cleanup. Two independent barriers close it:
  this channel writes to STDERR, and pweb.cli.dev parses the acknowledgement
  on pcsStdOut only. Either alone is one edit from being lost.

  ---------------------------------------------------------------------------
  NO PLATFORM CONDITIONAL
  ---------------------------------------------------------------------------

  There is not one ifdef in this unit and there must never be: everything
  platform-shaped belongs to pweb.webview.host, which is the ONE allowlisted
  file in src/webview. There is no environment read either - the mode arrives
  as a compiler define and the prefix as a parameter.
}
unit pweb.webview.devconsole;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.os,
  mormot.core.unicode,
  mormot.core.text,
  mormot.core.buffers,
  pweb.lib.webview;

const
  /// the ONE dev-only binding name, and the marker that proves a binary
  // carries the channel - test/cap10c2 scans the RELEASE bytes for it and
  // requires it absent
  PWEB_DEV_CONSOLE_BIND = '__pweb_dev_console';

  /// the fixed token every console line carries after the host's prefix
  PWEB_DEV_CONSOLE_TAG = ': console ';

  /// the eight levels a page may name, and the ONLY ones
  // - the first five are console methods, the next two are the engine's own
  // error events, and `dropped` is the page reporting its own bound
  PWEB_DEV_CONSOLE_LEVELS: array[0..7] of RawUtf8 = (
    'log', 'info', 'warn', 'error', 'debug', 'uncaught', 'rejection',
    'dropped');

  /// the level a page must use to report its own drop count
  PWEB_DEV_CONSOLE_DROPPED = 'dropped';

  /// one record's rendered text, in BYTES, truncated on a UTF-8 boundary
  PWEB_DEV_CONSOLE_MAX_TEXT = 1024;
  /// one record's source position, in bytes
  PWEB_DEV_CONSOLE_MAX_ORIGIN = 512;
  /// one record's console method name, in bytes
  PWEB_DEV_CONSOLE_MAX_METHOD = 32;
  /// records per flush - with the interval below, the page-side rate bound
  PWEB_DEV_CONSOLE_MAX_BATCH = 32;
  /// how often the page flushes what it has queued
  PWEB_DEV_CONSOLE_FLUSH_MS = 50;
  /// records the page may hold before it starts dropping and counting
  PWEB_DEV_CONSOLE_MAX_PENDING = 256;
  /// base64 bytes one call may carry, refused BEFORE a decode is attempted
  // - MAX_BATCH * (MAX_TEXT + MAX_ORIGIN + MAX_METHOD + 4) is 50 KiB of
  // records, whose base64 is under 68 KiB; 96 KiB is the bound with margin
  PWEB_DEV_CONSOLE_MAX_PAYLOAD = 98304;
  /// batches the host may hold - the AUTHORITATIVE bound, because a page can
  // call the binding directly and skip its own
  PWEB_DEV_CONSOLE_MAX_BATCHES = 64;
  /// one emitted line, including the prefix and the trailing LF
  // - 1024 bytes of headroom under the supervisor's PWEB_CLI_RUN_LINE_MAX
  PWEB_DEV_CONSOLE_LINE_MAX = 3072;
  /// how long the writer thread waits before it looks again
  PWEB_DEV_CONSOLE_POLL_MS = 100;
  /// how much longer than one poll the teardown waits for the writer
  PWEB_DEV_CONSOLE_JOIN_MS = 5000;

/// the dev-only page shim, with the binding name substituted once
// - a document-start user script: it wraps every function-valued property of
// `console`, listens for `error` and `unhandledrejection`, renders each into
// one bounded record and flushes batches through the binding
function PWebDevConsoleShim: RawUtf8;

/// the diagnostic prefix every emitted line starts with
// - called by the composition BEFORE the host runs; a channel installed
// without it still works and simply carries an empty prefix
procedure PWebDevConsoleConfigure(const APrefix: RawUtf8);

/// install the channel on a live view, on the GUI thread
// - THE ONE SEAM: pweb.webview.host calls this through
// TPWebHostOptions.DevViewReady, after the invocation binding is bound and
// BEFORE the first navigation, and only under the PWEB_DEV define
procedure PWebDevConsoleInstall(AView: Pointer);

/// stop the writer thread and drain what it still holds
// - called by the composition AFTER PWebHostRun has returned, so the GUI
// loop is already gone and no further callback can fire
procedure PWebDevConsoleShutdown;

/// render ONE decoded batch the way the writer thread renders it
// - exposed so the headless suite can decide the whole grammar without a
// window: every level, the method rule, the position rule, truncation, the
// sanitiser and every refusal
function PWebDevConsoleRenderBatch(const APrefix, ABatch: RawUtf8;
  out Refused: Integer): TRawUtf8DynArray;

/// decode ONE binding parameter array into a batch
// - False when the payload is past its bound, is not framed by quotes, or is
// not valid base64. Total: it never raises and never partially accepts
function PWebDevConsoleDecodeParams(const AParams: RawUtf8;
  out Batch: RawUtf8): Boolean;

type
  /// where one finished line goes - stderr in a real host, a collector in
  // the headless suite
  TPWebDevConsoleEmit = procedure(const Line: RawUtf8);

/// run the WHOLE channel headless, through the REAL ring and the REAL
/// writer path, emitting into Sink instead of stderr
// - the headless proof of the AUTHORITATIVE bound: a caller pushing more
// batches than the ring holds sees the surplus dropped, counted, and said
// - refuses while a real channel is installed, so it can never race one
function PWebDevConsoleProbe(Batches, RecordsEach: Integer;
  const Sink: TPWebDevConsoleEmit; out Emitted: Integer;
  out DroppedHost: Int64): Boolean;


implementation

const
  /// the field separator inside one record, and the record separator
  US = #31;
  LF = #10;

  /// the shim, with {{BIND}} substituted by PWebDevConsoleShim
  // - ASCII only, so it is byte-identical on four targets and a digest of it
  // is a digest of the RULE rather than of a checkout
  /// the shim, with the four placeholders substituted by PWebDevConsoleShim
  // - ASCII only, so it is byte-identical on four targets and a digest of
  // it is a digest of the RULE rather than of a checkout
  //
  // NOTE FOR EDITORS: THIS TEXT CONTAINS NO BACKSLASH, and must not gain
  // one. Pascal string literals carry no escapes, so a JavaScript backslash
  // has to be spelled with ONE - and spelling it with two is invisible in
  // the Pascal and fatal in the JavaScript. MEASURED on the first real dev
  // session of this shard: a character class whose escapes were DOUBLED
  // reached the engine as a range running from the letter u to a backslash
  // - ends the wrong way round, so a SyntaxError thrown
  // while the shim was being PARSED, so nothing installed and the channel
  // was silent with no diagnostic anywhere - the very defect this shard
  // exists to close, wearing a different hat. Every place that would have
  // wanted an escape is written as a character-code test instead, and
  // test/cap14b/check_cap14b_contracts.ps1 refuses a backslash here
  SHIM_JS =
    '(function(){' +
    '"use strict";' +
    'if(window.__pwebDevConsole__)return;' +
    'window.__pwebDevConsole__=1;' +
    'var US=String.fromCharCode(31),NL=String.fromCharCode(10);' +
    'var MAXT=%MAXT%,MAXB=%MAXB%,MAXP=%MAXP%,IVL=%IVL%;' +
    'var q=[],dropped=0,timer=null;' +
    // one field can never carry a control byte, so one record can never
    // become two - the page half of the rule the native sanitiser enforces
    'function clean(s,max){s=String(s);' +
    'if(s.length>max){var n=max,c0=s.charCodeAt(n-1);' +
    'if(c0>=55296&&c0<=56319)n=n-1;' +
    's=s.slice(0,n)+"...[+"+(String(arguments[0]).length-n)+"]";}' +
    'var o="",i,c;' +
    'for(i=0;i<s.length;i++){c=s.charCodeAt(i);' +
    'o+=(c<32||c===127)?" ":s.charAt(i);}' +
    'return o;}' +
    // the first stack line that ENDS in :<digits>:<digits>, optionally
    // followed by one closing parenthesis - written as a scan rather than a
    // regular expression, because WebKit spells a frame `f@url:1:2` and V8
    // spells it `    at f (url:1:2)` and both have to answer
    'function hasPos(l){var i=l.length-1,d=0;' +
    'if(l.charAt(i)===")")i--;' +
    'while(i>=0&&l.charAt(i)>="0"&&l.charAt(i)<="9"){i--;d++;}' +
    'if(d===0||l.charAt(i)!==":")return false;' +
    'i--;d=0;' +
    'while(i>=0&&l.charAt(i)>="0"&&l.charAt(i)<="9"){i--;d++;}' +
    'return d>0&&l.charAt(i)===":";}' +
    // V8 spells an anonymous frame `    at url:1:2` and WebKit spells it
    // `@url:1:2`; both prefixes are dropped here so the two engines put the
    // SAME shape in the origin field. MEASURED on the linux leg, which
    // reported `@pweb://app/assets/app.js:1942:54` before this line existed
    'function trimFrame(l){var s=0;' +
    'while(s<l.length&&(l.charAt(s)===" "||l.charCodeAt(s)===9))s++;' +
    'if(l.substr(s,3)==="at ")s+=3;' +
    'while(s<l.length&&l.charAt(s)===" ")s++;' +
    'if(l.charAt(s)==="@")s+=1;' +
    'return l.slice(s);}' +
    'function frame(st){if(!st)return "";' +
    'var ls=String(st).split(NL),i;' +
    'for(i=0;i<ls.length&&i<8;i++)' +
    'if(hasPos(ls[i]))return trimFrame(ls[i]);' +
    'return "";}' +
    'function render(v){' +
    'if(typeof v==="string")return v;' +
    'if(v instanceof Error)return (v.name||"Error")+": "+(v.message||"");' +
    'if(v===null||v===undefined||typeof v!=="object")return String(v);' +
    'try{var j=JSON.stringify(v);return (j===undefined)?String(v):j;}' +
    'catch(e){return String(v);}}' +
    'function push(level,method,origin,text){' +
    'if(q.length>=MAXP){dropped++;return;}' +
    'q.push(level+US+clean(method,32)+US+clean(origin,256)+US+' +
    'clean(text,MAXT));' +
    'if(timer===null)timer=setTimeout(flush,IVL);}' +
    'function b64(s){' +
    'var b=new TextEncoder().encode(s),o="",i=0;' +
    'for(;i<b.length;i+=4096)' +
    'o+=String.fromCharCode.apply(null,b.subarray(i,i+4096));' +
    'return btoa(o);}' +
    'function flush(){timer=null;' +
    'if(!q.length&&!dropped)return;' +
    'var fn=window.%BIND%;' +
    'if(typeof fn!=="function"){q.length=0;dropped=0;return;}' +
    'var take=q.splice(0,MAXB);' +
    'if(dropped){' +
    'take.push("dropped"+US+""+US+""+US+String(dropped));dropped=0;}' +
    'try{fn(b64(take.join(NL)));}catch(e){}' +
    'if(q.length&&timer===null)timer=setTimeout(flush,IVL);}' +
    // EVERY function-valued property of console, discovered rather than
    // listed: an allowlist is a second place the platform is written down,
    // and the day it gains a method the allowlist stops covering it
    'var names=[],k;for(k in console){' +
    'try{if(typeof console[k]==="function")names.push(k);}catch(e){}}' +
    'var map={log:"log",info:"info",warn:"warn",error:"error",' +
    'debug:"debug",trace:"log",dir:"log",table:"log",assert:"error",' +
    'exception:"error"};' +
    'names.forEach(function(n){var orig=console[n];' +
    'console[n]=function(){' +
    'try{push(map[n]||"log",n,"",' +
    'Array.prototype.map.call(arguments,render).join(" "));}catch(e){}' +
    'return orig.apply(console,arguments);};});' +
    'window.addEventListener("error",function(e){' +
    'var o=e.filename?(e.filename+":"+(e.lineno|0)+":"+(e.colno|0)):"";' +
    'push("uncaught","",o,' +
    'e.message?String(e.message):render(e.error));});' +
    'window.addEventListener("unhandledrejection",function(e){' +
    'var r=e.reason;' +
    'push("rejection","",(r&&r.stack)?frame(r.stack):"",render(r));});' +
    'window.addEventListener("pagehide",function(){flush();});' +
    '})();';

type
  /// ONE decoded batch, waiting for the writer thread
  TDevConsoleSlot = record
    Batch: RawUtf8;
  end;

var
  /// the live view the callback returns through, or nil once shut down
  ConView: Pointer;
  /// this run's diagnostic prefix
  ConPrefix: RawUtf8;
  /// the ring, its lock and the event that wakes the writer
  ConRing: array[0 .. PWEB_DEV_CONSOLE_MAX_BATCHES - 1] of TDevConsoleSlot;
  ConHead, ConTail: Integer;
  ConLock: TOSLock;
  ConLockReady: Boolean;
  ConWake: TSynEvent;
  ConStop: LongInt;
  ConWriter: system.TThreadID;
  ConWriterStarted: Boolean;
  ConInstalled: Boolean;
  /// counters, for the gate and for the notice the channel says about itself
  ConDroppedHost, ConRefused: Int64;
  ConDroppedPending: Int64;
  /// where a finished line goes - stderr in a host, a collector under the
  // headless probe
  ConEmit: TPWebDevConsoleEmit;

function PWebDevConsoleShim: RawUtf8;
begin
  Result := SHIM_JS;
  Result := StringReplaceAll(Result, '%BIND%', PWEB_DEV_CONSOLE_BIND);
  Result := StringReplaceAll(Result, '%MAXT%',
    RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_TEXT)));
  Result := StringReplaceAll(Result, '%MAXB%',
    RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_BATCH)));
  Result := StringReplaceAll(Result, '%MAXP%',
    RawUtf8(IntToStr(PWEB_DEV_CONSOLE_MAX_PENDING)));
  Result := StringReplaceAll(Result, '%IVL%',
    RawUtf8(IntToStr(PWEB_DEV_CONSOLE_FLUSH_MS)));
end;

procedure PWebDevConsoleConfigure(const APrefix: RawUtf8);
begin
  ConPrefix := APrefix;
end;

{ the decode - total, and the only thing that touches the parameter text }

function PWebDevConsoleDecodeParams(const AParams: RawUtf8;
  out Batch: RawUtf8): Boolean;
var
  first, last: PtrInt;
  payload: RawUtf8;
  decoded: RawByteString;
begin
  Batch := '';
  Result := False;
  if (AParams = '') or
     (Length(AParams) > PWEB_DEV_CONSOLE_MAX_PAYLOAD + 16) then
    exit;
  // the parameter array upstream hands the callback is ["<base64>"]; the
  // payload is what sits between the FIRST and the LAST quote. Base64's own
  // alphabet carries no quote, so this needs no parser and cannot be
  // confused by anything inside it
  first := PosExChar('"', AParams);
  if first = 0 then
    exit;
  last := Length(AParams);
  while (last > first) and
        (AParams[last] <> '"') do
    Dec(last);
  if last <= first then
    exit;
  payload := Copy(AParams, first + 1, last - first - 1);
  if (payload = '') or
     (Length(payload) > PWEB_DEV_CONSOLE_MAX_PAYLOAD) then
    exit;
  // Safe: it validates the alphabet and the padding before it decodes, so a
  // crafted payload is a refusal rather than a partial batch
  if not Base64ToBinSafe(pointer(payload), Length(payload), decoded) then
    exit;
  Batch := RawUtf8(decoded);
  Result := True;
end;

{ the render - what the writer thread does, exposed for the headless suite }

function ConLevelKnown(const L: RawUtf8): Boolean;
var
  i: Integer;
begin
  for i := Low(PWEB_DEV_CONSOLE_LEVELS) to High(PWEB_DEV_CONSOLE_LEVELS) do
    if PWEB_DEV_CONSOLE_LEVELS[i] = L then
      exit(True);
  Result := False;
end;

// every byte below $20 and $7F becomes a dot, so ONE record can never become
// two lines and no terminal control sequence can survive
function ConSanitise(const S: RawUtf8; Max: PtrInt): RawUtf8;
var
  i, n: PtrInt;
  src, dst: PByte;
begin
  n := Length(S);
  if n > Max then
  begin
    // back off to a UTF-8 lead byte, so a truncation never emits half a
    // code point
    n := Max;
    while (n > 0) and
          ((PByte(PAnsiChar(S) + n)^ and $C0) = $80) do
      Dec(n);
  end;
  SetLength(Result, n);
  if n = 0 then
    exit;
  src := PByte(PAnsiChar(S));
  dst := PByte(PAnsiChar(Result));
  for i := 1 to n do
  begin
    if (src^ < 32) or
       (src^ = 127) then
      dst^ := Ord('.')
    else
      dst^ := src^;
    Inc(src);
    Inc(dst);
  end;
end;

function ConIsDigits(const S: RawUtf8): Boolean;
var
  i: PtrInt;
begin
  Result := (S <> '') and
            (Length(S) <= 9);
  if not Result then
    exit;
  for i := 1 to Length(S) do
    if (S[i] < '0') or
       (S[i] > '9') then
      exit(False);
end;

function ConSplit(const Rec: RawUtf8; out Level, Method, Origin,
  Text: RawUtf8): Boolean;
var
  a, b, c: PtrInt;
begin
  Level := '';
  Method := '';
  Origin := '';
  Text := '';
  a := PosExChar(US, Rec);
  if a = 0 then
    exit(False);
  b := PosEx(US, Rec, a + 1);
  if b = 0 then
    exit(False);
  c := PosEx(US, Rec, b + 1);
  if c = 0 then
    exit(False);
  Level := Copy(Rec, 1, a - 1);
  Method := Copy(Rec, a + 1, b - a - 1);
  Origin := Copy(Rec, b + 1, c - b - 1);
  Text := Copy(Rec, c + 1, MaxInt);
  Result := True;
end;

function ConLine(const APrefix, ALevel, AMethod, AOrigin,
  AText: RawUtf8): RawUtf8;
var
  body: RawUtf8;
begin
  body := ConSanitise(AText, PWEB_DEV_CONSOLE_MAX_TEXT);
  // the page marks its OWN truncation; this is the backstop for a caller
  // that skipped the shim, and it says so rather than cutting silently
  if Length(AText) > Length(body) then
    body := body + ' [+' + RawUtf8(IntToStr(Length(AText) - Length(body))) + ']';
  if (AMethod <> '') and
     (AMethod <> ALevel) then
    body := ConSanitise(AMethod, PWEB_DEV_CONSOLE_MAX_METHOD) + ' ' + body;
  Result := APrefix + PWEB_DEV_CONSOLE_TAG + ALevel;
  if AOrigin <> '' then
    Result := Result + ' @' + ConSanitise(AOrigin, PWEB_DEV_CONSOLE_MAX_ORIGIN);
  Result := Result + ': ' + body;
  if Length(Result) > PWEB_DEV_CONSOLE_LINE_MAX then
    Result := ConSanitise(Result, PWEB_DEV_CONSOLE_LINE_MAX);
end;

function PWebDevConsoleRenderBatch(const APrefix, ABatch: RawUtf8;
  out Refused: Integer): TRawUtf8DynArray;
var
  start, i, n: PtrInt;
  level, method, origin, text: RawUtf8;
  count: Integer;

  procedure Emit(const L: RawUtf8);
  begin
    if count = Length(Result) then
      SetLength(Result, count + 16);
    Result[count] := L;
    Inc(count);
  end;

  procedure Consider(const R: RawUtf8);
  begin
    if R = '' then
      exit;
    if not ConSplit(R, level, method, origin, text) then
    begin
      Inc(Refused);
      exit;
    end;
    if not ConLevelKnown(level) then
    begin
      // a level nobody ratified is a record nobody prints
      Inc(Refused);
      exit;
    end;
    if level = PWEB_DEV_CONSOLE_DROPPED then
    begin
      // the ONE place a digit is read: a bound the page reports about
      // itself. The `(page)` token beside it is written HERE, natively, so
      // a page can supply the number and never the attribution
      if not ConIsDigits(text) then
      begin
        Inc(Refused);
        exit;
      end;
      Emit(APrefix + PWEB_DEV_CONSOLE_TAG + PWEB_DEV_CONSOLE_DROPPED + ': ' +
        text + ' (page)');
      exit;
    end;
    Emit(ConLine(APrefix, level, method, origin, text));
  end;

begin
  Result := nil;
  Refused := 0;
  count := 0;
  n := Length(ABatch);
  start := 1;
  for i := 1 to n do
    if ABatch[i] = LF then
    begin
      Consider(Copy(ABatch, start, i - start));
      start := i + 1;
    end;
  if start <= n then
    Consider(Copy(ABatch, start, n - start + 1));
  SetLength(Result, count);
end;

{ the writer thread - the only thing in this unit that writes a byte }

procedure ConWrite(const Line: RawUtf8);
var
  buf: RawUtf8;
begin
  if Line = '' then
    exit;
  buf := Line + LF;
  // ONE write, never WriteLn: FPC's text layer is not thread-safe and the
  // generation poller already writes to stderr. A single write below the
  // platform's pipe atomicity bound cannot be torn
  FileWrite(THandle(StdErrorHandle), pointer(buf)^, Length(buf));
end;

function ConPop(out Batch: RawUtf8): Boolean;
begin
  Batch := '';
  Result := False;
  if not ConLockReady then
    exit;
  ConLock.Lock;
  try
    if ConHead = ConTail then
      exit;
    Batch := ConRing[ConTail].Batch;
    ConRing[ConTail].Batch := '';
    ConTail := (ConTail + 1) mod PWEB_DEV_CONSOLE_MAX_BATCHES;
    Result := True;
  finally
    ConLock.UnLock;
  end;
end;

procedure ConDrain;
var
  batch: RawUtf8;
  lines: TRawUtf8DynArray;
  refused, i: Integer;
  pending: Int64;
begin
  while ConPop(batch) do
  begin
    lines := PWebDevConsoleRenderBatch(ConPrefix, batch, refused);
    for i := 0 to High(lines) do
      ConEmit(lines[i]);
    if refused > 0 then
      Inc(ConRefused, refused);
  end;
  // the host's OWN bound, said on the same channel and attributed natively
  pending := 0;
  if ConLockReady then
  begin
    ConLock.Lock;
    try
      pending := ConDroppedPending;
      ConDroppedPending := 0;
    finally
      ConLock.UnLock;
    end;
  end;
  if pending > 0 then
    ConEmit(ConPrefix + PWEB_DEV_CONSOLE_TAG + PWEB_DEV_CONSOLE_DROPPED +
      ': ' + RawUtf8(IntToStr(pending)) + ' (host)');
end;

function PWebDevConsoleWriterThread(Param: Pointer): PtrInt;
begin
  Result := 0;
  while True do
  begin
    if ConWake <> nil then
      ConWake.WaitFor(PWEB_DEV_CONSOLE_POLL_MS)
    else
      Sleep(PWEB_DEV_CONSOLE_POLL_MS);
    ConDrain;
    if InterlockedExchangeAdd(ConStop, 0) <> 0 then
    begin
      // one last pass, so a message enqueued between the drain above and the
      // stop flag is not lost at teardown
      ConDrain;
      exit;
    end;
  end;
end;

{ the callback - decode, enqueue, return, and nothing else }

function ConCountRecords(const Batch: RawUtf8): Integer;
var
  i: PtrInt;
begin
  Result := 0;
  if Batch = '' then
    exit;
  Result := 1;
  for i := 1 to Length(Batch) do
    if Batch[i] = LF then
      Inc(Result);
end;

procedure ConPush(const Batch: RawUtf8);
var
  next, records: Integer;
begin
  if (Batch = '') or
     (not ConLockReady) then
    exit;
  ConLock.Lock;
  try
    next := (ConHead + 1) mod PWEB_DEV_CONSOLE_MAX_BATCHES;
    if next = ConTail then
    begin
      // FULL. The authoritative bound: drop the batch, count its records and
      // never block the GUI thread
      records := ConCountRecords(Batch);
      Inc(ConDroppedHost, records);
      Inc(ConDroppedPending, records);
      exit;
    end;
    ConRing[ConHead].Batch := Batch;
    ConHead := next;
  finally
    ConLock.UnLock;
  end;
  if ConWake <> nil then
    ConWake.SetEvent;
end;

procedure PWebDevConsoleCallback(const id: PAnsiChar; const req: PAnsiChar;
  arg: Pointer); cdecl;
var
  params, batch: RawUtf8;
  view: Pointer;
begin
  // an exception barrier, because a Pascal exception may never cross a C
  // callback frame - the ratified rule, and this callback has no completion
  // sink to map a failure onto
  try
    view := ConView;
    if req <> nil then
    begin
      FastSetString(params, req, StrLen(req));
      if PWebDevConsoleDecodeParams(params, batch) then
        ConPush(batch)
      else
        // a payload past its bound, unframed or not valid base64: the WHOLE
        // batch is refused, and nothing partial is ever printed
        Inc(ConRefused);
    end;
    // ALWAYS return: upstream's init script keeps one promise per call and
    // resolves it from here, so a call that never returned would leak one
    // promise per console line
    if (view <> nil) and
       (id <> nil) then
      webview_return(view, id, 0, 'null');
  except
    // deliberately silent: a diagnostic channel that could raise into the
    // engine would be a worse defect than the one it exists to close
  end;
end;

procedure PWebDevConsoleInstall(AView: Pointer);
var
  shim: RawUtf8;
  writerId: system.TThreadID;
  bindErr, initErr: Integer;
begin
  if (AView = nil) or
     ConInstalled then
    exit;
  ConInstalled := True;
  ConView := AView;
  ConHead := 0;
  ConTail := 0;
  ConStop := 0;
  ConLock.Init;
  ConLockReady := True;
  ConWake := TSynEvent.Create;
  ConWriter := BeginThread(@PWebDevConsoleWriterThread, nil, writerId);
  ConWriterStarted := ConWriter <> system.TThreadID(0);
  if not ConWriterStarted then
  begin
    // the channel is a diagnostic; failing to start it must never fail a
    // development session, so it is reported once and disarmed
    ConWrite(ConPrefix + PWEB_DEV_CONSOLE_TAG +
      'unavailable: the writer thread did not start');
    ConView := nil;
    exit;
  end;
  // BIND FIRST, then inject: upstream re-emits every user script when a
  // binding is added, so the shim is added last and cannot be re-ordered
  // away from the function it calls
  bindErr := webview_bind(AView, PWEB_DEV_CONSOLE_BIND,
    @PWebDevConsoleCallback, nil);
  shim := PWebDevConsoleShim;
  initErr := webview_init(AView, pointer(shim));
  // ONE line, once, so "the console said nothing" can be told apart from
  // "the console is not there". A channel that failed to arm and stayed
  // quiet about it would be the defect this shard exists to close, wearing
  // a different hat
  if (bindErr <> 0) or
     (initErr <> 0) then
  begin
    ConWrite(ConPrefix + PWEB_DEV_CONSOLE_TAG + 'unavailable: bind=' +
      RawUtf8(IntToStr(bindErr)) + ' init=' + RawUtf8(IntToStr(initErr)));
    ConView := nil;
  end
  else
    ConWrite(ConPrefix + PWEB_DEV_CONSOLE_TAG + 'armed');
end;

function PWebDevConsoleProbe(Batches, RecordsEach: Integer;
  const Sink: TPWebDevConsoleEmit; out Emitted: Integer;
  out DroppedHost: Int64): Boolean;
var
  b, r: Integer;
  batch: RawUtf8;
  saved: TPWebDevConsoleEmit;
begin
  Emitted := 0;
  DroppedHost := 0;
  Result := False;
  // never beside a live channel: this drives the same ring
  if ConInstalled or
     (not Assigned(Sink)) or
     (Batches <= 0) or
     (RecordsEach <= 0) then
    exit;
  ConHead := 0;
  ConTail := 0;
  ConDroppedHost := 0;
  ConDroppedPending := 0;
  ConLock.Init;
  ConLockReady := True;
  saved := ConEmit;
  ConEmit := Sink;
  try
    for b := 1 to Batches do
    begin
      batch := '';
      for r := 1 to RecordsEach do
      begin
        if batch <> '' then
          batch := batch + LF;
        batch := batch + 'log' + US + 'log' + US + US + 'probe ' +
          RawUtf8(IntToStr(b)) + '/' + RawUtf8(IntToStr(r));
      end;
      ConPush(batch);
    end;
    ConDrain;
  finally
    ConEmit := saved;
    ConLockReady := False;
    ConLock.Done;
  end;
  DroppedHost := ConDroppedHost;
  Emitted := Batches * RecordsEach;
  Result := True;
end;

procedure PWebDevConsoleShutdown;
begin
  if not ConInstalled then
    exit;
  // the GUI loop is already gone when this runs, so no further callback can
  // fire; the view is disowned first anyway, so a late one would return
  // nothing rather than touch a destroyed handle
  ConView := nil;
  InterlockedIncrement(ConStop);
  if ConWake <> nil then
    ConWake.SetEvent;
  if ConWriterStarted then
  begin
    WaitForThreadTerminate(ConWriter, PWEB_DEV_CONSOLE_JOIN_MS);
    CloseThread(ConWriter);
    ConWriterStarted := False;
  end;
  // only after the join: the writer holds a reference to the event until it
  // returns
  FreeAndNil(ConWake);
  if ConLockReady then
  begin
    ConLockReady := False;
    ConLock.Done;
  end;
  ConInstalled := False;
end;

initialization
  // stderr is where a line goes unless the headless probe borrows the seam
  ConEmit := @ConWrite;

end.
