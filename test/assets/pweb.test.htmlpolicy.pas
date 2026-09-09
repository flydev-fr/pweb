unit pweb.test.htmlpolicy;

{ mormot.core.test cases for CAP-14A: what the native CSP will not run.

  The defect this suite exists for was measured by an external reviewer
  and cost nobody a red build, which is the problem: a dist whose
  index.html carried an inline <script> packed, verified, built and ran,
  and half of it silently did nothing under `script-src 'self'`. No
  engine reports that. The bundler now does, and this is the corpus that
  says what it reports.

  ONE TABLE drives everything. Each row is an HTML document and the
  exact finding list it must produce - cause, line and detail - so the
  refusal classes, the accept classes and the adversarial tokenizer
  shapes are all the same kind of assertion, and DecisionDigest emits
  the whole table as build/cap7f/html-policy.txt. Its SHA-256 is
  recorded by the CAP-7F emitters as html_policy_digest and required
  IDENTICAL on four targets: every decision here is a pure function of
  bytes, so a target that disagreed would be running a different rule.

  THE ADVERSARIAL ROWS ARE THE POINT. Anyone can write a test that finds
  `<script>alert(1)</script>`. What matters is whether an executable
  script can slip past: an uppercase tag, a newline inside the tag, a
  `>` inside an attribute value, an abruptly-closed comment, a CDATA
  section, a `</script` sequence inside a JSON data block, a tab spelled
  as a character reference in the middle of `javascript:`, a MIME type
  with a charset parameter. Each of those is a row, and each was capable
  of hiding a script from a naive scanner.

  THIS UNIT IS DELIBERATELY OUTSIDE test/cap6/check_cap6_nonetwork.ps1's
  swept set. Proving that a cross-origin script src is refused means
  spelling one, and a fixture written as `'htt' + 'ps://'` to dodge a
  sweep is a sweep that has stopped meaning anything. The sweep covers
  the unit under test; it does not cover the corpus that attacks it.

  Webview-free, bridge-free, filesystem-free apart from the one corpus
  file it writes - so it is headless on all four CI targets. }

{$I mormot.defines.inc}

interface

uses
  sysutils,
  classes,
  mormot.core.base,
  mormot.core.os,
  mormot.core.test,
  pweb.assets.support,
  pweb.assets.htmlpolicy,
  pweb.test.reporoot;

type
  /// CAP-14A HTML policy cases: the refusal classes, the accept
  /// classes, the tokenizer's adversarial shapes and the four-target
  /// decision corpus - all headless
  TTestHtmlPolicy = class(TSynTestCase)
  published
    /// one leg per ratified refusal class
    procedure RefusalClasses;
    /// one leg per accepted class, including Vite's real output shape
    procedure AcceptClasses;
    /// the shapes that could hide an executable script from a scanner
    procedure TokenizerAdversarial;
    /// HTML's own executable-script-type rule, not a four-name list
    procedure ScriptTypeRule;
    /// same-origin-relative src, and every spelling that is not
    procedure SrcOriginRule;
    /// the on* prefix rule and the javascript: URL rule
    procedure HandlerAndJavascriptUrlRules;
    /// exactly the logical names the MIME resolver types as text/html
    procedure DocumentSet;
    /// the report is bounded and the refusal is not
    procedure BoundedReport;
    /// the whole table, emitted for the four-target comparison
    procedure DecisionDigest;
  end;

const
  /// the file the CAP-7F emitters hash into html_policy_digest - the
  // ONE spelling of the path on the Pascal side
  PWEB_CAP14A_DIGEST_FILE = 'build/cap7f/html-policy.txt';

implementation

type
  TPolicyGroup = (pgRefuse, pgAccept, pgAdversarial);

  TPolicyRow = record
    Group: TPolicyGroup;
    Name: RawUtf8;
    Html: RawUtf8;
    /// the findings, canonically `cause@line[detail]` joined by one
    // space; '' means the document is accepted
    Want: RawUtf8;
  end;

const
  LF = #10;

  CORPUS: array[0 .. 53] of TPolicyRow = (
  // ---- the four ratified refusal classes -----------------------------
   (Group: pgRefuse; Name: 'inline_classic';
    Html: '<html><body>' + LF + '<script>window.cfg=1</script>' +
      '</body></html>';
    Want: 'bundle_inline_script@2[(no type)]'),
   (Group: pgRefuse; Name: 'inline_module';
    Html: '<script type="module">import "./x.js"</script>';
    Want: 'bundle_inline_script@1[module]'),
   (Group: pgRefuse; Name: 'inline_importmap';
    Html: '<script type="importmap">{"imports":{}}</script>';
    Want: 'bundle_inline_script@1[importmap]'),
   (Group: pgRefuse; Name: 'inline_text_javascript';
    Html: '<script type="text/javascript">x()</script>';
    Want: 'bundle_inline_script@1[text/javascript]'),
   (Group: pgRefuse; Name: 'external_https';
    Html: '<script src="https://cdn.example.invalid/v.js"></script>';
    Want: 'bundle_external_script@1[https:]'),
   (Group: pgRefuse; Name: 'external_http';
    Html: '<script src="http://cdn.example.invalid/v.js"></script>';
    Want: 'bundle_external_script@1[http:]'),
   (Group: pgRefuse; Name: 'external_protocol_relative';
    Html: '<script src="//cdn.example.invalid/v.js"></script>';
    Want: 'bundle_external_script@1[protocol-relative]'),
   (Group: pgRefuse; Name: 'external_data';
    Html: '<script src="data:text/javascript,alert(1)"></script>';
    Want: 'bundle_external_script@1[data:]'),
   (Group: pgRefuse; Name: 'external_blob';
    Html: '<script src="blob:0f0f"></script>';
    Want: 'bundle_external_script@1[blob:]'),
   (Group: pgRefuse; Name: 'external_module_https';
    Html: '<script type="module" src="https://x.invalid/m.js"></script>';
    Want: 'bundle_external_script@1[https:]'),
   (Group: pgRefuse; Name: 'handler_onload';
    Html: '<body onload="boot()"><p>x</p></body>';
    Want: 'bundle_inline_handler@1[onload]'),
   (Group: pgRefuse; Name: 'handler_unquoted_uppercase';
    Html: '<div ONCLICK=go()>x</div>';
    Want: 'bundle_inline_handler@1[onclick]'),
   (Group: pgRefuse; Name: 'handler_onerror_on_img';
    Html: '<img src="/a.png" onerror="fix()">';
    Want: 'bundle_inline_handler@1[onerror]'),
   (Group: pgRefuse; Name: 'jsurl_href';
    Html: '<a href="javascript:next()">n</a>';
    Want: 'bundle_javascript_url@1[href]'),
   (Group: pgRefuse; Name: 'jsurl_action';
    Html: '<form action="javascript:go()"></form>';
    Want: 'bundle_javascript_url@1[action]'),
   (Group: pgRefuse; Name: 'jsurl_formaction';
    Html: '<button formaction="javascript:go()">b</button>';
    Want: 'bundle_javascript_url@1[formaction]'),
   (Group: pgRefuse; Name: 'jsurl_iframe_src';
    Html: '<iframe src="javascript:parent.x()"></iframe>';
    Want: 'bundle_javascript_url@1[src]'),
   (Group: pgRefuse; Name: 'jsurl_xlink_href';
    Html: '<svg><a xlink:href="javascript:x()"></a></svg>';
    Want: 'bundle_javascript_url@1[xlink:href]'),
   (Group: pgRefuse; Name: 'unterminated_style';
    Html: '<html>' + LF + '<style>body{margin:0}' + LF;
    Want: 'bundle_html_unterminated@2[style]'),
   (Group: pgRefuse; Name: 'unterminated_script';
    Html: '<p>a</p>' + LF + '<script src="/a.js">';
    Want: 'bundle_html_unterminated@2[script]'),
   (Group: pgRefuse; Name: 'one_of_each_in_one_document';
    Html: '<html><body onload="a()">' + LF +
      '<script>b()</script>' + LF +
      '<script src="https://c.invalid/d.js"></script>' + LF +
      '<a href="javascript:e()">f</a>' + LF + '</body></html>';
    Want: 'bundle_inline_handler@1[onload] ' +
      'bundle_inline_script@2[(no type)] ' +
      'bundle_external_script@3[https:] ' +
      'bundle_javascript_url@4[href]'),

  // ---- the accepted classes ------------------------------------------
   (Group: pgAccept; Name: 'same_origin_absolute_path';
    Html: '<script src="/assets/app.js"></script>'; Want: ''),
   (Group: pgAccept; Name: 'same_origin_relative';
    Html: '<script src="assets/app.js"></script>'; Want: ''),
   (Group: pgAccept; Name: 'same_origin_dot_relative';
    Html: '<script src="./assets/app.js"></script>'; Want: ''),
   (Group: pgAccept; Name: 'vite_module_with_src';
    Html: '<script type="module" crossorigin src="/assets/app.js">' +
      '</script>'; Want: ''),
   (Group: pgAccept; Name: 'data_block_json';
    Html: '<script type="application/json">{"a":1}</script>'; Want: ''),
   (Group: pgAccept; Name: 'data_block_ldjson';
    Html: '<script type="application/ld+json">{"@type":"x"}</script>';
    Want: ''),
   (Group: pgAccept; Name: 'data_block_template';
    Html: '<script type="text/template"><b onclick="n()"></b></script>';
    Want: ''),
   (Group: pgAccept; Name: 'data_block_unknown_type';
    Html: '<script type="text/x-config">key = value</script>'; Want: ''),
   (Group: pgAccept; Name: 'inline_style_element';
    Html: '<style>a{background:url(javascript:x)}</style>'; Want: ''),
   (Group: pgAccept; Name: 'style_attribute';
    Html: '<div style="color:red">x</div>'; Want: ''),
   (Group: pgAccept; Name: 'empty_src';
    Html: '<script src=""></script>'; Want: ''),
   (Group: pgAccept; Name: 'stylesheet_link';
    Html: '<link rel="stylesheet" href="/assets/app.css">'; Want: ''),
   (Group: pgAccept; Name: 'query_string_ampersand';
    Html: '<a href="/x?a=1&amp;b=2">y</a>'; Want: ''),

  // ---- the shapes that could hide a script ---------------------------
   (Group: pgAdversarial; Name: 'uppercase_tag_and_attribute';
    Html: '<SCRIPT TYPE="TEXT/JAVASCRIPT">x()</SCRIPT>';
    Want: 'bundle_inline_script@1[TEXT/JAVASCRIPT]'),
   (Group: pgAdversarial; Name: 'newline_inside_tag';
    Html: '<script' + LF + '  type="module"' + LF + '>x()</script>';
    Want: 'bundle_inline_script@1[module]'),
   (Group: pgAdversarial; Name: 'gt_inside_attribute_value';
    Html: '<div data-t="a>b" onclick="c()">y</div>';
    Want: 'bundle_inline_handler@1[onclick]'),
   (Group: pgAdversarial; Name: 'abruptly_closed_comment';
    Html: '<!--><script>alert(1)</script>';
    Want: 'bundle_inline_script@1[(no type)]'),
   (Group: pgAdversarial; Name: 'abruptly_closed_comment_three_dashes';
    Html: '<!---><script>alert(1)</script>';
    Want: 'bundle_inline_script@1[(no type)]'),
   (Group: pgAdversarial; Name: 'comment_hides_script';
    Html: '<!-- <script>alert(1)</script> --><p>ok</p>'; Want: ''),
   (Group: pgAdversarial; Name: 'cdata_then_real_script';
    Html: '<svg><![CDATA[]]></svg><script>x()</script>';
    Want: 'bundle_inline_script@1[(no type)]'),
   (Group: pgAdversarial; Name: 'svg_script_executes_in_html';
    Html: '<svg><script>alert(1)</script></svg>';
    Want: 'bundle_inline_script@1[(no type)]'),
   (Group: pgAdversarial; Name: 'end_tag_sequence_inside_json_block';
    Html: '<script type="application/json">{"a":"</scr"}</script>' +
      '<script src="/a.js"></script>'; Want: ''),
   (Group: pgAdversarial; Name: 'raw_text_noscript_is_not_markup';
    Html: '<noscript><img src=x onerror=y()></noscript>'; Want: ''),
   (Group: pgAdversarial; Name: 'raw_text_title_is_not_markup';
    Html: '<title>a <script>b()</script> c</title>'; Want: ''),
   (Group: pgAdversarial; Name: 'bare_less_than_is_text';
    Html: '<p>a < b and 3<4</p>'; Want: ''),
   (Group: pgAdversarial; Name: 'unquoted_javascript_url';
    Html: '<a href=javascript:alert(1)>x</a>';
    Want: 'bundle_javascript_url@1[href]'),
   (Group: pgAdversarial; Name: 'space_around_the_equals_sign';
    Html: '<div onclick = "x()">y</div>';
    Want: 'bundle_inline_handler@1[onclick]'),
   // A <script> inside a <template> NEVER RUNS - template content is inert
   // until it is cloned, and a script that arrives by cloneNode or innerHTML
   // does not execute - so this is a NAMED OVER-REFUSAL. It is kept, and
   // pinned here rather than left incidental, because the author of such a
   // block believed it would run and it never will, whatever the CSP says.
   (Group: pgAdversarial; Name: 'script_inside_template_over_refused';
    Html: '<template><script>x()</script></template>';
    Want: 'bundle_inline_script@1[(no type)]'),
   // The handler in a template is a DIFFERENT case and refusing it is
   // correct: an on*= attribute survives cloning and fires as a real
   // handler, which `script-src ''self''` then blocks
   (Group: pgAdversarial; Name: 'handler_inside_template_is_a_real_handler';
    Html: '<template><b onclick="x()"></b></template>';
    Want: 'bundle_inline_handler@1[onclick]'),
   // A <base> WOULD make a same-origin-relative src resolve somewhere else,
   // and this scanner does not look at it - because it does not have to.
   // PWEB_NATIVE_CSP carries `base-uri ''none''`, so the element cannot
   // change the document's base URL at all. The row pins the reasoning: if
   // that CSP term ever goes, this accept becomes a hole.
   (Group: pgAdversarial; Name: 'base_element_cannot_redirect_a_relative_src';
    Html: '<base href="//cdn.example.invalid/"><script src="/a.js"></script>';
    Want: ''),
   // A NUL in the tag name makes it `script<U+FFFD>` for every engine - an
   // unknown element whose children are text - so nothing runs and nothing
   // is refused
   (Group: pgAdversarial; Name: 'nul_in_tag_name_is_not_a_script';
    Html: '<script'#0'>x()</script>'; Want: ''),
   // whitespace-only src: the engines strip it to empty, fire an error event
   // and fetch nothing, so it runs nothing and the CSP has no opinion
   (Group: pgAccept; Name: 'whitespace_only_src';
    Html: '<script src="   "></script>'; Want: ''),
   // AN OUT-OF-RANGE NUMERIC REFERENCE, which is where a decoder and an
   // engine can quietly disagree: nine hex digits overflow a 32-bit
   // accumulator, and an unclamped decoder would wrap `&#x10000006A;` to
   // $6A and read a `j` the engines never produce - they map anything above
   // U+10FFFF to U+FFFD. The accumulator is clamped, so this stays what the
   // engines make of it: not a javascript URL
   (Group: pgAdversarial; Name: 'out_of_range_numeric_reference';
    Html: '<a href="&#x10000006A;avascript:alert(1)">x</a>'; Want: ''));

function FindingsOf(const Html: RawUtf8; out Truncated: Boolean): RawUtf8;
var
  v: TPWebHtmlViolations;
  i: PtrInt;
begin
  PWebHtmlScan(Html, v, Truncated);
  Result := '';
  for i := 0 to High(v) do
  begin
    if Result <> '' then
      Result := Result + ' ';
    Result := Result + PWebHtmlRefusalCause(v[i].Refusal) + '@' +
      RawUtf8(IntToStr(v[i].Line)) + '[' + v[i].Detail + ']';
  end;
end;

function Findings(const Html: RawUtf8): RawUtf8;
var
  truncated: Boolean;
begin
  Result := FindingsOf(Html, truncated);
end;

// the UTF-16 fixture is BUILT rather than written as a literal: a
// string constant carrying a byte above $7F is converted by the
// compiler's source-codepage rules, so a literal would reach the
// scanner as UTF-8 and the row would silently test nothing
function Utf16Document(BigEndian: Boolean): RawUtf8;
begin
  SetLength(Result, 6);
  if BigEndian then
  begin
    Result[1] := AnsiChar($FE);
    Result[2] := AnsiChar($FF);
    Result[3] := #0;
    Result[4] := '<';
    Result[5] := #0;
    Result[6] := 'h';
  end
  else
  begin
    Result[1] := AnsiChar($FF);
    Result[2] := AnsiChar($FE);
    Result[3] := '<';
    Result[4] := #0;
    Result[5] := 'h';
    Result[6] := #0;
  end;
end;

procedure TTestHtmlPolicy.RefusalClasses;
var
  i: PtrInt;
begin
  for i := 0 to High(CORPUS) do
    if CORPUS[i].Group = pgRefuse then
      CheckEqual(Findings(CORPUS[i].Html), CORPUS[i].Want,
        string(CORPUS[i].Name));
  // the two refusals to JUDGE, whose fixtures cannot be literals
  CheckEqual(Findings(Utf16Document(False)),
    'bundle_html_encoding@1[utf-16]', 'utf-16 little endian');
  CheckEqual(Findings(Utf16Document(True)),
    'bundle_html_encoding@1[utf-16]', 'utf-16 big endian');
  // every cause is a distinct machine-stable token
  CheckEqual(PWebHtmlRefusalCause(phrInlineScript), 'bundle_inline_script');
  CheckEqual(PWebHtmlRefusalCause(phrExternalScript),
    'bundle_external_script');
  CheckEqual(PWebHtmlRefusalCause(phrInlineHandler),
    'bundle_inline_handler');
  CheckEqual(PWebHtmlRefusalCause(phrJavascriptUrl),
    'bundle_javascript_url');
  CheckEqual(PWebHtmlRefusalCause(phrHtmlEncoding), 'bundle_html_encoding');
  CheckEqual(PWebHtmlRefusalCause(phrHtmlUnterminated),
    'bundle_html_unterminated');
  Check(PWebHtmlRefusalText(phrInlineScript) <>
    PWebHtmlRefusalText(phrExternalScript),
    'two refusals share one diagnostic');
end;

procedure TTestHtmlPolicy.AcceptClasses;
var
  i: PtrInt;
begin
  for i := 0 to High(CORPUS) do
    if CORPUS[i].Group = pgAccept then
      CheckEqual(Findings(CORPUS[i].Html), '', string(CORPUS[i].Name));
end;

procedure TTestHtmlPolicy.TokenizerAdversarial;
var
  i: PtrInt;
begin
  for i := 0 to High(CORPUS) do
    if CORPUS[i].Group = pgAdversarial then
      CheckEqual(Findings(CORPUS[i].Html), CORPUS[i].Want,
        string(CORPUS[i].Name));
end;

procedure TTestHtmlPolicy.ScriptTypeRule;
begin
  // absent, empty and whitespace-only are all classic scripts
  Check(PWebHtmlScriptTypeExecutable(False, ''), 'absent type');
  Check(PWebHtmlScriptTypeExecutable(True, ''), 'empty type');
  Check(PWebHtmlScriptTypeExecutable(True, '  '#9), 'blank type');
  Check(PWebHtmlScriptTypeExecutable(True, 'module'), 'module');
  Check(PWebHtmlScriptTypeExecutable(True, ' MODULE '), 'MODULE trimmed');
  Check(PWebHtmlScriptTypeExecutable(True, 'importmap'), 'importmap');
  // THE ESSENCE RULE, which is why this is not a four-name list: a
  // parameter after the MIME type does not stop an engine running it
  Check(PWebHtmlScriptTypeExecutable(True, 'text/javascript; charset=utf-8'),
    'javascript with a charset parameter');
  Check(PWebHtmlScriptTypeExecutable(True, 'TEXT/JavaScript'),
    'javascript, mixed case');
  Check(PWebHtmlScriptTypeExecutable(True, 'application/ecmascript'),
    'application/ecmascript');
  Check(PWebHtmlScriptTypeExecutable(True, 'text/jscript'), 'text/jscript');
  Check(PWebHtmlScriptTypeExecutable(True, 'text/livescript'),
    'text/livescript');
  Check(PWebHtmlScriptTypeExecutable(True, 'text/javascript1.5'),
    'a versioned javascript type');
  // and the data blocks the engines do not run
  Check(not PWebHtmlScriptTypeExecutable(True, 'application/json'), 'json');
  Check(not PWebHtmlScriptTypeExecutable(True, 'application/ld+json'),
    'ld+json');
  Check(not PWebHtmlScriptTypeExecutable(True, 'text/template'), 'template');
  Check(not PWebHtmlScriptTypeExecutable(True, 'text/x-anything'),
    'an unknown type is a data block');
  Check(not PWebHtmlScriptTypeExecutable(True, 'module/x'),
    'module is a keyword, not a prefix');
end;

procedure TTestHtmlPolicy.SrcOriginRule;
begin
  Check(PWebHtmlSrcSameOrigin('/assets/app.js'), 'path-absolute');
  Check(PWebHtmlSrcSameOrigin('assets/app.js'), 'path-relative');
  Check(PWebHtmlSrcSameOrigin('./a.js'), 'dot-relative');
  Check(PWebHtmlSrcSameOrigin('../a.js'), 'dot-dot-relative');
  Check(PWebHtmlSrcSameOrigin(''), 'an empty src fetches nothing');
  Check(PWebHtmlSrcSameOrigin('?v=1'), 'a bare query');
  Check(not PWebHtmlSrcSameOrigin('https://x.invalid/a.js'), 'https');
  Check(not PWebHtmlSrcSameOrigin('HTTPS://x.invalid/a.js'), 'HTTPS');
  Check(not PWebHtmlSrcSameOrigin('//x.invalid/a.js'), 'protocol-relative');
  Check(not PWebHtmlSrcSameOrigin('\\x.invalid\a.js'), 'backslash pair');
  Check(not PWebHtmlSrcSameOrigin('/\x.invalid/a.js'), 'mixed slash pair');
  Check(not PWebHtmlSrcSameOrigin('data:text/javascript,x'), 'data');
  Check(not PWebHtmlSrcSameOrigin('blob:abc'), 'blob');
  Check(not PWebHtmlSrcSameOrigin('file:///a.js'), 'file');
  // the named over-refusal: an absolute pweb://app URL WOULD run, and is
  // refused anyway, because a bundle names its own assets relatively
  Check(not PWebHtmlSrcSameOrigin('pweb://app/assets/app.js'),
    'an absolute privileged-origin src is refused deliberately');
  CheckEqual(PWebHtmlSrcRefusalDetail('https://x/a.js'), 'https:');
  CheckEqual(PWebHtmlSrcRefusalDetail('//x/a.js'), 'protocol-relative');
  CheckEqual(PWebHtmlSrcRefusalDetail('/a.js'), 'same-origin');
end;

procedure TTestHtmlPolicy.HandlerAndJavascriptUrlRules;
begin
  Check(PWebHtmlIsEventHandler('onclick'), 'onclick');
  Check(PWebHtmlIsEventHandler('ONLOAD'), 'ONLOAD');
  Check(PWebHtmlIsEventHandler('onanythingatall'), 'an unknown on* name');
  // THE PREFIX RULE IS WIDER THAN THE SPEC'S LIST, deliberately: a
  // handler a hand-written list forgot is the silent failure this whole
  // shard exists to close, and the corpus carries no `on`-prefixed
  // attribute that is not a handler
  Check(PWebHtmlIsEventHandler('once'), 'the named over-refusal');
  Check(not PWebHtmlIsEventHandler('on'), 'two bytes is not a handler');
  Check(not PWebHtmlIsEventHandler('href'), 'href');
  Check(not PWebHtmlIsEventHandler('v-on:click'), 'a framework binding');
  Check(PWebHtmlIsJavascriptUrl('javascript:x'), 'plain');
  Check(PWebHtmlIsJavascriptUrl('  JaVaScRiPt:x'), 'space and case');
  Check(PWebHtmlIsJavascriptUrl('java'#9'script:x'), 'an embedded tab');
  Check(PWebHtmlIsJavascriptUrl('java'#10'script:x'), 'an embedded LF');
  Check(not PWebHtmlIsJavascriptUrl('/javascript/app.js'), 'a path');
  Check(not PWebHtmlIsJavascriptUrl('https://x/a'), 'https');
  Check(not PWebHtmlIsJavascriptUrl(''), 'empty');
  // the engines decode character references in an attribute value
  // BEFORE they parse the URL, so this scanner does too
  CheckEqual(PWebHtmlDecodeAttr('java&#9;script:x'), 'java'#9'script:x');
  CheckEqual(PWebHtmlDecodeAttr('&#106avascript:x'), 'javascript:x');
  CheckEqual(PWebHtmlDecodeAttr('&#x6A;avascript:x'), 'javascript:x');
  CheckEqual(PWebHtmlDecodeAttr('a&colon;b'), 'a:b');
  CheckEqual(PWebHtmlDecodeAttr('a&amp;b'), 'a&b');
  CheckEqual(PWebHtmlDecodeAttr('a&notareference;b'), 'a&notareference;b');
  CheckEqual(PWebHtmlDecodeAttr('100% & more'), '100% & more');
  Check(PWebHtmlIsJavascriptUrl(PWebHtmlDecodeAttr('java&#9;script:x')),
    'the decoded tab spelling is a javascript URL');
end;

procedure TTestHtmlPolicy.DocumentSet;
begin
  Check(PWebHtmlIsDocument('index.html'), 'index.html');
  Check(PWebHtmlIsDocument('a/b/c.htm'), 'a nested .htm');
  Check(PWebHtmlIsDocument('INDEX.HTML'), 'case-insensitive extension');
  Check(not PWebHtmlIsDocument('assets/app.js'), 'a script asset');
  Check(not PWebHtmlIsDocument('assets/app.css'), 'a stylesheet');
  Check(not PWebHtmlIsDocument('data/config.json'), 'a json asset');
  // THE NAMED NON-SCOPE. An SVG referenced as an image has scripting
  // disabled by the image context, so a handler inside one is inert by
  // DESIGN rather than by CSP, and refusing it would refuse a working
  // dist. The rule is read from the MIME resolver, so this row also
  // pins that the two can never disagree
  Check(not PWebHtmlIsDocument('assets/logo.svg'), 'an svg is not scanned');
  CheckEqual(PWebAssetMimeType('assets/logo.svg'), 'image/svg+xml');
  Check(not PWebHtmlIsDocument('page.xhtml'),
    'xhtml resolves to the fallback type and is never parsed as a document');
end;

procedure TTestHtmlPolicy.BoundedReport;
var
  hostile, findings: RawUtf8;
  v: TPWebHtmlViolations;
  truncated: Boolean;
  i: PtrInt;
begin
  hostile := '';
  for i := 1 to PWEB_HTML_MAX_VIOLATIONS * 4 do
    hostile := hostile + '<div onclick="x()"></div>' + LF;
  Check(not PWebHtmlScan(hostile, v, truncated),
    'a document with 256 handlers is refused');
  Check(truncated, 'the report says it stopped early');
  CheckEqual(Length(v), PWEB_HTML_MAX_VIOLATIONS,
    'the report is bounded at the ratified ceiling');
  // and the bound is on the REPORT, never on the refusal
  findings := FindingsOf(hostile, truncated);
  Check(findings <> '', 'a truncated report still refuses');
end;

procedure TTestHtmlPolicy.DecisionDigest;
var
  lines: RawUtf8;
  allPass: Boolean;
  i: PtrInt;
  stream: TFileStream;
  root, digestFile: TFileName;

  procedure Emit(const ALine: RawUtf8);
  begin
    lines := lines + ALine + LF; // LF only - the digest crosses OSes
  end;

  procedure Row(const AName, AWant, AGot: RawUtf8);
  begin
    if AGot <> AWant then
    begin
      allPass := False;
      Check(False, 'row ' + string(AName) + ' decided ' + string(AGot));
    end;
    if AGot = '' then
      Emit('decision name=' + AName + ' verdict=accept')
    else
      Emit('decision name=' + AName + ' verdict=refuse findings=' + AGot);
  end;

begin
  // Every line below is a pure decision of a pure function over a fixed
  // table, so the file bytes - and therefore html_policy_digest - are
  // identical on all four targets by construction. A target that
  // disagreed would be running a different rule, which is exactly what
  // the aggregator's equality check is for.
  lines := '';
  allPass := True;
  Emit('schema=1');
  Emit('classes=bundle_external_script,bundle_html_encoding,' +
    'bundle_html_unterminated,bundle_inline_handler,' +
    'bundle_inline_script,bundle_javascript_url');
  Emit('max_violations=' + RawUtf8(IntToStr(PWEB_HTML_MAX_VIOLATIONS)));
  Emit('scanned_mime=text/html; charset=utf-8');
  for i := 0 to High(CORPUS) do
    Row(CORPUS[i].Name, CORPUS[i].Want, Findings(CORPUS[i].Html));
  Row('utf16_le', 'bundle_html_encoding@1[utf-16]',
    Findings(Utf16Document(False)));
  Row('utf16_be', 'bundle_html_encoding@1[utf-16]',
    Findings(Utf16Document(True)));
  if allPass then
    Emit('verdict=PASS')
  else
    Emit('verdict=FAIL');

  root := RepoRootFromExecutable;
  if root = '' then
  begin
    Check(False, 'repository root (webview.lock marker) not found from ' +
      string(Executable.ProgramFilePath) +
      ' - refusing to write the digest corpus at an ambiguous location');
    exit;
  end;
  digestFile := root + TFileName(StringReplace(PWEB_CAP14A_DIGEST_FILE,
    '/', PathDelim, [rfReplaceAll]));
  if not ForceDirectories(ExtractFilePath(digestFile)) then
    Check(False, 'unable to create ' + string(ExtractFilePath(digestFile)))
  else
  begin
    stream := TFileStream.Create(digestFile, fmCreate);
    try
      if lines <> '' then
        stream.WriteBuffer(lines[1], Length(lines));
    finally
      stream.Free;
    end;
  end;

  Check(allPass, 'every html-policy row decided as ratified');
end;

end.
