# Architecture diagrams

Companion to `SPEC.md`. Diagrams only; every claim they carry is also stated in the kernel or another companion.

## System shape

```mermaid
flowchart TD
    PWeb[PWeb] --> FE[Frontend]
    PWeb --> NC[Native Core]

    FE --> React[React / Vite]
    FE --> Pas2JS[Pas2JS]
    React --> WV[System WebView]
    Pas2JS --> WV
    WV --> LIB["webview/webview binding"]
    LIB -- webview_bind --> IB[Invocation Bridge]

    NC --> SOA[mORMot2 SOA]
    SOA --> URI["TRestServer.Uri()"]
    IB --> URI

    LIB --> Win[Windows]
    LIB --> Mac[macOS]
    LIB --> Lin[Linux]
```

## Asset store

```mermaid
flowchart TD
    IAS[IAssetStore] --> Folder["Folder — dev"]
    IAS --> Zip["ZIP — MVP"]
    IAS --> PWB["PWB — optimized, only if benchmarked"]
    PWB --> Codec["ZIP / SynLZ / other"]
```

## What the frozen abstractions buy (Phase 0)

```mermaid
flowchart TD
    React[React] --> B[IWebViewBinding]
    Pas2JS[Pas2JS] --> B
    QuickJS["QuickJS — not a WebView"] --> SCH
    B --> SCH[IInvocationScheduler]
    SCH --> IB[IInvocationBridge]
    IB --> CP[ICapabilityPolicy]
    CP --> SOA[mORMot2 SOA]
```

```mermaid
flowchart LR
    ZIP[ZIP] --> IAS[IAssetStore]
    Folder[Folder] --> IAS
    PWB[PWB] --> IAS
    IAS --> WV[WebView]
```

## Invocation path (CAP-3)

```mermaid
flowchart TD
    FE["Pas2JS / React"] --> NI["nativeInvoke()"]
    NI --> WB[webview_bind]
    WB --> BR[TWebViewInvocationBridge]
    BR --> P[TRestUriParams]
    P --> U["TRestServer.Uri()"]
    U --> SOA[mORMot2 SOA]
```

Explicitly absent from this path: `TRestHttpServer`, localhost, TCP, HTTP, any port.

## One RPC path for every frontend (CAP-5)

```mermaid
flowchart LR
    React[React] --> RPC[EXACT SAME RPC]
    Pas2JS[Pas2JS] --> RPC
    RPC --> M[mORMot2]
```

## Threading (invariant 1)

```mermaid
flowchart TD
    RUN["webview_run() — GUI thread"] --> BIND["webview_bind() callback"]
    BIND -->|"validate, copy, capture context, enqueue"| POOL[Worker pool]
    POOL --> CAPS[capabilities]
    CAPS --> URI["TRestServer.Uri()"]
    URI --> RET["webview_return() — thread-safe"]
    RET --> P[JS Promise]
    POOL -.->|"GUI-affine commands only"| DISP["webview_dispatch()"]
    DISP --> GUI[GUI operation]
```

## Control plane vs data plane (CAP-12)

```mermaid
flowchart TD
    React[React] -->|"RPC / JSON"| M[mORMot]
    M -->|BlobHandle| React
    React --> URL["pweb://blob/{handle}"]
    URL --> PROTO[TWebViewBlobProtocol]
    QJS["QuickJS / native client"] -->|"opaque handle, no URL"| IBS
    PROTO --> IBS[IBlobStore]
    IBS --> Mem[memory]
    IBS --> File[file]
    IBS --> Arch[archive]
    IBS --> Gen[generated stream]
```

```mermaid
flowchart TD
    T[IWebBlobTransport] --> G["generic pweb://"]
    T --> SB["WebView2SharedBuffer — optimization"]
```

## Capability gating (CAP-8)

```mermaid
flowchart TD
    NI["native.invoke() — method + args only"] --> CC["TInvocationContext — built natively"]
    CC --> CP[CapabilityPolicy]
    AM[AppMaximum] --> EFF[EffectiveCapabilities]
    PR[PrincipalCapabilities] --> EFF
    WC[WindowCapabilities] --> EFF
    RG[RuntimeGrants] --> EFF
    EFF --> CP
    CP -->|no| D[403]
    CP -->|yes| SOA[SOA]
```

```mermaid
flowchart LR
    EXT[External navigation] -.->|blocked| BR[Native bridge]
```

## QuickJS adds no new RPC architecture (CAP-9)

```mermaid
flowchart TD
    UI[WebView UI] --> RP["React / Pas2JS"]
    UI --> QJ[QuickJS plugin]
    RP --> IB[InvocationBridge]
    QJ --> IB
    IB --> CP[ICapabilityPolicy]
    CP --> U["TRestServer.Uri()"]
    U --> M[mORMot2]
```

## Build pipeline (CAP-6, CAP-10)

```mermaid
flowchart TD
    D["frontend/dist"] --> PACK["pweb pack"]
    PACK --> PWB[app.pwb]
```

```mermaid
flowchart TD
    FB[frontend build] --> AP[asset pack]
    AP --> FPC[FPC compile]
    FPC --> PKG[package]
    PKG --> REL[release]
```

## Upstream watcher (CAP-11)

```mermaid
flowchart TD
    UP["webview/webview latest"] --> CO[checkout]
    CO --> CB[compile binding]
    CB --> T["ABI / API tests"]
    T -->|OK| R1[report]
    T -->|changed| R2[report API diff]
```

Production always builds against the pinned upstream version, never `master`.

## Critical path

```mermaid
flowchart LR
    A[Binding C] --> B[webview_bind]
    B --> C[InvocationBridge]
    C --> D[TRestServer.Uri]
    D --> E[React SDK]
    E --> F[IAssetStore]
    F --> G[ZIP]
```
