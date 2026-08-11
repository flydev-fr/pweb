#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>

#include <WebView2.h>
#include <shlwapi.h>
#include <wrl.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <climits>
#include <cstdio>
#include <cstdlib>
#include <cwchar>
#include <cstring>
#include <exception>
#include <mutex>
#include <stdexcept>
#include <string>
#include <thread>

#include "webview/api.h"

using Microsoft::WRL::Callback;
using Microsoft::WRL::ComPtr;

namespace {

constexpr wchar_t kFilter[] = L"pweb://app/*";
constexpr wchar_t kWrongAuthority[] = L"pweb://other-host/probe";
constexpr char kWrongAuthorityUtf8[] = "pweb://other-host/probe";
constexpr wchar_t kHttpsIsolation[] = L"https://cap4w.invalid/";
constexpr char kHttpsIsolationUtf8[] = "https://cap4w.invalid/";
constexpr wchar_t kMainUri[] = L"pweb://app/probe";
constexpr char kMainUriUtf8[] = "pweb://app/probe";
constexpr wchar_t kScriptUri[] = L"pweb://app/probe.js";
constexpr char kPassMessage[] = "CAP-4W PASS";

constexpr char kHtml[] =
    "<!doctype html><html><head><meta charset=\"utf-8\"><title>CAP-4W"
    "</title></head><body><main id=\"verdict\">CAP-4W PENDING</main>"
    "<script src=\"/probe.js\"></script></body></html>";

constexpr char kScript[] =
    "requestAnimationFrame(() => requestAnimationFrame(() => {"
    "const node=document.getElementById('verdict');"
    "const secure=window.isSecureContext===true;"
    "node.textContent=secure?'CAP-4W PASS':'CAP-4W INSECURE';"
    "document.body.dataset.cap4w=secure?'pass':'insecure';"
    "window.chrome.webview.postMessage(node.textContent);"
    "}));";

enum class Phase {
  wrong_authority,
  https_isolation,
  app,
  complete
};

class HResultError final : public std::runtime_error {
 public:
  HResultError(const char *operation, HRESULT hr)
      : std::runtime_error(operation), hr_(hr) {}
  HRESULT value() const noexcept { return hr_; }

 private:
  HRESULT hr_;
};

void CheckHr(HRESULT hr, const char *operation) {
  if (FAILED(hr)) {
    throw HResultError(operation, hr);
  }
}

void CheckWebView(webview_error_t error, const char *operation) {
  if (error < WEBVIEW_ERROR_OK) {
    throw std::runtime_error(operation);
  }
}

struct ProbeState {
  webview_t webview{};
  std::atomic<Phase> phase{Phase::wrong_authority};
  std::atomic<unsigned> app_request_count{0};
  std::atomic<unsigned> main_request_count{0};
  std::atomic<unsigned> script_request_count{0};
  std::atomic<bool> rendered{false};
  std::atomic<bool> failed{false};
  std::mutex mutex;
  std::condition_variable wake;
  std::string failure;

  void Fail(const char *message) noexcept {
    try {
      std::lock_guard<std::mutex> guard(mutex);
      if (!failed.load()) {
        failure = message;
        failed.store(true);
      }
    } catch (...) {
      failed.store(true);
    }
    wake.notify_all();
  }
};

struct CoTaskMemString {
  LPWSTR value{};
  ~CoTaskMemString() { CoTaskMemFree(value); }
};

HRESULT PutResponse(ICoreWebView2Environment *environment,
                    ICoreWebView2WebResourceRequestedEventArgs *args,
                    const char *body, const wchar_t *content_type,
                    int status, const wchar_t *reason) {
  const auto size = std::strlen(body);
  if (size > UINT_MAX) {
    return E_INVALIDARG;
  }
  ComPtr<IStream> stream;
  stream.Attach(SHCreateMemStream(
      reinterpret_cast<const BYTE *>(body), static_cast<UINT>(size)));
  if (!stream) {
    return E_OUTOFMEMORY;
  }

  const std::wstring headers = L"Content-Type: " +
                               std::wstring(content_type) +
                               L"\r\nCache-Control: no-store";
  ComPtr<ICoreWebView2WebResourceResponse> response;
  HRESULT hr = environment->CreateWebResourceResponse(
      stream.Get(), status, reason, headers.c_str(), &response);
  if (FAILED(hr)) {
    return hr;
  }
  return args->put_Response(response.Get());
}

void TerminateOrFail(ProbeState *state) noexcept {
  if ((state != nullptr) && (state->webview != nullptr) &&
      (webview_terminate(state->webview) < WEBVIEW_ERROR_OK)) {
    state->Fail("webview_terminate failed");
  }
}

void TerminateOnGuiThread(webview_t webview, void *argument) noexcept {
  auto *state = static_cast<ProbeState *>(argument);
  if ((state == nullptr) || (state->webview != webview)) {
    if (state != nullptr) {
      state->Fail("watchdog dispatch state mismatch");
    }
    return;
  }
  TerminateOrFail(state);
}

void NavigateOrFail(ProbeState *state, const char *uri) noexcept {
  try {
    CheckWebView(webview_navigate(state->webview, uri), "webview_navigate");
  } catch (const std::exception &error) {
    state->Fail(error.what());
    TerminateOrFail(state);
  } catch (...) {
    state->Fail("unknown navigation failure");
    TerminateOrFail(state);
  }
}

bool RunCycle(unsigned cycle) {
  ProbeState state;
  webview_t webview = webview_create(0, nullptr);
  if (webview == nullptr) {
    std::fprintf(stderr,
                 "CAP4W_FAIL cycle=%u operation=webview_create\n", cycle);
    return false;
  }
  state.webview = webview;

  bool resource_registered = false;
  bool resource_filter_registered = false;
  bool message_registered = false;
  bool navigation_registered = false;
  EventRegistrationToken resource_token{};
  EventRegistrationToken message_token{};
  EventRegistrationToken navigation_token{};
  ComPtr<ICoreWebView2> core;
  ComPtr<ICoreWebView2_2> core2;
  ComPtr<ICoreWebView2Environment> environment;
  ComPtr<ICoreWebView2WebResourceRequestedEventHandler> resource_handler;
  ComPtr<ICoreWebView2WebMessageReceivedEventHandler> message_handler;
  ComPtr<ICoreWebView2NavigationCompletedEventHandler> navigation_handler;
  std::thread watchdog;
  bool ok = false;

  try {
    auto *borrowed_controller = static_cast<ICoreWebView2Controller *>(
        webview_get_native_handle(
            webview, WEBVIEW_NATIVE_HANDLE_KIND_BROWSER_CONTROLLER));
    if (borrowed_controller == nullptr) {
      throw std::runtime_error("borrowed controller unavailable");
    }
    CheckHr(borrowed_controller->get_CoreWebView2(&core),
            "controller.get_CoreWebView2");
    CheckHr(core.As(&core2), "CoreWebView2.QueryInterface(_2)");
    CheckHr(core2->get_Environment(&environment),
            "CoreWebView2_2.get_Environment");

    resource_handler = Callback<ICoreWebView2WebResourceRequestedEventHandler>(
        [&state, environment](ICoreWebView2 *,
                              ICoreWebView2WebResourceRequestedEventArgs *args)
            -> HRESULT {
          try {
            ComPtr<ICoreWebView2WebResourceRequest> request;
            CheckHr(args->get_Request(&request), "args.get_Request");
            CoTaskMemString uri;
            CheckHr(request->get_Uri(&uri.value), "request.get_Uri");
            if (uri.value == nullptr) {
              throw std::runtime_error("request URI is null");
            }
            state.app_request_count.fetch_add(1);
            if (std::wcscmp(uri.value, kMainUri) == 0) {
              state.main_request_count.fetch_add(1);
              CheckHr(PutResponse(environment.Get(), args, kHtml,
                                  L"text/html; charset=utf-8", 200, L"OK"),
                      "respond main HTML");
            } else if (std::wcscmp(uri.value, kScriptUri) == 0) {
              state.script_request_count.fetch_add(1);
              CheckHr(PutResponse(environment.Get(), args, kScript,
                                  L"text/javascript; charset=utf-8", 200,
                                  L"OK"),
                      "respond probe JS");
            } else {
              CheckHr(PutResponse(environment.Get(), args, "not found",
                                  L"text/plain; charset=utf-8", 404,
                                  L"Not Found"),
                      "respond not found");
            }
            return S_OK;
          } catch (const std::exception &error) {
            state.Fail(error.what());
          } catch (...) {
            state.Fail("unknown WebResourceRequested failure");
          }
          TerminateOrFail(&state);
          return S_OK;
        });
    if (!resource_handler) {
      throw std::runtime_error("resource handler allocation failed");
    }

    message_handler = Callback<ICoreWebView2WebMessageReceivedEventHandler>(
        [&state](ICoreWebView2 *, ICoreWebView2WebMessageReceivedEventArgs *args)
            -> HRESULT {
          try {
            CoTaskMemString message;
            CheckHr(args->TryGetWebMessageAsString(&message.value),
                    "TryGetWebMessageAsString");
            CoTaskMemString source;
            CheckHr(args->get_Source(&source.value),
                    "WebMessageReceived.get_Source");
            if ((source.value == nullptr) ||
                (std::wcscmp(source.value, kMainUri) != 0)) {
              throw std::runtime_error("web message source mismatch");
            }
            if ((message.value == nullptr) ||
                (std::wcscmp(message.value, L"CAP-4W PASS") != 0)) {
              throw std::runtime_error("unexpected web message");
            }
            if ((state.main_request_count.load() != 1) ||
                (state.script_request_count.load() != 1) ||
                (state.app_request_count.load() != 2)) {
              throw std::runtime_error("main/subresource count mismatch");
            }
            state.rendered.store(true);
            state.phase.store(Phase::complete);
            state.wake.notify_all();
          } catch (const std::exception &error) {
            state.Fail(error.what());
          } catch (...) {
            state.Fail("unknown WebMessageReceived failure");
          }
          TerminateOrFail(&state);
          return S_OK;
        });
    if (!message_handler) {
      throw std::runtime_error("message handler allocation failed");
    }

    navigation_handler = Callback<ICoreWebView2NavigationCompletedEventHandler>(
        [&state](ICoreWebView2 *,
                 ICoreWebView2NavigationCompletedEventArgs *args) -> HRESULT {
          try {
            const Phase current = state.phase.load();
            if (current == Phase::wrong_authority) {
              BOOL succeeded = TRUE;
              CheckHr(args->get_IsSuccess(&succeeded),
                      "wrong-authority get_IsSuccess");
              if (succeeded) {
                throw std::runtime_error(
                    "wrong-authority navigation unexpectedly succeeded");
              }
              if (state.app_request_count.load() != 0) {
                throw std::runtime_error("wrong authority reached app handler");
              }
              state.phase.store(Phase::https_isolation);
              NavigateOrFail(&state, kHttpsIsolationUtf8);
            } else if (current == Phase::https_isolation) {
              BOOL succeeded = TRUE;
              CheckHr(args->get_IsSuccess(&succeeded),
                      "HTTPS isolation get_IsSuccess");
              if (succeeded) {
                throw std::runtime_error(
                    "reserved HTTPS isolation navigation unexpectedly succeeded");
              }
              if (state.app_request_count.load() != 0) {
                throw std::runtime_error("HTTPS reached app handler");
              }
              state.phase.store(Phase::app);
              NavigateOrFail(&state, kMainUriUtf8);
            }
          } catch (const std::exception &error) {
            state.Fail(error.what());
            TerminateOrFail(&state);
          } catch (...) {
            state.Fail("unknown NavigationCompleted failure");
            TerminateOrFail(&state);
          }
          return S_OK;
        });
    if (!navigation_handler) {
      throw std::runtime_error("navigation handler allocation failed");
    }

    CheckHr(core->AddWebResourceRequestedFilter(
                kFilter, COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL),
            "AddWebResourceRequestedFilter");
    resource_filter_registered = true;
    CheckHr(core->add_WebResourceRequested(resource_handler.Get(),
                                           &resource_token),
            "add_WebResourceRequested");
    resource_registered = true;
    CheckHr(core->add_WebMessageReceived(message_handler.Get(), &message_token),
            "add_WebMessageReceived");
    message_registered = true;
    CheckHr(core->add_NavigationCompleted(navigation_handler.Get(),
                                          &navigation_token),
            "add_NavigationCompleted");
    navigation_registered = true;

    watchdog = std::thread([&state] {
      std::unique_lock<std::mutex> lock(state.mutex);
      if (!state.wake.wait_for(lock, std::chrono::seconds(20), [&state] {
            return state.failed.load() ||
                   state.phase.load() == Phase::complete;
          })) {
        lock.unlock();
        state.Fail("runtime probe timeout");
        if (webview_dispatch(state.webview, TerminateOnGuiThread, &state) <
            WEBVIEW_ERROR_OK) {
          state.Fail("watchdog webview_dispatch failed");
        }
      }
    });

    NavigateOrFail(&state, kWrongAuthorityUtf8);
    CheckWebView(webview_run(webview), "webview_run");
    state.wake.notify_all();
    if (watchdog.joinable()) {
      watchdog.join();
    }

    ok = !state.failed.load() && state.rendered.load() &&
         state.phase.load() == Phase::complete;
  } catch (const HResultError &error) {
    state.Fail(error.what());
    std::fprintf(stderr, "CAP4W_HRESULT cycle=%u hr=0x%08lx operation=%s\n",
                 cycle, static_cast<unsigned long>(error.value()), error.what());
  } catch (const std::exception &error) {
    state.Fail(error.what());
  } catch (...) {
    state.Fail("unknown probe failure");
  }

  state.wake.notify_all();
  if (watchdog.joinable()) {
    watchdog.join();
  }

  // Required order: unregister events/filter, release callback state and
  // owned COM references, then destroy the webview. The controller was borrowed
  // and is deliberately never released by this probe.
  bool unregistration_ok = true;
  if (navigation_registered &&
      FAILED(core->remove_NavigationCompleted(navigation_token))) {
    state.Fail("remove_NavigationCompleted failed");
    unregistration_ok = false;
  }
  if (message_registered &&
      FAILED(core->remove_WebMessageReceived(message_token))) {
    state.Fail("remove_WebMessageReceived failed");
    unregistration_ok = false;
  }
  if (resource_registered &&
      FAILED(core->remove_WebResourceRequested(resource_token))) {
    state.Fail("remove_WebResourceRequested failed");
    unregistration_ok = false;
  }
  if (resource_filter_registered &&
      FAILED(core->RemoveWebResourceRequestedFilter(
          kFilter, COREWEBVIEW2_WEB_RESOURCE_CONTEXT_ALL))) {
    state.Fail("RemoveWebResourceRequestedFilter failed");
    unregistration_ok = false;
  }

  if (unregistration_ok) {
    navigation_handler.Reset();
    message_handler.Reset();
    resource_handler.Reset();
    environment.Reset();
    core2.Reset();
    core.Reset();
  }

  if (webview_destroy(webview) < WEBVIEW_ERROR_OK) {
    state.Fail("webview_destroy failed");
  }

  // If removal failed, retain callback objects and the state they reference
  // until destruction has synchronously released the browser-owned event
  // registrations. The cycle still fails, but no callback can target freed
  // stack state during the fallback cleanup path.
  if (!unregistration_ok) {
    navigation_handler.Reset();
    message_handler.Reset();
    resource_handler.Reset();
    environment.Reset();
    core2.Reset();
    core.Reset();
  }

  if (state.failed.load()) {
    std::lock_guard<std::mutex> guard(state.mutex);
    std::fprintf(stderr, "CAP4W_FAIL cycle=%u reason=%s\n", cycle,
                 state.failure.c_str());
    return false;
  }
  if (!ok) {
    std::fprintf(stderr, "CAP4W_FAIL cycle=%u reason=incomplete verdict\n",
                 cycle);
    return false;
  }

  std::printf("CAP4W_CYCLE_PASS cycle=%u requests=%u\n", cycle,
              state.app_request_count.load());
  return true;
}

}  // namespace

int main(int argc, char **argv) {
  unsigned cycles = 3;
  if (argc == 2) {
    const int parsed = std::atoi(argv[1]);
    if ((parsed < 1) || (parsed > 20)) {
      std::fprintf(stderr, "usage: cap4w_probe [cycles 1..20]\n");
      return 2;
    }
    cycles = static_cast<unsigned>(parsed);
  } else if (argc != 1) {
    std::fprintf(stderr, "usage: cap4w_probe [cycles 1..20]\n");
    return 2;
  }

  for (unsigned cycle = 1; cycle <= cycles; ++cycle) {
    if (!RunCycle(cycle)) {
      return 1;
    }
  }
  std::printf("CAP4W_RENDERED_PASS cycles=%u message=%s\n", cycles,
              kPassMessage);
  return 0;
}
