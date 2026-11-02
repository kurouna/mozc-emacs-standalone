// Copyright 2026, Shinsaku Nakagawa
// Use of this source code is governed by the BSD 3-Clause license in LICENSE.

// aux_ulib is not available in MinGW.  Report "unknown" so that callers of
// WinUtil::IsDLLSynchronizationHeld() take their conservative path.

#include <windows.h>

extern "C" BOOL WINAPI AuxUlibInitialize() { return TRUE; }

extern "C" BOOL WINAPI AuxUlibIsDLLSynchronizationHeld(PBOOL held) {
  ::SetLastError(ERROR_NOT_SUPPORTED);
  return FALSE;
}
