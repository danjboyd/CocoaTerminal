// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd
//
// The bench's memory reading on Windows, kept out of the Objective-C file so <windows.h> doesn't meet the runtime.

#if defined(_WIN32)
#include <windows.h>
#include <psapi.h>

extern "C" double COTBenchPrivateMegabytes(void) {
  PROCESS_MEMORY_COUNTERS_EX counters = {};
  counters.cb = sizeof counters;
  if (!GetProcessMemoryInfo(GetCurrentProcess(), reinterpret_cast<PROCESS_MEMORY_COUNTERS *>(&counters), sizeof counters)) {
    return 0;
  }
  return counters.PrivateUsage / 1048576.0;
}
#endif
