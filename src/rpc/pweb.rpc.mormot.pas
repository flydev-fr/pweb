{
  pweb.rpc.mormot - transport-neutral in-process mORMot bridge.

  The scheduler performs capability authorization before Invoke(). This
  unit deliberately knows nothing about WebViews, the raw C binding, HTTP
  servers or network clients. Interface-service calls are direct
  TRestUriParams -> TRestServer.Uri() operations on scheduler workers.
}
unit pweb.rpc.mormot;

{$mode ObjFPC}{$H+}

interface

uses
  SysUtils,
  Variants,
  mormot.core.base,
  mormot.core.os,
  mormot.core.data,
  mormot.core.json,
  mormot.core.variants,
  mormot.core.interfaces,
  mormot.orm.core,
  mormot.rest.core,
  mormot.rest.server,
  mormot.soa.core,
  pweb.rpc.intf,
  pweb.rpc.support;

type
  TMormotInvocationBridge = class(TInterfacedObject, IInvocationBridge)
  private type
    TCatalogArgument = record
      Name: RawUtf8;
      ValueType: TInterfaceMethodValueType;
      Unsigned64: Boolean;
    end;
    TCatalogArguments = array of TCatalogArgument;
    TCatalogMethod = record
      PublicName: RawUtf8;
      Route: RawUtf8;
      Inputs: TCatalogArguments;
      OutputCount: Integer;
      MethodInfo: PInterfaceMethod;
      IsCustomAnswer: Boolean;
    end;
    TCatalog = array of TCatalogMethod;
  private
    FServer: TRestServer;
    FOwnsServer: Boolean;
    FCatalog: TCatalog;
    procedure BuildCatalog;
    function FindMethod(const AMethod: RawUtf8): Integer;
    function ValidateArguments(const AMethod: TCatalogMethod;
      const AArgs: RawUtf8): Boolean;
    function NormalizeSuccess(const AMethod: TCatalogMethod;
      const ABody: RawUtf8): TPWebInvocationResult;
  public
    { Registration must be complete before construction. The catalog is an
      immutable snapshot; later ServiceRegister calls are unsupported.
      When AOwnsServer is true, ownership transfers only after successful
      construction and the caller must release the bridge after scheduler
      Shutdown has drained all workers. }
    constructor Create(AServer: TRestServer; AOwnsServer: Boolean = True);
    destructor Destroy; override;
    function Invoke(const Context: TInvocationContext;
      const Method: Utf8String; const Args: TPWebJson;
      const Token: ICancellationToken): TPWebInvocationResult;
  end;

implementation

const
  SERVICE_RESULT_PREFIX = '{"result":';

function TrimJsonBounds(const AJson: RawUtf8; out AFirst,
  AAfterLast: PAnsiChar): Boolean;
begin
  Result := False;
  if AJson = '' then
    exit;
  AFirst := PAnsiChar(pointer(AJson));
  AAfterLast := AFirst + Length(AJson);
  while (AFirst < AAfterLast) and (AFirst^ in [#9, #10, #13, ' ']) do
    Inc(AFirst);
  while (AAfterLast > AFirst) and
        (AAfterLast[-1] in [#9, #10, #13, ' ']) do
    Dec(AAfterLast);
  Result := AFirst < AAfterLast;
end;

function StrictJson(const AJson: RawUtf8): Boolean;
var
  first, afterLast, parsed: PAnsiChar;
begin
  if not TrimJsonBounds(AJson, first, afterLast) then
    exit(False);
  parsed := GotoEndJsonItemStrict(first, afterLast);
  if parsed = nil then
    exit(False);
  while (parsed < afterLast) and (parsed^ in [#9, #10, #13, ' ']) do
    Inc(parsed);
  Result := parsed = afterLast;
end;

function IsJsonNull(const AJson: RawUtf8): Boolean;
var
  first, afterLast: PAnsiChar;
begin
  Result := TrimJsonBounds(AJson, first, afterLast) and
    (afterLast - first = 4) and (first[0] = 'n') and
    (first[1] = 'u') and (first[2] = 'l') and (first[3] = 'l');
end;

function StrictObjectOrNull(const AJson: RawUtf8): Boolean;
var
  parsed: Variant;
  doc: PDocVariantData;
  i, j: Integer;
begin
  Result := False;
  if not StrictJson(AJson) then
    exit;
  if IsJsonNull(AJson) then
    exit(True);
  try
    parsed := JsonToVariant(AJson,
      JSON_FAST_FLOAT + [dvoNameCaseSensitive,
        dvoCheckForDuplicatedNames, dvoJsonParseDoNotTryCustomVariants], True);
    if not DocVariantType.IsOfType(parsed) then
      exit;
    doc := _Safe(parsed);
    if doc^.Kind <> dvObject then
      exit;
    for i := 0 to doc^.Count - 2 do
      for j := i + 1 to doc^.Count - 1 do
        if doc^.Names[i] = doc^.Names[j] then
          exit;
    Result := True;
  except
    Result := False;
  end;
end;

function IsIntegerVariant(const AValue: Variant): Boolean;
begin
  case VarType(AValue) and varTypeMask of
    varSmallInt, varInteger, varShortInt, varByte, varWord,
    varLongWord, varInt64, varWord64:
      Result := True;
  else
    Result := False;
  end;
end;

function IsStringVariant(const AValue: Variant): Boolean;
begin
  case VarType(AValue) and varTypeMask of
    varString, varOleStr, varUString:
      Result := True;
  else
    Result := False;
  end;
end;

function DocKindIs(const AValue: Variant; AKind: TDocVariantKind): Boolean;
begin
  Result := DocVariantType.IsOfType(AValue) and (_Safe(AValue)^.Kind = AKind);
end;

function SupportedInputType(AType: TInterfaceMethodValueType): Boolean;
begin
  Result := AType in [imvBoolean, imvInteger, imvCardinal, imvInt64,
    imvDouble, imvDateTime, imvCurrency, imvRawUtf8, imvString,
    imvRawByteString, imvWideString, imvRawJson, imvVariant];
end;

function ArgumentTypeMatches(const AArgument: TMormotInvocationBridge.TCatalogArgument;
  const AValue: Variant): Boolean;
var
  vt: Integer;
  signed: Int64;
  unsigned: QWord;
  convertedCurrency: Currency;
begin
  vt := VarType(AValue) and varTypeMask;
  case AArgument.ValueType of
    imvBoolean:
      Result := vt = varBoolean;
    imvRawUtf8, imvString, imvRawByteString, imvWideString, imvDateTime:
      Result := IsStringVariant(AValue);
    imvInteger:
      begin
        Result := IsIntegerVariant(AValue) and (vt <> varWord64);
        if Result then
        begin
          signed := Int64(AValue);
          Result := (signed >= Low(Integer)) and (signed <= High(Integer));
        end;
      end;
    imvCardinal:
      begin
        Result := IsIntegerVariant(AValue);
        if Result then
        begin
          if vt = varWord64 then
            unsigned := QWord(AValue)
          else
          begin
            signed := Int64(AValue);
            if signed < 0 then
              exit(False);
            unsigned := QWord(signed);
          end;
          Result := unsigned <= High(Cardinal);
        end;
      end;
    imvInt64:
      begin
        Result := IsIntegerVariant(AValue);
        if Result and (vt = varWord64) and not AArgument.Unsigned64 then
          Result := QWord(AValue) <= QWord(High(Int64));
      end;
    imvDouble:
      Result := IsIntegerVariant(AValue) or (vt in [varSingle, varDouble,
        varCurrency]);
    imvCurrency:
      begin
        Result := IsIntegerVariant(AValue) or
          (vt in [varSingle, varDouble, varCurrency]);
        if Result then
          convertedCurrency := Currency(AValue); // range-check conversion
      end;
    imvRawJson, imvVariant:
      Result := True; // the containing document already passed strict JSON
  else
    Result := False; // complex/callback/unknown RTTI is not cataloged
  end;
end;

constructor TMormotInvocationBridge.Create(AServer: TRestServer;
  AOwnsServer: Boolean);
begin
  inherited Create;
  if AServer = nil then
    raise EArgumentNilException.Create('TMormotInvocationBridge server');
  FServer := AServer;
  FOwnsServer := False; // failed construction leaves ownership with caller
  BuildCatalog;
  FOwnsServer := AOwnsServer;
end;

destructor TMormotInvocationBridge.Destroy;
begin
  FCatalog := nil;
  if FOwnsServer then
    FServer.Free;
  FServer := nil;
  inherited Destroy;
end;

procedure TMormotInvocationBridge.BuildCatalog;
var
  i, j, n, argIndex, methodIndex: Integer;
  source: TServiceContainerInterfaceMethod;
  method: PInterfaceMethod;
  tmp: TCatalogMethod;
  supported: Boolean;
begin
  for i := 0 to High(FServer.Services.InterfaceList) do
    if LowerCase(String(FServer.Services.InterfaceList[i].InterfaceName)) =
       String(PWEB_RESERVED_NAMESPACE) then
      raise EServiceException.Create(
        'application service collides with reserved pweb namespace');

  SetLength(FCatalog, 0);
  for i := 0 to High(FServer.Services.InterfaceMethod) do
  begin
    source := FServer.Services.InterfaceMethod[i];
    if source.InterfaceMethodIndex < SERVICE_PSEUDO_METHOD_COUNT then
      continue;
    methodIndex := source.InterfaceMethodIndex - SERVICE_PSEUDO_METHOD_COUNT;
    method := @source.InterfaceService.InterfaceFactory.Methods[methodIndex];
    supported := True;
    if method^.ArgsInputValuesCount <> 0 then
      for argIndex := method^.ArgsInFirst to method^.ArgsInLast do
        if method^.Args[argIndex].IsInput and
           not SupportedInputType(method^.Args[argIndex].ValueType) then
        begin
          supported := False;
          break;
        end;
    if not supported then
      continue; // fail closed: never publish a method we cannot validate fully
    n := Length(FCatalog);
    SetLength(FCatalog, n + 1);
    FCatalog[n].PublicName := source.InterfaceDotMethodName;
    UniqueString(FCatalog[n].PublicName);
    FCatalog[n].Route := FServer.Model.Root + '/' + source.InterfaceDotMethodName;
    UniqueString(FCatalog[n].Route);
    FCatalog[n].MethodInfo := method;
    FCatalog[n].OutputCount := method^.ArgsOutputValuesCount;
    FCatalog[n].IsCustomAnswer :=
      imfResultIsServiceCustomAnswer in method^.Flags;
    SetLength(FCatalog[n].Inputs, method^.ArgsInputValuesCount);
    j := 0;
    if method^.ArgsInputValuesCount <> 0 then
      for argIndex := method^.ArgsInFirst to method^.ArgsInLast do
        if method^.Args[argIndex].IsInput then
        begin
          FCatalog[n].Inputs[j].Name := method^.ArgsName[argIndex];
          UniqueString(FCatalog[n].Inputs[j].Name);
          FCatalog[n].Inputs[j].ValueType := method^.Args[argIndex].ValueType;
          FCatalog[n].Inputs[j].Unsigned64 :=
            vIsQword in method^.Args[argIndex].ValueKindAsm;
          Inc(j);
        end;
  end;
  // Stable lexical order makes the immutable snapshot deterministic even
  // if service registration order changes.
  for i := 1 to High(FCatalog) do
  begin
    tmp := FCatalog[i];
    j := i - 1;
    while (j >= 0) and (FCatalog[j].PublicName > tmp.PublicName) do
    begin
      FCatalog[j + 1] := FCatalog[j];
      Dec(j);
    end;
    FCatalog[j + 1] := tmp;
  end;
end;

function TMormotInvocationBridge.FindMethod(const AMethod: RawUtf8): Integer;
begin
  for Result := 0 to High(FCatalog) do
    if FCatalog[Result].PublicName = AMethod then
      exit;
  Result := -1;
end;

function TMormotInvocationBridge.ValidateArguments(
  const AMethod: TCatalogMethod; const AArgs: RawUtf8): Boolean;
var
  parsed: Variant;
  doc: PDocVariantData;
  options: TDocVariantOptions;
  i, j: Integer;
  found: Boolean;
  seen: array of Boolean;
begin
  Result := False;
  if not StrictJson(AArgs) then
    exit;
  if IsJsonNull(AArgs) then
    exit(Length(AMethod.Inputs) = 0);
  try
    options := JSON_FAST_FLOAT +
      [dvoNameCaseSensitive, dvoCheckForDuplicatedNames,
       dvoJsonParseDoNotTryCustomVariants];
    parsed := JsonToVariant(AArgs, options, True);
    if not DocVariantType.IsOfType(parsed) then
      exit;
    doc := _Safe(parsed);
    if (doc^.Kind <> dvObject) or
       (doc^.Count <> Length(AMethod.Inputs)) then
      exit;
    SetLength(seen, Length(AMethod.Inputs));
    for i := 0 to doc^.Count - 1 do
    begin
      found := False;
      for j := 0 to High(AMethod.Inputs) do
        if doc^.Names[i] = AMethod.Inputs[j].Name then
        begin
          if seen[j] or
             not ArgumentTypeMatches(AMethod.Inputs[j], doc^.Values[i]) then
            exit;
          seen[j] := True;
          found := True;
          break;
        end;
      if not found then
        exit; // includes unknown and wrong-case names
    end;
    for j := 0 to High(seen) do
      if not seen[j] then
        exit;
    Result := True;
  except
    Result := False; // parser/type conversion details are never exposed
  end;
end;

function TMormotInvocationBridge.NormalizeSuccess(
  const AMethod: TCatalogMethod; const ABody: RawUtf8): TPWebInvocationResult;
var
  arrayStart, arrayEnd, itemStart, itemEnd, p: PAnsiChar;
  arrayJson, value, objectJson: RawUtf8;
  parsed: Variant;
begin
  Result := PWebDefaultErrorResult(pecInternalError);
  if not StrictJson(ABody) or
     (Copy(ABody, 1, Length(SERVICE_RESULT_PREFIX)) <> SERVICE_RESULT_PREFIX) then
    exit;
  arrayStart := PAnsiChar(pointer(ABody)) + Length(SERVICE_RESULT_PREFIX);
  if arrayStart^ <> '[' then
    exit;
  arrayEnd := GotoEndJsonItemStrict(arrayStart,
    PAnsiChar(pointer(ABody)) + Length(ABody));
  if arrayEnd = nil then
    exit;
  FastSetString(arrayJson, arrayStart, arrayEnd - arrayStart);
  if AMethod.OutputCount = 0 then
  begin
    if arrayJson <> '[]' then
      exit;
    exit(PWebSuccessResult(PWEB_JSON_NULL));
  end;
  if AMethod.OutputCount = 1 then
  begin
    itemStart := arrayStart + 1;
    while itemStart^ in [#9, #10, #13, ' '] do
      Inc(itemStart);
    itemEnd := GotoEndJsonItemStrict(itemStart, arrayEnd - 1);
    if itemEnd = nil then
      exit;
    p := itemEnd;
    while p^ in [#9, #10, #13, ' '] do
      Inc(p);
    if p^ <> ']' then
      exit; // wrapper arity disagrees with immutable method metadata
    FastSetString(value, itemStart, itemEnd - itemStart);
    exit(PWebSuccessResult(value));
  end;
  try
    parsed := JsonToVariant(arrayJson, JSON_FAST_FLOAT, True);
    if not DocVariantType.IsOfType(parsed) or
       (_Safe(parsed)^.Kind <> dvArray) or
       (_Safe(parsed)^.Count <> AMethod.OutputCount) then
      exit;
    objectJson := AMethod.MethodInfo^.ArgsArrayToObject(
      pointer(arrayJson), {Input=}False);
    if not StrictJson(objectJson) then
      exit;
    Result := PWebSuccessResult(objectJson);
  except
    Result := PWebDefaultErrorResult(pecInternalError);
  end;
end;

function TMormotInvocationBridge.Invoke(const Context: TInvocationContext;
  const Method: Utf8String; const Args: TPWebJson;
  const Token: ICancellationToken): TPWebInvocationResult;
var
  catalogIndex: Integer;
  call: TRestUriParams;
begin
  if (Token <> nil) and Token.IsCancelled then
    exit(PWebDefaultErrorResult(pecCancelled));
  if not PWebValidMethod(Method) then
    exit(PWebDefaultErrorResult(pecInvalidRequest));
  if Method = PWEB_METHOD_ECHO then
  begin
    if not StrictObjectOrNull(Args) then
      exit(PWebDefaultErrorResult(pecInvalidRequest));
    exit(PWebSuccessResult(Args));
  end;
  if Method = PWEB_METHOD_HANDSHAKE then
  begin
    if not StrictObjectOrNull(Args) then
      exit(PWebDefaultErrorResult(pecInvalidRequest));
    exit(PWebSuccessResult('{"protocol":' +
      Utf8String(IntToStr(PWEB_PROTOCOL_VERSION)) + ',"runtime":"' +
      PWEB_RUNTIME_VERSION + '","capabilities":' +
      JsonEncodeArrayUtf8(Context.Capabilities) + '}'));
  end;
  if Copy(Method, 1, Length(PWEB_RESERVED_NAMESPACE) + 1) =
     PWEB_RESERVED_NAMESPACE + '.' then
    exit(PWebDefaultErrorResult(pecMethodNotFound));
  catalogIndex := FindMethod(Method);
  if catalogIndex < 0 then
    exit(PWebDefaultErrorResult(pecMethodNotFound));
  if not ValidateArguments(FCatalog[catalogIndex], Args) then
    exit(PWebDefaultErrorResult(pecInvalidRequest));
  if (Token <> nil) and Token.IsCancelled then
    exit(PWebDefaultErrorResult(pecCancelled));

  try
    call.Init(FCatalog[catalogIndex].Route, 'POST',
      JSON_CONTENT_TYPE_HEADER, Args);
    call.RestAccessRights := @SUPERVISOR_ACCESS_RIGHTS;
    Include(call.LowLevelConnectionFlags, llfInProcess);
    UniqueRawUtf8(call.InBody); // mORMot parses the body in place
    FServer.Uri(call);          // synchronous, cooperative boundary
    if call.OutStatus = HTTP_SUCCESS then
      Result := NormalizeSuccess(FCatalog[catalogIndex], call.OutBody)
    else if (call.OutStatus = HTTP_UNPROCESSABLE_CONTENT) and
            FCatalog[catalogIndex].IsCustomAnswer and
            StrictJson(call.OutBody) then
      Result := PWebErrorResult(pecServiceError,
        PWEB_DEFAULT_ERROR_MESSAGE[pecServiceError], call.OutBody)
    else
      Result := PWebDefaultErrorResult(pecInternalError);
  except
    // CAP-3U allows service exceptions to unwind safely; no exception text,
    // class name, mORMot envelope, route or stack detail crosses this boundary.
    Result := PWebDefaultErrorResult(pecInternalError);
  end;
end;

end.
