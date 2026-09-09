{
  pweb.assets.htmlpolicy - CAP-14A: what the native CSP will not run.

  PWEB_NATIVE_CSP (src/security/pweb.navigation.policy.pas) carries
  `script-src 'self'` with no 'unsafe-inline' and no 'unsafe-eval'.
  Four HTML constructs are therefore DEAD in a bundle, silently:

    - an inline <script> with an executable type;
    - a <script src=...> that is not same-origin;
    - an on*= event-handler attribute;
    - a javascript: URL.

  An engine reports none of them to the application, so a dist carrying
  one bundles, verifies, builds and runs - and half-works with no error
  anywhere. This unit is the ONE statement of that rule, and
  tools/bundler/pwebbundle.pas is its only caller: the refusal is
  walk-time policy owned by the CLI, exactly as the ratified sourcemap
  exclusion is, so nothing here is linked by a production host.

  `style-src 'self' 'unsafe-inline'` is the other half of the same
  ratified decision, which is why an inline <style> and a style=
  attribute are ACCEPTED. So is every non-executable <script> data
  block - application/json, application/ld+json, text/template and
  anything else the engines do not run.

  ---------------------------------------------------------------------
  THE TOKENIZER
  ---------------------------------------------------------------------

  ONE forward pass over the bytes. No DOM, no full HTML parser, no
  regex, no backtracking, no recursion; every state advances and none
  ever moves left. Attributes are JUDGED AS THEY ARE PARSED rather than
  collected, so a pathological tag cannot grow an array, and at most
  PWEB_HTML_MAX_VIOLATIONS findings are recorded before the scan stops
  with Truncated set - a refused document is refused, and an unbounded
  report is not a better refusal.

  It agrees with the HTML tokenizer where that matters and DIVERGES
  ONLY TOWARDS REFUSAL. Each divergence is named:

    - `<!` that is not `<!--` becomes a bogus comment ending at the
      first `>`. That is the HTML-namespace rule, and it is applied in
      foreign content too: a <script> that is TEXT inside an SVG
      <![CDATA[ ... > ... ]]> section is refused. Refusing text costs a
      diagnostic; missing an element costs the defect this unit exists
      to close.
    - the script-data ESCAPE states are not implemented: a script
      element ends at the first `</script` delimiter. An engine may end
      it later, never earlier, so this scanner can only resume reading
      markup SOONER than the engine does - it can over-refuse, it
      cannot under-refuse.
    - a raw-text element that is never closed is refused
      (bundle_html_unterminated) rather than skipped to EOF, because
      skipping to EOF is the one shape that would hide the rest of a
      document from the scan.
    - a document opening with a UTF-16 byte order mark is refused
      (bundle_html_encoding). The engines decode it as UTF-16 and this
      is a UTF-8 scanner; certifying it would be a guess.

  The comment state seeds its dash counter at TWO, which is the spec's
  abrupt-closing rule: `<!-->` and `<!--->` are complete comments. A
  scanner that missed that would treat `<!--><script>x</script>` as one
  unterminated comment and never see the script - a real bypass, not a
  theoretical one.

  Character references in ATTRIBUTE VALUES are decoded once before any
  URL is judged, because the engines do: `href="java&#9;script:x"` is a
  javascript: URL and `src="&#100;ata:,x"` is a data: URL. Attribute
  NAMES are never entity-decoded, which is also what the engines do.

  ---------------------------------------------------------------------
  WHAT IS DELIBERATELY NOT SCANNED
  ---------------------------------------------------------------------

  Exactly the logical names PWebAssetMimeType resolves to text/html.
  The set is READ from the MIME resolver rather than typed a second
  time, so the scanned set and the served type can never disagree.

  `.svg` is NOT scanned, and that is a measurement rather than an
  oversight: an SVG referenced as an image has scripting disabled by
  the image context, so a handler inside one is inert BY DESIGN rather
  than by CSP, and refusing it would refuse a working dist. An SVG
  navigated to as a document is a case the navigation policy permits
  and no shipped corpus produces.

  Layering: assets layer only - mormot.core.base plus the MIME resolver
  in pweb.assets.support. No filesystem, no archive, no platform type,
  no transport of any kind.
}
unit pweb.assets.htmlpolicy;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base,
  pweb.assets.support;

const
  /// how many findings one document may report before the scan stops
  // - a refused document is refused; the bound is what keeps a hostile
  // input from producing an unbounded diagnostic
  PWEB_HTML_MAX_VIOLATIONS = 64;
  /// ceiling for one decoded attribute value, in bytes
  PWEB_HTML_MAX_ATTR_BYTES = 4096;

type
  /// the typed causes a document can be refused with
  // - the first four are the ratified CSP violation classes; the last
  // two are refusals to JUDGE - the scanner says so rather than
  // certifying a document it cannot read
  TPWebHtmlRefusal = (
    /// <script> with no src and an executable type
    phrInlineScript,
    /// <script src=...> whose URL is not same-origin-relative
    phrExternalScript,
    /// an on*= event-handler attribute
    phrInlineHandler,
    /// a javascript: URL in an attribute value
    phrJavascriptUrl,
    /// the document opens with a UTF-16 byte order mark
    phrHtmlEncoding,
    /// a raw-text element (script/style/textarea/title/noscript) that
    /// is never closed, so the rest of the document cannot be judged
    phrHtmlUnterminated);

  /// one finding, with the line the construct starts on
  TPWebHtmlViolation = record
    Refusal: TPWebHtmlRefusal;
    /// 1-based, counted in line feeds
    Line: Integer;
    /// the attribute name, the script type or the offending scheme -
    // never a slice of the document's own content
    Detail: RawUtf8;
  end;
  TPWebHtmlViolations = array of TPWebHtmlViolation;

/// the machine-stable cause token of a refusal
// - `bundle_inline_script`, `bundle_external_script`,
// `bundle_inline_handler`, `bundle_javascript_url`,
// `bundle_html_encoding`, `bundle_html_unterminated`
function PWebHtmlRefusalCause(Refusal: TPWebHtmlRefusal): RawUtf8;

/// fixed human text for a refusal, naming the CSP term that kills it
function PWebHtmlRefusalText(Refusal: TPWebHtmlRefusal): RawUtf8;

/// is this logical asset name a document the engines parse as HTML?
// - answered by PWebAssetMimeType, never by a second extension table
function PWebHtmlIsDocument(const LogicalPath: RawUtf8): Boolean;

/// HTML's own executable-script-type rule
// - True for an absent attribute, an empty (or whitespace-only) value,
// `module`, `importmap`, and any value whose MIME essence is one of
// the sixteen JavaScript MIME types - so `text/javascript; charset=utf-8`
// is executable and `application/json` is not
function PWebHtmlScriptTypeExecutable(Present: Boolean;
  const Value: RawUtf8): Boolean;

/// may this script src run under `script-src 'self'`?
// - True only for a same-origin-RELATIVE URL: no scheme, and no
// protocol-relative `//` (or its backslash spellings) prefix
// - an ABSOLUTE `pweb://app/...` is refused too, deliberately: a bundle
// names its own assets relatively, the privileged origin is
// native-controlled, and authority parsing is where cross-origin
// acceptance bugs live
// - an empty value is accepted: the engines fire an error event and
// fetch nothing, so it runs nothing and the CSP has no opinion
function PWebHtmlSrcSameOrigin(const Url: RawUtf8): Boolean;

/// what a refused src is refused FOR - its scheme, or `protocol-relative`
function PWebHtmlSrcRefusalDetail(const Url: RawUtf8): RawUtf8;

/// does this attribute value name a javascript: URL?
// - the URL parser's own normalisation first: leading C0 controls and
// spaces are stripped and TAB/LF/CR are dropped throughout, so
// `java&#9;script:x` (decoded) is one
function PWebHtmlIsJavascriptUrl(const Value: RawUtf8): Boolean;

/// is this attribute name an inline event handler?
// - the PREFIX rule: ASCII-lowercased, begins `on`, at least 3 bytes.
// It is deliberately wider than the spec's handler list, because a
// handler a hand-written list forgot is exactly the silent failure
// this unit exists to close; the corpus is measured to carry none
function PWebHtmlIsEventHandler(const Name: RawUtf8): Boolean;

/// decode HTML character references in one attribute value, once
// - numeric (`&#NN;`, `&#xHH;`, semicolon optional as the engines
// allow) plus the named references that can spell a scheme or its
// colon; anything else is left verbatim
// - a code point above U+007F becomes one $FF byte: it can be part of
// neither a scheme nor a colon, and this scanner never re-emits the
// value
function PWebHtmlDecodeAttr(const Value: RawUtf8): RawUtf8;

/// scan one HTML document
// - returns True when the document carries nothing the native CSP
// would refuse to run
// - Truncated is True when PWEB_HTML_MAX_VIOLATIONS was reached and
// the scan stopped early
function PWebHtmlScan(const Content: RawUtf8;
  out Violations: TPWebHtmlViolations; out Truncated: Boolean): Boolean;


implementation

function LowerCh(c: AnsiChar): AnsiChar;
begin
  if c in ['A'..'Z'] then
    Result := AnsiChar(Ord(c) + 32)
  else
    Result := c;
end;

function LowerText(const s: RawUtf8): RawUtf8;
var
  i: PtrInt;
begin
  Result := s;
  for i := 1 to Length(Result) do
    Result[i] := LowerCh(Result[i]);
end;

// the five bytes the HTML tokenizer treats as whitespace
function IsHtmlSpace(c: AnsiChar): Boolean;
begin
  Result := (c = ' ') or (c = #9) or (c = #10) or (c = #12) or (c = #13);
end;

function IsAsciiAlpha(c: AnsiChar): Boolean;
begin
  Result := (c in ['a'..'z']) or (c in ['A'..'Z']);
end;

function PWebHtmlRefusalCause(Refusal: TPWebHtmlRefusal): RawUtf8;
begin
  case Refusal of
    phrInlineScript:
      Result := 'bundle_inline_script';
    phrExternalScript:
      Result := 'bundle_external_script';
    phrInlineHandler:
      Result := 'bundle_inline_handler';
    phrJavascriptUrl:
      Result := 'bundle_javascript_url';
    phrHtmlEncoding:
      Result := 'bundle_html_encoding';
    phrHtmlUnterminated:
      Result := 'bundle_html_unterminated';
  else
    Result := 'bundle_html_refused';
  end;
end;

function PWebHtmlRefusalText(Refusal: TPWebHtmlRefusal): RawUtf8;
begin
  case Refusal of
    phrInlineScript:
      Result := 'inline <script>: script-src ''self'' carries no ' +
        '''unsafe-inline'', so this block never runs';
    phrExternalScript:
      Result := '<script src> is not same-origin: script-src ''self'' ' +
        'refuses it, and a bundle names its own assets relatively';
    phrInlineHandler:
      Result := 'inline event handler: script-src ''self'' carries no ' +
        '''unsafe-inline'', so this handler never fires';
    phrJavascriptUrl:
      Result := 'javascript: URL: script-src ''self'' carries no ' +
        '''unsafe-inline'', so this URL never executes';
    phrHtmlEncoding:
      Result := 'UTF-16 byte order mark: this bundler scans UTF-8 ' +
        'documents and will not certify one it cannot read';
    phrHtmlUnterminated:
      Result := 'raw-text element is never closed: the rest of the ' +
        'document cannot be judged';
  else
    Result := 'refused';
  end;
end;

function PWebHtmlIsDocument(const LogicalPath: RawUtf8): Boolean;
begin
  // the ONE truth for "the engines parse this as a document", read from
  // the resolver that decides what the handler serves it as
  Result := PWebAssetMimeType(LogicalPath) = 'text/html; charset=utf-8';
end;

const
  // the HTML specification's JavaScript MIME type set, verbatim
  JS_MIME: array[0 .. 15] of RawUtf8 = (
    'application/ecmascript',
    'application/javascript',
    'application/x-ecmascript',
    'application/x-javascript',
    'text/ecmascript',
    'text/javascript',
    'text/javascript1.0',
    'text/javascript1.1',
    'text/javascript1.2',
    'text/javascript1.3',
    'text/javascript1.4',
    'text/javascript1.5',
    'text/jscript',
    'text/livescript',
    'text/x-ecmascript',
    'text/x-javascript');

function PWebHtmlScriptTypeExecutable(Present: Boolean;
  const Value: RawUtf8): Boolean;
var
  t: RawUtf8;
  i, first, last: PtrInt;
begin
  Result := True;
  // no type attribute at all is a classic script
  if not Present then
    exit;
  // strip the ASCII whitespace the engines strip
  first := 1;
  last := Length(Value);
  while (first <= last) and
        IsHtmlSpace(Value[first]) do
    Inc(first);
  while (last >= first) and
        IsHtmlSpace(Value[last]) do
    Dec(last);
  if last < first then
    exit; // an empty value is a classic script too
  t := LowerText(Copy(Value, first, last - first + 1));
  if (t = 'module') or
     (t = 'importmap') then
    exit;
  // the MIME ESSENCE: everything before the first ';', trimmed. This is
  // why the rule is not a four-name list - `text/javascript; charset=utf-8`
  // is executable, and a list of four would have run it silently
  i := Pos(';', t);
  if i > 0 then
    t := Copy(t, 1, i - 1);
  last := Length(t);
  while (last >= 1) and
        IsHtmlSpace(t[last]) do
    Dec(last);
  SetLength(t, last);
  for i := 0 to High(JS_MIME) do
    if t = JS_MIME[i] then
      exit;
  Result := False;
end;

// The URL parser's own preamble, and nothing more: leading C0 controls
// and spaces are stripped, then TAB, LF and CR are dropped wherever
// they sit. HasScheme is True when the walk reaches ':' through scheme
// bytes only; Lead carries the first two significant bytes, which is
// all a protocol-relative test needs and all this ever collects - a
// megabyte-long attribute value costs two bytes here.
procedure UrlHead(const Value: RawUtf8; out HasScheme: Boolean;
  out Scheme, Lead: RawUtf8);
var
  i, n: PtrInt;
  c: AnsiChar;
  acc: RawUtf8;

  procedure FillLead;
  begin
    while (i <= n) and
          (Length(Lead) < 2) do
    begin
      c := Value[i];
      Inc(i);
      if (c = #9) or
         (c = #10) or
         (c = #13) then
        continue;
      Lead := Lead + c;
    end;
  end;

begin
  HasScheme := False;
  Scheme := '';
  Lead := '';
  acc := '';
  n := Length(Value);
  i := 1;
  while (i <= n) and
        (Value[i] <= ' ') do
    Inc(i);
  while i <= n do
  begin
    c := Value[i];
    Inc(i);
    if (c = #9) or
       (c = #10) or
       (c = #13) then
      continue;
    if Length(Lead) < 2 then
      Lead := Lead + c;
    if c = ':' then
    begin
      if acc <> '' then
      begin
        Scheme := LowerText(acc);
        HasScheme := True;
      end;
      FillLead;
      exit;
    end;
    if ((acc = '') and IsAsciiAlpha(c)) or
       ((acc <> '') and (IsAsciiAlpha(c) or (c in ['0'..'9']) or
        (c = '+') or (c = '-') or (c = '.'))) then
      acc := acc + c
    else
    begin
      // not a scheme after all: this is a relative reference, and the
      // only thing left worth reading is the second lead byte
      FillLead;
      exit;
    end;
  end;
end;

function PWebHtmlIsJavascriptUrl(const Value: RawUtf8): Boolean;
var
  hasScheme: Boolean;
  scheme, lead: RawUtf8;
begin
  UrlHead(Value, hasScheme, scheme, lead);
  Result := hasScheme and
            (scheme = 'javascript');
end;

function ProtocolRelative(const Lead: RawUtf8): Boolean;
begin
  Result := (Length(Lead) >= 2) and
            ((Lead[1] = '/') or (Lead[1] = '\')) and
            ((Lead[2] = '/') or (Lead[2] = '\'));
end;

function PWebHtmlSrcSameOrigin(const Url: RawUtf8): Boolean;
var
  hasScheme: Boolean;
  scheme, lead: RawUtf8;
begin
  UrlHead(Url, hasScheme, scheme, lead);
  // ANY scheme, pweb: included - see the interface comment
  Result := not hasScheme and
            not ProtocolRelative(lead);
end;

function PWebHtmlSrcRefusalDetail(const Url: RawUtf8): RawUtf8;
var
  hasScheme: Boolean;
  scheme, lead: RawUtf8;
begin
  UrlHead(Url, hasScheme, scheme, lead);
  if hasScheme then
    Result := scheme + ':'
  else if ProtocolRelative(lead) then
    Result := 'protocol-relative'
  else
    Result := 'same-origin';
end;

function PWebHtmlIsEventHandler(const Name: RawUtf8): Boolean;
begin
  Result := (Length(Name) >= 3) and
            (LowerCh(Name[1]) = 'o') and
            (LowerCh(Name[2]) = 'n');
end;

const
  // the named references that can spell a scheme or its colon. Numeric
  // references cover every other character, and a named reference in an
  // attribute value requires its semicolon (the engines' own rule for
  // attributes), so this short table is the whole of what a name buys
  NAMED_REF: array[0 .. 10] of RawUtf8 = (
    'colon', 'Tab', 'NewLine', 'amp', 'AMP', 'lt', 'LT', 'gt', 'GT',
    'quot', 'apos');
  NAMED_CH: array[0 .. 10] of AnsiChar = (
    ':', #9, #10, '&', '&', '<', '<', '>', '>', '"', '''');

function PWebHtmlDecodeAttr(const Value: RawUtf8): RawUtf8;
var
  i, n, j, k, m: PtrInt;
  code, base: Cardinal;
  digits: PtrInt;
  hex, matched: Boolean;
  name: RawUtf8;
  c: AnsiChar;
begin
  Result := '';
  n := Length(Value);
  if n > PWEB_HTML_MAX_ATTR_BYTES then
    n := PWEB_HTML_MAX_ATTR_BYTES;
  i := 1;
  while i <= n do
  begin
    c := Value[i];
    if c <> '&' then
    begin
      Result := Result + c;
      Inc(i);
      continue;
    end;
    j := i + 1;
    if (j <= n) and
       (Value[j] = '#') then
    begin
      Inc(j);
      hex := (j <= n) and
             ((Value[j] = 'x') or (Value[j] = 'X'));
      if hex then
      begin
        Inc(j);
        base := 16;
      end
      else
        base := 10;
      code := 0;
      digits := 0;
      while j <= n do
      begin
        c := Value[j];
        if c in ['0'..'9'] then
          code := code * base + Cardinal(Ord(c) - Ord('0'))
        else if hex and
                (LowerCh(c) in ['a'..'f']) then
          code := code * 16 + Cardinal(Ord(LowerCh(c)) - Ord('a') + 10)
        else
          break;
        Inc(digits);
        Inc(j);
        // THE ACCUMULATOR IS CLAMPED RATHER THAN BOUNDED BY A DIGIT COUNT,
        // and the difference is not cosmetic: nine hex digits overflow a
        // Cardinal, so `&#x10000006A;` would wrap to $6A and this scanner
        // would read a `j` the engines never produce - they map anything
        // above U+10FFFF to U+FFFD. Clamping keeps the two in step, and it
        // keeps the loop bounded by the value rather than by a magic 8
        if code > $10FFFF then
        begin
          code := $10FFFF;
          // consume the rest of the digit run so the reference still ends
          // where the engines end it
          while (j <= n) and
                ((Value[j] in ['0'..'9']) or
                 (hex and (LowerCh(Value[j]) in ['a'..'f']))) do
            Inc(j);
          break;
        end;
      end;
      if digits = 0 then
      begin
        Result := Result + '&';
        Inc(i);
        continue;
      end;
      // the semicolon is OPTIONAL, exactly as the engines allow: they
      // raise a parse error and flush the reference anyway, which is
      // why `&#106avascript:x` is a javascript: URL
      if (j <= n) and
         (Value[j] = ';') then
        Inc(j);
      if (code = 0) or
         (code > 127) then
        Result := Result + #$FF
      else
        Result := Result + AnsiChar(code);
      i := j;
      continue;
    end;
    // a NAMED reference, semicolon required
    k := j;
    while (k <= n) and
          (k - j < 12) and
          (IsAsciiAlpha(Value[k]) or (Value[k] in ['0'..'9'])) do
      Inc(k);
    matched := False;
    if (k <= n) and
       (k > j) and
       (Value[k] = ';') then
    begin
      name := Copy(Value, j, k - j);
      for m := 0 to High(NAMED_REF) do
        if name = NAMED_REF[m] then
        begin
          Result := Result + NAMED_CH[m];
          i := k + 1;
          matched := True;
          break;
        end;
    end;
    if matched then
      continue;
    Result := Result + '&';
    Inc(i);
  end;
end;

function PWebHtmlScan(const Content: RawUtf8;
  out Violations: TPWebHtmlViolations; out Truncated: Boolean): Boolean;
var
  i, n, used: PtrInt;
  line: Integer;
  stopped: Boolean;

  procedure Add(Refusal: TPWebHtmlRefusal; AtLine: Integer;
    const Detail: RawUtf8);
  begin
    if used >= PWEB_HTML_MAX_VIOLATIONS then
    begin
      Truncated := True;
      stopped := True;
      exit;
    end;
    if used >= Length(Violations) then
      SetLength(Violations, used + 16);
    Violations[used].Refusal := Refusal;
    Violations[used].Line := AtLine;
    Violations[used].Detail := Detail;
    Inc(used);
  end;

  // consume one byte, counting line feeds - the ONLY way i ever moves
  procedure Step;
  begin
    if (i <= n) and
       (Content[i] = #10) then
      Inc(line);
    Inc(i);
  end;

  // True when Content[i..] starts with Text (Text already lowercase)
  function Peek(const Text: RawUtf8): Boolean;
  var
    k: PtrInt;
  begin
    Result := False;
    if i + Length(Text) - 1 > n then
      exit;
    for k := 1 to Length(Text) do
      if LowerCh(Content[i + k - 1]) <> Text[k] then
        exit;
    Result := True;
  end;

  // `<!--` has been consumed. Seeding the dash count at two is the
  // spec's abrupt-closing rule; see the unit header for why it matters
  procedure SkipComment;
  var
    dashes: Integer;
  begin
    dashes := 2;
    while i <= n do
    begin
      case Content[i] of
        '-':
          Inc(dashes);
        '>':
          if dashes >= 2 then
          begin
            Step;
            exit;
          end
          else
            dashes := 0;
        '!':
          begin
            if (dashes >= 2) and
               (i + 1 <= n) and
               (Content[i + 1] = '>') then
            begin
              Step;
              Step;
              exit;
            end;
            dashes := 0;
          end;
      else
        dashes := 0;
      end;
      Step;
    end;
  end;

  // a bogus comment / markup declaration / processing instruction:
  // everything to the first '>'
  procedure SkipToGt;
  begin
    while i <= n do
    begin
      if Content[i] = '>' then
      begin
        Step;
        exit;
      end;
      Step;
    end;
  end;

  // raw text (script, style, textarea, title, noscript): to `</name`
  // followed by a delimiter, exactly as the tokenizer ends it. On True
  // i still points at the '<' of that end tag
  function SkipRawText(const Name: RawUtf8): Boolean;
  var
    k, after: PtrInt;
    ok: Boolean;
    d: AnsiChar;
  begin
    Result := False;
    while i <= n do
    begin
      if (Content[i] = '<') and
         (i + 1 <= n) and
         (Content[i + 1] = '/') and
         (i + 1 + Length(Name) <= n) then
      begin
        ok := True;
        for k := 1 to Length(Name) do
          if LowerCh(Content[i + 1 + k]) <> Name[k] then
          begin
            ok := False;
            break;
          end;
        if ok then
        begin
          after := i + 2 + Length(Name);
          if after > n then
            exit; // a truncated end tag leaves the rest unjudged
          d := Content[after];
          if IsHtmlSpace(d) or
             (d = '/') or
             (d = '>') then
          begin
            Result := True;
            exit;
          end;
        end;
      end;
      Step;
    end;
  end;

  // one start or end tag, from the byte after its name. Attributes are
  // JUDGED HERE, one at a time, so nothing accumulates
  procedure ReadTag(const TagName: RawUtf8; IsEnd: Boolean; TagLine: Integer;
    out Terminated: Boolean);
  var
    attrName, raw, value: RawUtf8;
    attrLine: Integer;
    quote: AnsiChar;
    isScript, srcSeen, typeSeen: Boolean;
    srcValue, typeValue: RawUtf8;
    start: PtrInt;
  begin
    Terminated := False;
    isScript := (not IsEnd) and
                (TagName = 'script');
    srcSeen := False;
    typeSeen := False;
    srcValue := '';
    typeValue := '';
    while i <= n do
    begin
      while (i <= n) and
            IsHtmlSpace(Content[i]) do
        Step;
      if i > n then
        break;
      if Content[i] = '>' then
      begin
        Step;
        Terminated := True;
        break;
      end;
      if Content[i] = '/' then
      begin
        // self-closing syntax is READ and then ignored, exactly as the
        // tokenizer ignores it on an HTML-namespace element
        Step;
        continue;
      end;
      attrLine := line;
      start := i;
      while (i <= n) and
            not IsHtmlSpace(Content[i]) and
            (Content[i] <> '=') and
            (Content[i] <> '>') and
            (Content[i] <> '/') do
        Step;
      attrName := LowerText(Copy(Content, start, i - start));
      while (i <= n) and
            IsHtmlSpace(Content[i]) do
        Step;
      raw := '';
      if (i <= n) and
         (Content[i] = '=') then
      begin
        Step;
        while (i <= n) and
              IsHtmlSpace(Content[i]) do
          Step;
        if (i <= n) and
           ((Content[i] = '"') or (Content[i] = '''')) then
        begin
          quote := Content[i];
          Step;
          start := i;
          // a '>' INSIDE a quoted value is content, not the end of the
          // tag - which is the whole reason this is a tokenizer and not
          // a search for '>'
          while (i <= n) and
                (Content[i] <> quote) do
            Step;
          raw := Copy(Content, start, i - start);
          if i <= n then
            Step;
        end
        else
        begin
          start := i;
          while (i <= n) and
                not IsHtmlSpace(Content[i]) and
                (Content[i] <> '>') do
            Step;
          raw := Copy(Content, start, i - start);
        end;
      end;
      if attrName = '' then
        continue;
      if Pos('&', raw) > 0 then
        value := PWebHtmlDecodeAttr(raw)
      else
        value := raw;
      if IsEnd then
        continue; // an end tag's attributes are dropped by the engines
      if PWebHtmlIsEventHandler(attrName) then
        Add(phrInlineHandler, attrLine, attrName)
      else if PWebHtmlIsJavascriptUrl(value) then
        Add(phrJavascriptUrl, attrLine, attrName);
      if stopped then
        exit;
      if isScript then
        if (attrName = 'src') and
           not srcSeen then
        begin
          srcSeen := True;   // duplicates: the engines keep the FIRST
          srcValue := value;
        end
        else if (attrName = 'type') and
                not typeSeen then
        begin
          typeSeen := True;
          typeValue := value;
        end;
    end;
    if not isScript then
      exit;
    if srcSeen then
    begin
      if not PWebHtmlSrcSameOrigin(srcValue) then
        Add(phrExternalScript, TagLine, PWebHtmlSrcRefusalDetail(srcValue));
    end
    else if PWebHtmlScriptTypeExecutable(typeSeen, typeValue) then
      if typeSeen then
        Add(phrInlineScript, TagLine, typeValue)
      else
        Add(phrInlineScript, TagLine, '(no type)');
  end;

var
  tagLine: Integer;
  tagName: RawUtf8;
  isEnd, terminated: Boolean;
  start: PtrInt;
begin
  Violations := nil;
  Truncated := False;
  used := 0;
  stopped := False;
  line := 1;
  i := 1;
  n := Length(Content);
  // a UTF-16 document is one this scanner cannot read, and the engines
  // decode it by its mark whatever the served charset says
  if (n >= 2) and
     (((Content[1] = #$FF) and (Content[2] = #$FE)) or
      ((Content[1] = #$FE) and (Content[2] = #$FF))) then
  begin
    Add(phrHtmlEncoding, 1, 'utf-16');
    SetLength(Violations, used);
    Result := False;
    exit;
  end;
  while (i <= n) and
        not stopped do
  begin
    if Content[i] <> '<' then
    begin
      Step;
      continue;
    end;
    tagLine := line;
    Step; // the '<'
    if i > n then
      break;
    if Peek('!--') then
    begin
      Step;
      Step;
      Step;
      SkipComment;
      continue;
    end;
    if (Content[i] = '!') or
       (Content[i] = '?') then
    begin
      // markup declaration, processing instruction, and - deliberately -
      // <![CDATA[ in both namespaces
      SkipToGt;
      continue;
    end;
    isEnd := Content[i] = '/';
    if isEnd then
      Step;
    if (i > n) or
       not IsAsciiAlpha(Content[i]) then
      continue; // a bare '<' is text
    start := i;
    while (i <= n) and
          not IsHtmlSpace(Content[i]) and
          (Content[i] <> '>') and
          (Content[i] <> '/') do
      Step;
    tagName := LowerText(Copy(Content, start, i - start));
    ReadTag(tagName, isEnd, tagLine, terminated);
    if stopped then
      break;
    if isEnd or
       not terminated then
      continue;
    // RAW TEXT: the content of these five is never markup, so a
    // handler-shaped string inside one is text and must not be judged
    if (tagName = 'script') or
       (tagName = 'style') or
       (tagName = 'textarea') or
       (tagName = 'title') or
       (tagName = 'noscript') then
      if not SkipRawText(tagName) then
      begin
        Add(phrHtmlUnterminated, tagLine, tagName);
        break;
      end;
  end;
  SetLength(Violations, used);
  Result := used = 0;
end;

end.
