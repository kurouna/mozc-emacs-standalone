// Copyright 2026, Shinsaku Nakagawa
// Use of this source code is governed by the BSD 3-Clause license in LICENSE.

#pragma once
#include <windows.h>
#ifdef __cplusplus
extern "C" {
#endif
BOOL WINAPI AuxUlibInitialize(void);
BOOL WINAPI AuxUlibIsDLLSynchronizationHeld(PBOOL);
#ifdef __cplusplus
}
#endif
