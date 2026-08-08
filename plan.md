**Stack cible : PWeb = FPC/Lazarus + mORMot2 + `webview/webview` + React/Vite ou Pas2JS + bundle interne, avec RPC in-process et aucun serveur réseau en production.**

Je ferais le projet dans cet ordre, avec une règle : **on valide chaque couche isolément avant de construire la suivante**. Le premier objectif n’est pas de fabriquer tout de suite un “Tauri Pascal complet”, mais d’obtenir un noyau suffisamment propre pour ne jamais devoir le réécrire.

### Architecture cible

```text
                         PWeb
                          │
          ┌───────────────┴────────────────┐
          │                                │
      Frontend                         Native Core
          │                                │
 ┌────────┴────────┐                  mORMot2 SOA
 │                 │                       │
React/Vite       Pas2JS              TRestServer.Uri()
 │                 │                       ▲
 └────────┬────────┘                       │
          │                         Invocation Bridge
          ▼                                ▲
     System WebView                        │
          │                                │
     webview/webview ───── webview_bind ───┘
          │
 ┌────────┼────────┐
 │        │        │
Win     macOS    Linux
```

Et en parallèle :

```text
                    IAssetStore
                         │
       ┌─────────────────┼─────────────────┐
       │                 │                 │
    Folder              ZIP               PWB
     DEV                MVP             optimized
                         │
                    ZIP/SynLZ/etc.
```

### Plan d’exécution

| Phase  | Objectif                  | Résultat vérifiable                                     |
| ------ | ------------------------- | ------------------------------------------------------- |
| **0**  | Geler les interfaces      | Aucun code plateforme ne fuit dans le core              |
| **1**  | Binding `webview/webview` | Une fenêtre WebView contrôlée depuis Pascal             |
| **2**  | Binding JS ↔ Pascal       | `await native.invoke()` appelle réellement Pascal       |
| **3**  | Bridge mORMot2            | Une interface SOA est appelée sans HTTP/socket          |
| **4**  | Asset system              | HTML/JS/CSS chargés depuis `IAssetStore`                |
| **5**  | React + Pas2JS SDK        | Deux frontends utilisent exactement le même backend     |
| **6**  | Bundle release            | Application sans fichiers frontend dispersés            |
| **7**  | Cross-platform            | Windows/macOS/Linux derrière le même contrat            |
| **8**  | Capabilities/sécurité     | Le frontend n’accède qu’aux RPC autorisés               |
| **9**  | QuickJS                   | Plugins/scripts utilisant les mêmes services            |
| **10** | CLI/build tooling         | `pweb dev`, `pweb build`, `pweb create`                 |
| **11** | CI/CD upstream            | Détection automatique des changements `webview/webview` |

---

## Phase 0 — figer seulement les abstractions

Avant le binding, je définirais 5 contrats.

```pascal
IWebView
IWebViewBinding
IAssetStore
IInvocationBridge
ICapabilityPolicy
```

Le point essentiel est :

```text
React ───────┐
Pas2JS ──────┼── IWebViewBinding
QuickJS ─────┘
                   │
                   ▼
           IInvocationBridge
                   │
                   ▼
             mORMot2 SOA
```

et :

```text
ZIP ────────┐
Folder ─────┼── IAssetStore ── WebView
PWB ────────┘
```

**Aucune référence à WebView2, WKWebView, ZIP, SynLZ ou React dans ces interfaces.**

C’est le point architectural que je verrouillerais avant tout.

---

## Phase 1 — notre binding `webview/webview`

Premier code réellement écrit :

```text
src/
└── lib/
    ├── pweb.lib.webview.pas
    ├── pweb.lib.webview.types.pas
    └── pweb.lib.webview.errors.pas
```

Binding brut de :

```text
webview_create
webview_destroy
webview_run
webview_terminate
webview_dispatch
webview_set_title
webview_set_size
webview_navigate
webview_set_html
webview_eval
webview_bind
webview_unbind
webview_return
webview_get_native_handle
```

Avec **zéro abstraction mORMot** ici.

Premier test :

```pascal
WebView := webview_create(...);

webview_set_title(WebView, 'PWeb');
webview_set_html(WebView, '<h1>Hello Pascal</h1>');
webview_run(WebView);
```

Gate :

```text
✓ Windows x64
✓ fenêtre
✓ HTML
✓ fermeture propre
✓ erreurs vérifiées
✓ pas de leak évident
```

---

## Phase 2 — le vrai moment intéressant : JS ↔ Pascal

On ajoute :

```text
src/webview/
├── pweb.webview.intf.pas
├── pweb.webview.core.pas
└── pweb.webview.binding.pas
```

Et on veut pouvoir faire depuis JavaScript :

```ts
const result = await nativeInvoke(
  "echo",
  {
    message: "hello"
  }
);
```

Pascal reçoit :

```json
[
  "echo",
  {
    "message": "hello"
  }
]
```

et répond :

```json
{
  "message": "hello"
}
```

Gate extrêmement simple :

```text
JS
 ↓
Pascal
 ↓
JS Promise
```

Tant que cela n’est pas absolument solide, **aucun mORMot**.

---

# Phase 3 — brancher `TRestServer.Uri()`

C’est ici que notre architecture devient réellement intéressante.

```text
Pas2JS / React
      │
      ▼
 nativeInvoke()
      │
      ▼
webview_bind
      │
      ▼
TWebViewInvocationBridge
      │
      ▼
TRestUriParams
      │
      ▼
TRestServer.Uri()
      │
      ▼
mORMot2 SOA
```

On crée par exemple :

```pascal
ICalculatorService = interface(IInvokable)
  ['{...}']

  function Add(A, B: Integer): Integer;
end;
```

et React doit pouvoir écrire :

```ts
const value = await CalculatorService.add(20, 22);
```

Résultat :

```text
42
```

**sans :**

```text
TRestHttpServer
localhost
TCP
HTTP
port
```

Cette phase est le **premier vrai milestone**.

À ce moment-là, le concept du framework est validé.

---

# Phase 4 — `IAssetStore`

Ensuite seulement :

```pascal
IAssetStore = interface
  function Exists(const Path: RawUtf8): Boolean;

  function Read(
    const Path: RawUtf8;
    out Asset: TAssetResponse): Boolean;
end;
```

Premières implémentations :

```text
TFolderAssetStore
TZipAssetStore
```

Le premier nous donne un développement facile :

```text
frontend/dist/
```

Le second valide le packaging :

```text
app.zip
```

Puis :

```text
pweb://app/index.html
pweb://app/assets/app.js
pweb://app/assets/app.css
```

Cette étape demandera notre petite adaptation plateforme pour le resource handler.

Je commencerais **Windows/WebView2 uniquement**, puis généralisation macOS/Linux.

---

# Phase 5 — React ET Pas2JS

À ce moment-là seulement, on ajoute les SDK frontend.

### TypeScript

```text
sdk/typescript/
└── src/
    ├── invoke.ts
    ├── events.ts
    └── window.ts
```

API :

```ts
import { invoke } from "@pweb/runtime";

const result = await invoke<User>(
  "UserService.Get",
  { id: 42 }
);
```

### Pas2JS

```text
sdk/pas2js/
└── pweb.native.pas
```

avec conceptuellement :

```pascal
User := await Native.Invoke(
  'UserService.Get',
  Params
);
```

Le critère fondamental :

```text
React ────┐
          ├──── EXACT SAME RPC ──── mORMot2
Pas2JS ───┘
```

Pas de chemin spécial pour Pas2JS.

---

# Phase 6 — le bundler

Je commencerais volontairement par ZIP.

```text
frontend/dist
       │
       ▼
   pweb pack
       │
       ▼
    app.pwb
```

Mais au début :

```text
app.pwb = ZIP
```

Le nom du format est à nous, l’implémentation interne peut évoluer.

```text
app.pwb
├── manifest.json
├── index.html
└── assets/
```

Avec `TZipRead`.

Ensuite seulement, benchmark :

```text
ZIP
versus
PWB indexed + SynLZ
```

Si ZIP suffit, **on garde ZIP**.

Si nos mesures justifient PWB :

```text
PWB1
├── header
├── index
├── MIME
├── hashes
├── offsets
└── blobs
    ├── stored
    ├── SynLZ
    └── éventuellement autre algo
```

Je ne construirais surtout pas un format propriétaire avant d’avoir une raison mesurée de le faire.

---

# Phase 7 — cross-platform

Ordre :

```text
Windows
   ↓
Linux
   ↓
macOS
```

Pas parce que macOS serait moins important, mais Windows sera notre environnement de développement initial.

Le core reste :

```text
TSystemWebView
```

et seules les extensions assets sont spécifiques :

```text
platform/
├── windows/
│   └── pweb.asset.webview2.pas
│
├── macos/
│   └── pweb.asset.webkit.pas
│
└── linux/
    └── pweb.asset.webkitgtk.pas
```

Tout ce qui est :

```text
RPC
capabilities
mORMot
bundle
frontend
```

reste identique.

---

# Phase 8 — sécurité

Avant de parler plugins, filesystem ou process execution :

```text
ICapabilityPolicy
```

Exemple :

```json
{
  "allow": [
    "settings.read",
    "settings.write",
    "parking.list"
  ]
}
```

Chaque invocation passe alors :

```text
native.invoke()
      │
      ▼
CallerContext
      │
      ▼
CapabilityPolicy
      │
   allowed?
    /   \
  no     yes
  │       │
403      SOA
```

Et surtout :

```text
navigation externe
        │
        X
        │
pas d'accès au bridge natif
```

C’est une phase obligatoire avant de considérer le runtime comme utilisable en production.

---

# Phase 9 — QuickJS

**Seulement maintenant.**

```text
TQuickJSEngine
      │
      ▼
native.invoke()
      │
      ▼
IInvocationBridge
      │
      ▼
ICapabilityPolicy
      │
      ▼
TRestServer.Uri()
```

Le résultat est très propre :

```text
WebView UI
    │
    ├───────────────┐
    │               │
    ▼               ▼
React/Pas2JS     QuickJS plugin
    │               │
    └──────┬────────┘
           ▼
   InvocationBridge
           ▼
       mORMot2
```

QuickJS n’introduit donc **aucune nouvelle architecture RPC**.

---

# Phase 10 — le CLI

Quand le runtime est stabilisé :

```text
pweb.exe
```

Commandes :

```powershell
pweb create MyApp --ui react
pweb create MyApp --ui pas2js

pweb dev
pweb build
pweb run
pweb doctor
```

`pweb dev` :

```text
React:
Vite HMR
+
native EXE

Pas2JS:
pas2js watcher
+
native EXE
```

`pweb build` :

```text
frontend build
      ↓
asset pack
      ↓
FPC compile
      ↓
package
      ↓
release
```

---

# Phase 11 — CI/CD upstream

Deux choses complètement séparées.

Notre CI :

```text
Windows x64
Linux x64
macOS x64
macOS ARM64
```

Et le watcher upstream :

```text
webview/webview latest
        │
        ▼
checkout
        │
        ▼
compile binding
        │
        ▼
ABI/API tests
        │
    ┌───┴───┐
    ▼       ▼
   OK     changed
    │       │
report    report API diff
```

La production reste toujours sur :

```text
pinned upstream version
```

Jamais automatiquement `master`.

---

## Structure de dépôt que je figerais

```text
pweb/
├── src/
│   ├── lib/
│   │   └── pweb.lib.webview.pas
│   │
│   ├── webview/
│   │   ├── pweb.webview.intf.pas
│   │   ├── pweb.webview.core.pas
│   │   └── pweb.webview.binding.pas
│   │
│   ├── rpc/
│   │   ├── pweb.rpc.intf.pas
│   │   └── pweb.rpc.mormot.pas
│   │
│   ├── assets/
│   │   ├── pweb.assets.intf.pas
│   │   ├── pweb.assets.folder.pas
│   │   ├── pweb.assets.zip.pas
│   │   └── pweb.assets.bundle.pas
│   │
│   ├── security/
│   │   └── pweb.capabilities.pas
│   │
│   ├── script/
│   │   └── pweb.script.quickjs.pas
│   │
│   └── platform/
│       ├── windows/
│       ├── linux/
│       └── macos/
│
├── sdk/
│   ├── typescript/
│   └── pas2js/
│
├── tools/
│   ├── pweb/
│   └── bundler/
│
├── examples/
│   ├── 01-hello/
│   ├── 02-js-binding/
│   ├── 03-mormot-rpc/
│   ├── 04-react/
│   ├── 05-pas2js/
│   ├── 06-assets/
│   └── 07-quickjs/
│
├── test/
│   ├── core/
│   ├── rpc/
│   ├── assets/
│   └── integration/
│
└── .github/
    └── workflows/
```

## Le MVP que je viserais

Je ne considérerais pas « MVP » un CLI, QuickJS ou macOS.

**MVP = ces six cases cochées :**

```text
[x] Windows x64
[x] binding webview/webview indépendant
[x] React affiche une vraie UI
[x] native.invoke() fonctionne
[x] native.invoke() atteint un service mORMot via TRestServer.Uri()
[x] les assets production viennent d'une archive, sans HTTP
```

Donc concrètement :

```tsx
const info = await SystemService.getInfo();
```

→ WebView

→ Pascal

→ mORMot2

→ retour React

**avec Wireshark qui ne voit absolument rien.**

À ce moment précis, on a prouvé le concept essentiel. Tout le reste devient de l’industrialisation.

### Chemin critique

```text
Binding C
   ↓
webview_bind
   ↓
InvocationBridge
   ↓
TRestServer.Uri
   ↓
React SDK
   ↓
IAssetStore
   ↓
ZIP
```

Je ne dévierais pas de cette chaîne avant qu’elle fonctionne de bout en bout.

Et je commencerais le code par **Phase 0 + Phase 1**, avec les interfaces définitives et le binding ABI upstream accompagné de ses tests. Ensuite on avance par `continue`, étape par étape, sans écrire 40 unités avant d’avoir exécuté le premier `Hello`.
