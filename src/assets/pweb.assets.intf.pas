{
  pweb.assets.intf - PWeb asset store contract (Phase 0 freeze).

  The one ratified place where a mORMot type appears in a Phase 0
  signature: IAssetStore.TryRead is on record verbatim with RawUtf8
  (core-interfaces.md "IAssetStore, settled"). No archive, compression
  or filesystem-path type appears here (must-not-reference column).

  Canonical sources:
    - core-interfaces.md : verbatim TryRead; canonical-path rules;
                           v1 asset policy; additive evolution rule.
    - conventions.md     : source-level compatibility promise.

  Naming note: TAssetResponse deliberately keeps its spec-verbatim
  unprefixed name from core-interfaces.md. Not an oversight - do not
  rename after freeze.
}
unit pweb.assets.intf;

{$mode ObjFPC}{$H+}

interface

uses
  mormot.core.base;

type
  { Response of a successful asset read.

    Evolution rule - ratified (core-interfaces.md): TryRead's signature
    is frozen; this record may grow ADDITIVELY at source level. PWeb v1
    promises source-level API compatibility only - adding a field is
    not claimed to preserve binary ABI between separately compiled
    framework versions.

    v1 asset policy: normal frontend assets (HTML/CSS/JS/icons) are
    fully materialised in Content; large/bulk media is not an ordinary
    bundle asset in v1 and belongs on the blob data plane. }
  TAssetResponse = record
    Content: RawByteString;  // full asset bytes, materialised
    ContentType: RawUtf8;    // MIME type served to the resource handler
  end;

  { Read of a frontend asset by canonical logical path, fail-closed on
    non-canonical input (core-interfaces.md responsibility table).
    Implementations: a dev folder store and a packaged archive store,
    behind this same contract.

    Fail-closed path semantics - ratified (core-interfaces.md
    "Canonical asset paths"). The scheme handler validates and
    canonicalizes first; stores ADDITIONALLY fail closed themselves on
    any non-canonical input rather than trusting the caller:
      - forward slashes only; no empty, '.' or '..' segments
      - no NUL, no backslash, no drive or UNC prefix
      - single percent-decode then validate; encoded and double-encoded
        traversal rejected
      - Windows device names (CON, NUL, COM1, ... including with
        extensions) and alternate-data-stream forms rejected
      - exact case-sensitive matching on EVERY platform: the dev folder
        store must match archive production behaviour, not the
        case-insensitive Windows filesystem
      - invalid or non-shortest-form (overlong) UTF-8 rejected
      - malformed percent-escapes (e.g. '%zz', truncated '%2')
        rejected, never passed through literally
      - segments ending in '.' or ' ' rejected (Windows strips them -
        'app.js.' must not alias 'app.js' in the dev folder store)
      - empty Path and leading/trailing '/' are non-canonical (empty
        segment) and return False
    These enforce the ratified dev-store == archive-store equivalence
    under the fail-closed umbrella. Fail closed means: any violation
    returns False - never an exception, never a "best effort"
    lookup.

    Thread affinity: none required by contract; implementations must
    tolerate concurrent TryRead calls from resource-handler threads.
    Ownership: Asset is a value copy owned by the caller. }
  IAssetStore = interface
    ['{511475EF-4295-4C93-BDB3-C7993383CD50}']
    { Verbatim ratified signature - frozen (core-interfaces.md).
      Returns True and fills Asset iff Path is canonical and the asset
      exists; one lookup, no separate existence probe, no TOCTOU
      window. Returns False for missing assets AND for every
      non-canonical path. }
    function TryRead(
      const Path: RawUtf8;
      out Asset: TAssetResponse): Boolean;
  end;

implementation

end.
