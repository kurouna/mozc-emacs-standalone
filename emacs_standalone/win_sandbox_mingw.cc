// Copyright 2026, Shinsaku Nakagawa
// Use of this source code is governed by the BSD 3-Clause license in LICENSE.

// Minimal WinSandbox for the standalone MinGW build.
//
// The original implementation depends on ATL, which MinGW does not provide.
// The standalone emacs helper runs as a single process with the user's own
// token, so only the functions reached from base/ are implemented here.

#include <windows.h>
#include <sddl.h>

#include <memory>
#include <string>
#include <string_view>

#include "base/win32/win_sandbox.h"

namespace mozc {
namespace {

std::wstring CurrentUserSidString() {
  HANDLE token = nullptr;
  if (!::OpenProcessToken(::GetCurrentProcess(), TOKEN_QUERY, &token)) {
    return L"";
  }
  DWORD size = 0;
  ::GetTokenInformation(token, TokenUser, nullptr, 0, &size);
  auto buffer = std::make_unique<BYTE[]>(size);
  std::wstring result;
  if (::GetTokenInformation(token, TokenUser, buffer.get(), size, &size)) {
    LPWSTR sid = nullptr;
    auto* user = reinterpret_cast<TOKEN_USER*>(buffer.get());
    if (::ConvertSidToStringSidW(user->User.Sid, &sid)) {
      result = sid;
      ::LocalFree(sid);
    }
  }
  ::CloseHandle(token);
  return result;
}

}  // namespace

wil::unique_hlocal_security_descriptor WinSandbox::MakeSecurityDescriptor(
    ObjectSecurityType shareble_object_type) {
  const std::wstring sid = CurrentUserSidString();
  if (sid.empty()) {
    return nullptr;
  }
  // Full access for the current user and SYSTEM only.
  const std::wstring sddl = L"D:P(A;;GA;;;SY)(A;;GA;;;" + sid + L")";
  PSECURITY_DESCRIPTOR sd = nullptr;
  if (!::ConvertStringSecurityDescriptorToSecurityDescriptorW(
          sddl.c_str(), SDDL_REVISION_1, &sd, nullptr)) {
    return nullptr;
  }
  return wil::unique_hlocal_security_descriptor(sd);
}

bool WinSandbox::AddKnownSidToKernelObject(HANDLE object, const SID* known_sid,
                                           DWORD inheritance_flag,
                                           ACCESS_MASK access_mask) {
  return true;
}

bool WinSandbox::EnsureAllApplicationPackagesPermisssion(
    std::wstring_view file_name, AppContainerVisibilityType type) {
  return true;
}

}  // namespace mozc
