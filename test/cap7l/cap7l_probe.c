/*
 * CAP-7L reference proof of the Linux seam, in C.
 *
 * The Linux analogue of test/cap4w/cap4w_probe.cpp, and it exists for the
 * same reason: before the Pascal adapter is believed, the seam itself is
 * proven from a language with no Pascal runtime in the picture, against the
 * pinned webview C ABI and the ratified WebKitGTK stack. If this probe fails,
 * the defect is in the seam or the engine, not in pweb.platform.webkitgtk.
 *
 * What it proves, per cycle, in one real GTK/WebKitGTK window on a real
 * (virtual) display:
 *
 *   L4/L22   create -> title/size -> bind -> navigate -> RPC -> terminate ->
 *            destroy, repeatable, with every callback disowned and every
 *            worker drained before the native state dies
 *   L5/L6/L7 the bind callback runs on the GUI thread; the service runs on a
 *            worker; the worker calls webview_return DIRECTLY (never through
 *            webview_dispatch) and the JS promise still resolves
 *   L8       concurrent invocations all complete exactly once
 *   L9/L10   pweb://app/ HTML renders and its CSS/JS subresources load, with
 *            computed style proving the CSS actually applied
 *   L11      pweb://evil/x and an empty authority reach the handler and are
 *            REFUSED there - error finish, no body. On GTK a URI scheme is
 *            registered scheme-WIDE, so unlike the WebView2 filter a wrong
 *            authority really does arrive at the handler; refusing it is
 *            exactly why the full URI, and never the path, is validated.
 *   L13      location.protocol == "pweb:", location.host == "app",
 *            location.origin == "pweb://app", isSecureContext === true -
 *            stated by JavaScript, never inferred from "it rendered"
 *   L21      terminate with invocations in flight completes gracefully and
 *            exactly once
 *
 * The seam is the PUBLIC one - webview_get_native_handle(BROWSER_CONTROLLER)
 * -> WebKitWebView* -> WebKitWebContext* - so deps/webview stays unpatched
 * and its export surface stays at exactly 17.
 *
 * Usage: cap7l_probe [cycles 1..20]
 */

#define _GNU_SOURCE

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <glib.h>
#include <gio/gio.h>
#include <webkit2/webkit2.h>

#include "webview/api.h"

#define PROBE_SCHEME "pweb"
#define PROBE_MAIN_URI "pweb://app/probe"
#define PROBE_JS_URI "pweb://app/probe.js"
#define PROBE_CSS_URI "pweb://app/probe.css"
#define PROBE_ECHOES 8
#define PROBE_TIMEOUT_SECONDS 40
#define PROBE_DRAIN_SECONDS 10

static const char kHtml[] =
    "<!doctype html><html><head><meta charset=\"utf-8\">"
    "<title>CAP-7L</title>"
    "<link rel=\"stylesheet\" href=\"/probe.css\"></head>"
    "<body><main id=\"verdict\">CAP-7L PENDING</main>"
    "<script src=\"/probe.js\"></script></body></html>";

static const char kCss[] = "#verdict{color:rgb(1, 2, 3)}";

/* The page STATES every fact it is asked about; nothing here is inferred
 * from the mere fact that something rendered. */
static const char kJs[] =
    "(async () => {"
    "  const out = {};"
    "  try {"
    "    out.protocol = location.protocol;"
    "    out.host = location.host;"
    "    out.origin = location.origin;"
    "    out.secure = window.isSecureContext === true;"
    "    const node = document.getElementById('verdict');"
    "    out.css = getComputedStyle(node).color === 'rgb(1, 2, 3)';"
    "    const echoes = [];"
    "    for (let i = 0; i < 8; i++) { echoes.push(window.__cap7l_echo(i)); }"
    "    const values = await Promise.all(echoes);"
    "    out.concurrency = values.length === 8 &&"
    "      values.every((v, i) => Number(v) === i * 2 + 1);"
    "    const blocked = async (u) => {"
    "      try { const r = await fetch(u); return r.ok === false; }"
    "      catch (e) { return true; }"
    "    };"
    "    out.wronghost = await blocked('pweb://evil/x');"
    "    out.emptyhost = await blocked('pweb:///x');"
    "    out.notfound = await blocked('pweb://app/missing.txt');"
    "    const ok = await fetch('pweb://app/probe.css');"
    "    out.subresource = ok.ok === true;"
    "    out.ok = out.protocol === 'pweb:' && out.host === 'app' &&"
    "      out.origin === 'pweb://app' && out.secure && out.css &&"
    "      out.concurrency && out.wronghost && out.emptyhost &&"
    "      out.notfound && out.subresource;"
    "    node.textContent = out.ok ? 'CAP-7L PASS' : 'CAP-7L FAIL';"
    "  } catch (e) {"
    "    out.ok = false;"
    "    out.error = String(e);"
    "  }"
    // the object, NOT JSON.stringify(out): webview serialises the argument
    // itself, so passing a string would arrive double-encoded ("\"ok\":true")
    // and every substring check below would silently miss
    "  window.__cap7l_report(out);"
    "})();";

struct probe_state {
  webview_t webview;

  /* The disownable registration cell - the same model the Pascal adapter
     uses, because WebKitGTK 4.1 has no way to unregister a URI scheme: the
     callback is made inert rather than removed. */
  struct probe_registration *registration;

  pthread_mutex_t mutex;
  pthread_cond_t wake;

  int finished; /* the page reported, or the run loop ended */
  int failed;
  int passed;

  unsigned main_requests;
  unsigned js_requests;
  unsigned css_requests;
  unsigned refused_requests;

  unsigned echo_returns;   /* atomic */
  unsigned pending_workers; /* atomic */

  unsigned long gui_thread;
  int worker_was_distinct; /* atomic-ish: written by workers, read after join */

  char failure[512];
  char report[4096];
};

struct probe_registration {
  struct probe_state *owner; /* NULL once disowned */
};

struct echo_job {
  webview_t webview;
  struct probe_state *state;
  char *id;
  long value;
};

static void probe_fail(struct probe_state *state, const char *message) {
  pthread_mutex_lock(&state->mutex);
  if (!state->failed) {
    state->failed = 1;
    snprintf(state->failure, sizeof(state->failure), "%s", message);
  }
  pthread_cond_broadcast(&state->wake);
  pthread_mutex_unlock(&state->mutex);
}

/* --- the pweb scheme handler -------------------------------------------- */

static void probe_finish_refused(WebKitURISchemeRequest *request) {
  GError *error = g_error_new_literal(g_quark_from_static_string("cap7l"), 1,
                                      "cap7l asset unavailable");
  if (error == NULL) {
    return;
  }
  webkit_uri_scheme_request_finish_error(request, error);
  g_error_free(error);
}

static void probe_finish_body(WebKitURISchemeRequest *request, const char *body,
                              const char *content_type) {
  const gsize size = (gsize)strlen(body);
  gpointer copy = g_try_malloc(size > 0 ? size : 1);
  GInputStream *stream = NULL;

  if (copy == NULL) {
    probe_finish_refused(request);
    return;
  }
  memcpy(copy, body, size);
  /* ownership moves to GIO, exactly as in the Pascal adapter: nothing the
     page receives may point at this frame */
  stream = g_memory_input_stream_new_from_data(copy, (gssize)size, g_free);
  if (stream == NULL) {
    g_free(copy);
    probe_finish_refused(request);
    return;
  }
  webkit_uri_scheme_request_finish(request, stream, (gint64)size, content_type);
  g_object_unref(stream);
}

static void probe_scheme_request(WebKitURISchemeRequest *request,
                                 gpointer user_data) {
  struct probe_registration *registration =
      (struct probe_registration *)user_data;
  struct probe_state *state = NULL;
  const gchar *uri = NULL;

  if ((registration == NULL) || (registration->owner == NULL)) {
    probe_finish_refused(request); /* disowned: fail closed, never serve */
    return;
  }
  state = registration->owner;

  /* THE URI IS THE WHOLE URI. webkit_uri_scheme_request_get_path() is
     deliberately never called: MEASURED, it returns "/x" for
     "pweb://evil/x", which would hand a wrong-authority request through as
     if it named a legitimate asset. */
  uri = webkit_uri_scheme_request_get_uri(request);
  if (uri == NULL) {
    probe_finish_refused(request);
    return;
  }
  if (strcmp(uri, PROBE_MAIN_URI) == 0) {
    state->main_requests++;
    probe_finish_body(request, kHtml, "text/html; charset=utf-8");
  } else if (strcmp(uri, PROBE_JS_URI) == 0) {
    state->js_requests++;
    probe_finish_body(request, kJs, "text/javascript; charset=utf-8");
  } else if (strcmp(uri, PROBE_CSS_URI) == 0) {
    state->css_requests++;
    probe_finish_body(request, kCss, "text/css; charset=utf-8");
  } else {
    /* wrong authority, empty authority and missing asset are ONE outcome:
       a constant error finish, no body, no reason */
    state->refused_requests++;
    probe_finish_refused(request);
  }
}

/* MEASURED: webkit_web_context_register_uri_scheme refuses a SECOND
 * registration of the same scheme on the same context -
 *   CRITICAL: Cannot register URI scheme pweb more than once
 * - and WebKitGTK 4.1 has no unregister call. Upstream creates its views
 * on the shared default context, so cycle 2 onwards must RE-OWN the cell
 * installed by cycle 1 rather than registering again. This is the same
 * constraint, and the same remedy, that pweb.platform.webkitgtk
 * implements with its PWebGtkCells table. */
static struct probe_registration *g_registration = NULL;
static WebKitWebContext *g_registered_context = NULL;

static void probe_registration_destroyed(gpointer data) {
  if (data == (gpointer)g_registration) {
    g_registration = NULL;
    g_registered_context = NULL;
  }
  g_free(data);
}

/* --- bindings ------------------------------------------------------------ */

static void *echo_worker(void *argument) {
  struct echo_job *job = (struct echo_job *)argument;
  char result[64];

  if ((unsigned long)pthread_self() != job->state->gui_thread) {
    job->state->worker_was_distinct = 1;
  }
  /* The frozen threading model: a worker resolves by calling webview_return
     DIRECTLY. Never wrapped in webview_dispatch. Upstream forwards it through
     its own dispatch internally, so no GTK call runs on this thread. */
  snprintf(result, sizeof(result), "%ld", job->value * 2 + 1);
  if (webview_return(job->webview, job->id, 0, result) < WEBVIEW_ERROR_OK) {
    probe_fail(job->state, "worker webview_return failed");
  }
  __atomic_fetch_add(&job->state->echo_returns, 1u, __ATOMIC_SEQ_CST);
  free(job->id);
  __atomic_fetch_sub(&job->state->pending_workers, 1u, __ATOMIC_SEQ_CST);
  free(job);
  return NULL;
}

static void echo_binding(const char *id, const char *req, void *argument) {
  struct probe_state *state = (struct probe_state *)argument;
  struct echo_job *job = NULL;
  pthread_t thread;

  /* GUI-affine and copy-only: id and req are valid ONLY for this call */
  if ((unsigned long)pthread_self() != state->gui_thread) {
    probe_fail(state, "bind callback did not run on the GUI thread");
    return;
  }
  job = (struct echo_job *)calloc(1, sizeof(*job));
  if (job == NULL) {
    probe_fail(state, "echo job allocation failed");
    return;
  }
  job->webview = state->webview;
  job->state = state;
  job->id = strdup(id);
  job->value = (req != NULL) ? strtol(req + 1, NULL, 10) : -1;
  if (job->id == NULL) {
    free(job);
    probe_fail(state, "echo id copy failed");
    return;
  }
  __atomic_fetch_add(&state->pending_workers, 1u, __ATOMIC_SEQ_CST);
  if (pthread_create(&thread, NULL, echo_worker, job) != 0) {
    __atomic_fetch_sub(&state->pending_workers, 1u, __ATOMIC_SEQ_CST);
    free(job->id);
    free(job);
    probe_fail(state, "echo worker thread could not start");
    return;
  }
  pthread_detach(thread);
}

static void report_binding(const char *id, const char *req, void *argument) {
  struct probe_state *state = (struct probe_state *)argument;

  if ((unsigned long)pthread_self() != state->gui_thread) {
    probe_fail(state, "report callback did not run on the GUI thread");
    return;
  }
  if (req != NULL) {
    snprintf(state->report, sizeof(state->report), "%s", req);
  }
  state->passed = (req != NULL) && (strstr(req, "\"ok\":true") != NULL);
  webview_return(state->webview, id, 0, "null");

  pthread_mutex_lock(&state->mutex);
  state->finished = 1;
  pthread_cond_broadcast(&state->wake);
  pthread_mutex_unlock(&state->mutex);
  webview_terminate(state->webview);
}

/* --- watchdog ------------------------------------------------------------ */

static void terminate_on_gui_thread(webview_t webview, void *argument) {
  (void)argument;
  webview_terminate(webview);
}

static void *watchdog(void *argument) {
  struct probe_state *state = (struct probe_state *)argument;
  struct timespec deadline;
  int timed_out = 0;

  clock_gettime(CLOCK_REALTIME, &deadline);
  deadline.tv_sec += PROBE_TIMEOUT_SECONDS;

  pthread_mutex_lock(&state->mutex);
  while (!state->finished && !state->failed) {
    if (pthread_cond_timedwait(&state->wake, &state->mutex, &deadline) ==
        ETIMEDOUT) {
      timed_out = 1;
      break;
    }
  }
  pthread_mutex_unlock(&state->mutex);

  if (timed_out) {
    probe_fail(state, "runtime probe timeout");
    /* cross-thread shutdown travels worker -> dispatch -> terminate */
    webview_dispatch(state->webview, terminate_on_gui_thread, NULL);
  }
  return NULL;
}

/* --- one cycle ----------------------------------------------------------- */

static int drain_workers(struct probe_state *state) {
  int waited_ms = 0;
  while (__atomic_load_n(&state->pending_workers, __ATOMIC_SEQ_CST) != 0u) {
    struct timespec nap = {0, 5 * 1000 * 1000};
    nanosleep(&nap, NULL);
    waited_ms += 5;
    if (waited_ms > PROBE_DRAIN_SECONDS * 1000) {
      return 0;
    }
  }
  return 1;
}

static int run_cycle(unsigned cycle) {
  struct probe_state state;
  struct probe_registration *registration = NULL;
  WebKitWebView *view = NULL;
  WebKitWebContext *context = NULL;
  WebKitSecurityManager *security = NULL;
  webview_t webview = NULL;
  pthread_t dog;
  int dog_started = 0;
  int ok = 0;
  void *controller = NULL;

  memset(&state, 0, sizeof(state));
  pthread_mutex_init(&state.mutex, NULL);
  pthread_cond_init(&state.wake, NULL);
  state.gui_thread = (unsigned long)pthread_self();

  webview = webview_create(0, NULL);
  if (webview == NULL) {
    /* the no-display condition: NULL, never a code (c_api_impl discards it) */
    fprintf(stderr, "CAP7L_FAIL cycle=%u operation=webview_create\n", cycle);
    pthread_cond_destroy(&state.wake);
    pthread_mutex_destroy(&state.mutex);
    return 0;
  }
  state.webview = webview;

  controller = webview_get_native_handle(
      webview, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER);
  if (controller == NULL) {
    probe_fail(&state, "borrowed browser controller unavailable");
    goto teardown;
  }
  /* on GTK the browser controller IS the WebKitWebView */
  view = (WebKitWebView *)controller;
  context = webkit_web_view_get_context(view);
  if (context == NULL) {
    probe_fail(&state, "WebKitWebContext unavailable");
    goto teardown;
  }
  security = webkit_web_context_get_security_manager(context);
  if (security == NULL) {
    probe_fail(&state, "WebKitSecurityManager unavailable");
    goto teardown;
  }
  /* classification BEFORE registration and before any navigation */
  webkit_security_manager_register_uri_scheme_as_secure(security,
                                                        PROBE_SCHEME);
  webkit_security_manager_register_uri_scheme_as_cors_enabled(security,
                                                              PROBE_SCHEME);

  if ((g_registration != NULL) && (g_registered_context == context)) {
    registration = g_registration; /* re-own, never re-register */
    __atomic_store_n(&registration->owner, &state, __ATOMIC_SEQ_CST);
  } else {
    registration =
        (struct probe_registration *)g_malloc0(sizeof(*registration));
    registration->owner = &state;
    g_registration = registration;
    g_registered_context = context;
    webkit_web_context_register_uri_scheme(context, PROBE_SCHEME,
                                           probe_scheme_request, registration,
                                           probe_registration_destroyed);
  }
  state.registration = registration;

  if (webview_set_title(webview, "CAP-7L probe") < WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_set_title failed");
    goto teardown;
  }
  if (webview_set_size(webview, 800, 600, WEBVIEW_HINT_NONE) <
      WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_set_size failed");
    goto teardown;
  }
  if (webview_bind(webview, "__cap7l_echo", echo_binding, &state) <
      WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_bind(__cap7l_echo) failed");
    goto teardown;
  }
  if (webview_bind(webview, "__cap7l_report", report_binding, &state) <
      WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_bind(__cap7l_report) failed");
    goto teardown;
  }
  if (webview_navigate(webview, PROBE_MAIN_URI) < WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_navigate failed");
    goto teardown;
  }

  if (pthread_create(&dog, NULL, watchdog, &state) != 0) {
    probe_fail(&state, "watchdog thread could not start");
    goto teardown;
  }
  dog_started = 1;

  if (webview_run(webview) < WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_run failed");
  }

teardown:
  /* release the watchdog whatever happened */
  pthread_mutex_lock(&state.mutex);
  state.finished = 1;
  pthread_cond_broadcast(&state.wake);
  pthread_mutex_unlock(&state.mutex);
  if (dog_started) {
    pthread_join(dog, NULL);
  }

  /* L21: never destroy while an invocation is still in flight - a worker
     calling webview_return into destroyed state is exactly the failure this
     ordering exists to prevent */
  if (!drain_workers(&state)) {
    probe_fail(&state, "outstanding invocations did not drain");
  }

  webview_unbind(webview, "__cap7l_echo");
  webview_unbind(webview, "__cap7l_report");

  /* disown BEFORE destroy: the scheme callback cannot be unregistered, so it
     must be unable to reach this frame's state afterwards */
  if (registration != NULL) {
    __atomic_store_n(&registration->owner, (struct probe_state *)NULL,
                     __ATOMIC_SEQ_CST);
    state.registration = NULL;
  }

  if (webview_destroy(webview) < WEBVIEW_ERROR_OK) {
    probe_fail(&state, "webview_destroy failed");
  }

  if (!state.failed) {
    if (!state.passed) {
      probe_fail(&state, "page verdict was not ok");
    } else if (state.main_requests != 1u) {
      probe_fail(&state, "main document was not requested exactly once");
    } else if (state.js_requests != 1u) {
      probe_fail(&state, "probe script was not requested exactly once");
    } else if (state.css_requests < 1u) {
      probe_fail(&state, "stylesheet subresource never reached the handler");
    } else if (state.refused_requests < 3u) {
      probe_fail(&state, "hostile/missing URIs did not reach the handler");
    } else if (state.echo_returns != (unsigned)PROBE_ECHOES) {
      probe_fail(&state, "concurrent invocations did not complete exactly once");
    } else if (!state.worker_was_distinct) {
      probe_fail(&state, "no invocation was serviced off the GUI thread");
    } else {
      ok = 1;
    }
  }

  if (state.report[0] != '\0') {
    printf("CAP7L_REPORT cycle=%u %s\n", cycle, state.report);
  }
  if (!ok) {
    fprintf(stderr, "CAP7L_FAIL cycle=%u reason=%s\n", cycle,
            state.failure[0] != '\0' ? state.failure : "incomplete verdict");
  } else {
    printf("CAP7L_CYCLE_PASS cycle=%u requests=%u refused=%u echoes=%u\n",
           cycle, state.main_requests + state.js_requests + state.css_requests,
           state.refused_requests, state.echo_returns);
  }

  pthread_cond_destroy(&state.wake);
  pthread_mutex_destroy(&state.mutex);
  return ok;
}

int main(int argc, char **argv) {
  unsigned cycles = 3;
  unsigned cycle;

  if (argc == 2) {
    const long parsed = strtol(argv[1], NULL, 10);
    if ((parsed < 1) || (parsed > 20)) {
      fprintf(stderr, "usage: cap7l_probe [cycles 1..20]\n");
      return 2;
    }
    cycles = (unsigned)parsed;
  } else if (argc != 1) {
    fprintf(stderr, "usage: cap7l_probe [cycles 1..20]\n");
    return 2;
  }

  for (cycle = 1; cycle <= cycles; ++cycle) {
    if (!run_cycle(cycle)) {
      return 1;
    }
  }
  printf("CAP7L_RENDERED_PASS cycles=%u\n", cycles);
  return 0;
}
