import { createRoot } from "react-dom/client";
/* The canonical CAP-5 acceptance component, imported UNMODIFIED across
 * the example boundary. It still runs the whole CAP-5/CAP-8B corpus and
 * still reports it through example.report; this page adds the CAP-9C2
 * plugin-invisibility corpus beside it on a SECOND channel, so neither
 * verdict can mask the other and examples/04-react needs no edit.
 * build.mjs pins react/react-dom/@pweb/runtime to THIS package's
 * resolution - see the comment there; without it the cross-example
 * import silently produces two React instances. */
import { App } from "../../../04-react/frontend/src/App.js";
import { PluginProbes } from "./PluginProbes.js";

const container = document.getElementById("root");
if (container === null) {
  throw new Error("root container missing");
}
createRoot(container).render(
  <>
    <App />
    <PluginProbes />
  </>,
);
