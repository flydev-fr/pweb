#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>

#include <WebView2.h>

#include <cstdio>
#include <cwchar>
#include <string>

#include "webview/detail/native_library.hh"
#include "webview/detail/platform/windows/iid.hh"
#include "webview/detail/platform/windows/reg_key.hh"
#include "webview/detail/platform/windows/version.hh"

// This is a platform-private white-box gate over the pinned loader. It does
// not alter or expose the webview C ABI.
#define private public
#include "webview/detail/platform/windows/webview2/loader.hh"
#undef private

namespace {

constexpr wchar_t kChannel[] = L"PWebCap4WBoundaryTest";
constexpr wchar_t kKey[] =
    L"SOFTWARE\\Microsoft\\EdgeUpdate\\ClientState\\PWebCap4WBoundaryTest";

bool SetRuntimePath(HKEY key, const wchar_t *path) {
  const DWORD bytes =
      static_cast<DWORD>((std::wcslen(path) + 1) * sizeof(wchar_t));
  return RegSetValueExW(key, L"EBWebView", 0, REG_SZ,
                        reinterpret_cast<const BYTE *>(path), bytes) ==
         ERROR_SUCCESS;
}

}  // namespace

int main() {
  using webview::detail::mswebview2::loader;
  static_assert(loader::api_version == 1587,
                "CAP-4W private loader minimum drifted");

  HKEY key{};
  DWORD disposition{};
  const LSTATUS create_status = RegCreateKeyExW(
      HKEY_CURRENT_USER, kKey, 0, nullptr, REG_OPTION_NON_VOLATILE,
      KEY_SET_VALUE | KEY_WOW64_32KEY, nullptr, &key, &disposition);
  if (create_status != ERROR_SUCCESS) {
    std::fprintf(stderr, "CAP4W_LOADER_FAIL create=%ld\n",
                 static_cast<long>(create_status));
    return 1;
  }

  bool passed = true;
  loader instance;
  if (!SetRuntimePath(key, L"C:\\cap4w\\1.0.1586.99") ||
      instance.find_installed_client(1587, false, kChannel).found) {
    std::fputs("CAP4W_LOADER_FAIL below-boundary\n", stderr);
    passed = false;
  }
  if (!SetRuntimePath(key, L"C:\\cap4w\\1.0.1587.0") ||
      !instance.find_installed_client(1587, false, kChannel).found) {
    std::fputs("CAP4W_LOADER_FAIL exact-boundary\n", stderr);
    passed = false;
  }
  if (!SetRuntimePath(key, L"C:\\cap4w\\1.0.1588.0") ||
      !instance.find_installed_client(1587, false, kChannel).found) {
    std::fputs("CAP4W_LOADER_FAIL above-boundary\n", stderr);
    passed = false;
  }

  const LSTATUS close_status = RegCloseKey(key);
  const LSTATUS delete_status =
      RegDeleteKeyExW(HKEY_CURRENT_USER, kKey, KEY_WOW64_32KEY, 0);
  if ((close_status != ERROR_SUCCESS) ||
      (delete_status != ERROR_SUCCESS)) {
    std::fprintf(stderr, "CAP4W_LOADER_FAIL cleanup=%ld/%ld\n",
                 static_cast<long>(close_status),
                 static_cast<long>(delete_status));
    passed = false;
  }

  if (!passed) {
    return 1;
  }
  std::puts("CAP4W_LOADER_BOUNDARY_PASS below=reject exact=accept above=accept");
  return 0;
}
