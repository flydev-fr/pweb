// The CAP-10B0 fixture frontend. Neutral by design: no framework, no SDK
// import and no bridge call, because CAP-10B0 freezes the scaffolding engine
// and ships no runnable public template. It exists so the engine has real
// text to render, and so the generated corpus has real bytes to compare.

var identity = {
  name: '{{PROJECT_NAME}}',
  version: '{{PROJECT_VERSION}}',
  bundleId: '{{BUNDLE_ID}}',
  ui: '{{UI_KIND}}'
};

document.getElementById('identity').textContent =
  identity.name + ' ' + identity.version + ' (' + identity.ui + ')';
