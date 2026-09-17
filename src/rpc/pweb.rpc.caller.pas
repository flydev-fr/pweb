{
  pweb.rpc.caller - what an application service can own FOR ITS CALLER
  (CAP-16, ledger 12-5).

  The blob data plane (CAP-12B) is owner-scoped by construction: a token
  resolves only for the principal that created it. Its one producer used to
  be the runtime-owned `pweb.fetch`, because an application's mORMot service
  never saw the principal it was serving. pweb.rpc.mormot now publishes that
  principal for the length of each bridged call, and this unit is the
  documented way a service turns bytes into a blob the CALLING page can read
  by URL:

    function TJobs.Snapshot(since: Int64): RawJson;
    ...
      if not PWebCallerBlobPut(FBlobs, log, 'text/plain; charset=utf-8',
           handle, ceiling) then
        ... answer a typed refusal ...
      Result := handle;   // the token, url, size and type object

  IT TAKES NO OWNER, on purpose. The owner is the principal of the native
  context the binding built for this call; the page never names it, and a
  service that wanted a different owner would have to leave this helper to
  get one. A service is native code at the executable's trust level and can
  always hold IBlobStore directly - that is the trust model - but the path
  this unit documents cannot create a blob for anyone but the caller.

  Outside a bridged call - including on a thread the service started - it
  refuses, with the ceiling pbcInvalidOwner, and creates nothing.

  The handle is the SAME JSON object `pweb.fetch` returns in its `blob`
  member, built from the same frozen pweb.blobs.protocol, so both SDKs'
  existing blob handle type reads it unchanged.
}
unit pweb.rpc.caller;

{$mode ObjFPC}{$H+}

interface

uses
  sysutils,
  mormot.core.base,
  mormot.core.json,
  pweb.rpc.mormot,
  pweb.blobs.intf,
  pweb.blobs.protocol;

/// seal Content as a blob OWNED BY THE CALLING PRINCIPAL and answer its handle
// - Handle is `{"token":..,"url":..,"size":..,"type":..}`, the shape the
// fetch door returns; an empty ContentType is sealed as
// PWEB_BLOB_FALLBACK_TYPE, never guessed
// - False with Ceiling naming what refused: pbcInvalidOwner when there is no
// bridged caller on this thread, otherwise the store's own ceiling
function PWebCallerBlobPut(const Store: IBlobStore;
  const Content: RawByteString; const ContentType: RawUtf8;
  out Handle: RawUtf8; out Ceiling: TPWebBlobCeiling): Boolean;

implementation

function PWebCallerBlobPut(const Store: IBlobStore;
  const Content: RawByteString; const ContentType: RawUtf8;
  out Handle: RawUtf8; out Ceiling: TPWebBlobCeiling): Boolean;
var
  owner, token, mime: RawUtf8;
begin
  Result := False;
  Handle := '';
  Ceiling := pbcNone;
  if not PWebCallerPrincipal(owner) then
  begin
    Ceiling := pbcInvalidOwner;
    exit;
  end;
  mime := ContentType;
  if mime = '' then
    mime := PWEB_BLOB_FALLBACK_TYPE;
  if not PWebBlobPut(Store, owner, Content, mime, token, Ceiling) then
    exit;
  Handle := '{"token":"' + token + '"' +
    ',"url":"' + PWebBlobUrl(token) + '"' +
    ',"size":' + RawUtf8(IntToStr(Length(Content))) +
    ',"type":' + QuotedStrJson(mime) + '}';
  Result := True;
end;

end.
