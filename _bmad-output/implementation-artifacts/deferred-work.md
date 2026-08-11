- source_spec: `_bmad-output/implementation-artifacts/spec-phase-0-contracts.md`
  summary: Phase 1 CI must include the Phase 0 freeze gate — isolation compile of pweb.rpc.intf.pas with zero unit paths, compile of all three contract units, the banned-identifier grep sweep, and the blob-interface-absence check.
  evidence: Verification-gap review confirmed the freeze invariants (RTL-only isolation, frozen wire tables, dependency bans) are currently verified only by one-shot manual runs; nothing committed re-verifies them. CI is ratified to start at Phase 1 (phase-plan.md), so the committed re-runnable gate lands there rather than adding Phase 0 tooling outside the frozen layout.
- source_spec: `_bmad-output/implementation-artifacts/spec-phase-1-cap1-webview-binding.md`
  summary: Upstream's cmake fetches the WebView2 SDK nuget by version with no URL_HASH, leaving an unverified network input to the DLL build; evaluate vendoring or hash-pinning at the next pin review.
  evidence: cmake/webview.cmake:3 at pinned commit cbbdee44 pins version 1.0.1150.38 but relies solely on nuget version immutability for integrity.
- source_spec: `_bmad-output/implementation-artifacts/spec-phase-4-cap4-asset-system.md`
  summary: TZipAssetStore case-collision rejection folds ASCII only; Unicode case pairs (e-acute vs E-acute) are not detected as colliding archive entries.
  evidence: NTFS treats non-ASCII case pairs as equal per its $UpCase table, so such an archive is ambiguous against a folder store, but a faithful fold needs a ratified Unicode-folding decision (ties into CAP-6 bundler validation) rather than an ad-hoc table.
