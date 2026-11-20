// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#include "COTConPTY.h"

#if defined(_WIN32)

#ifndef NTDDI_VERSION
#define NTDDI_VERSION 0x0A000006  // NTDDI_WIN10_RS5, the first with ConPTY
#endif
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <algorithm>
#include <cstdlib>
#include <cstring>
#include <atomic>
#include <mutex>
#include <thread>

namespace cot {

namespace {

std::wstring Widen(const std::string &utf8) {
  if (utf8.empty()) {
    return std::wstring();
  }
  int count = MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), NULL, 0);
  std::wstring wide((std::size_t)count, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.data(), (int)utf8.size(), &wide[0], count);
  return wide;
}

std::string LastErrorMessage(const char *what, DWORD code) {
  wchar_t *text = NULL;
  FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code,
                 0, (LPWSTR)&text, 0, NULL);
  std::string message = what;
  message += " failed (";
  message += std::to_string((unsigned long)code);
  message += ")";
  if (text != NULL) {
    int count = WideCharToMultiByte(CP_UTF8, 0, text, -1, NULL, 0, NULL, NULL);
    if (count > 1) {
      std::string narrow((std::size_t)count - 1, '\0');
      WideCharToMultiByte(CP_UTF8, 0, text, -1, &narrow[0], count, NULL, NULL);
      while (!narrow.empty() && (narrow.back() == '\n' || narrow.back() == '\r' || narrow.back() == ' ')) {
        narrow.pop_back();
      }
      message += ": " + narrow;
    }
    LocalFree(text);
  }
  return message;
}

// "KEY=VALUE\0...\0\0", sorted without regard to case as CreateProcess wants. Later duplicates of a key (in any case)
// replace earlier ones, since Windows names are case-insensitive.
std::wstring EnvironmentBlock(const std::vector<std::pair<std::string, std::string>> &environment) {
  std::vector<std::pair<std::wstring, std::wstring>> entries;
  for (const auto &entry : environment) {
    if (entry.first.empty() || entry.first.find('=') != std::string::npos) {
      continue;
    }
    std::wstring key = Widen(entry.first);
    std::wstring value = Widen(entry.second);
    auto existing = std::find_if(entries.begin(), entries.end(), [&](const auto &e) {
      return CompareStringOrdinal(e.first.c_str(), -1, key.c_str(), -1, TRUE) == CSTR_EQUAL;
    });
    if (existing != entries.end()) {
      existing->second = value;
    } else {
      entries.emplace_back(key, value);
    }
  }
  std::sort(entries.begin(), entries.end(), [](const auto &a, const auto &b) {
    return CompareStringOrdinal(a.first.c_str(), -1, b.first.c_str(), -1, TRUE) == CSTR_LESS_THAN;
  });
  std::wstring block;
  for (const auto &entry : entries) {
    block += entry.first;
    block += L'=';
    block += entry.second;
    block += L'\0';
  }
  block += L'\0';
  if (entries.empty()) {
    block += L'\0';
  }
  return block;
}

// The pseudo console functions: Microsoft's own conpty.dll when it sits next to the program (it starts the
// OpenConsole.exe beside it, the console Windows Terminal ships), else the ones built into Windows. The bundled one
// is newer than what older Windows has, and the same on every machine. COCOATERMINAL_CONPTY overrides: "system" for
// the built-in ones, or the full path of a conpty.dll.
struct PseudoConsoleAPI {
  HRESULT(WINAPI *create)(COORD, HANDLE, HANDLE, DWORD, HPCON *) = CreatePseudoConsole;
  HRESULT(WINAPI *resize)(HPCON, COORD) = ResizePseudoConsole;
  void(WINAPI *close)(HPCON) = ClosePseudoConsole;
  std::string description = "system";
};

const PseudoConsoleAPI &PseudoConsole() {
  static PseudoConsoleAPI api;
  static std::once_flag once;
  std::call_once(once, [] {
    std::wstring path;
    const char *override_ = getenv("COCOATERMINAL_CONPTY");
    if (override_ != NULL && *override_ != '\0') {
      if (strcmp(override_, "system") == 0) {
        return;
      }
      path = Widen(override_);
    } else {
      wchar_t exe[MAX_PATH];
      DWORD length = GetModuleFileNameW(NULL, exe, MAX_PATH);
      if (length == 0 || length >= MAX_PATH) {
        return;
      }
      path.assign(exe, length);
      std::size_t slash = path.find_last_of(L"\\/");
      path = (slash == std::wstring::npos ? std::wstring() : path.substr(0, slash + 1)) + L"conpty.dll";
      if (GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
        return;
      }
    }
    // A full path, and its own folder searched for what it loads: never a conpty.dll found elsewhere.
    HMODULE module = LoadLibraryExW(path.c_str(), NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (module == NULL) {
      return;
    }
    auto create = reinterpret_cast<decltype(api.create)>(GetProcAddress(module, "ConptyCreatePseudoConsole"));
    auto resize = reinterpret_cast<decltype(api.resize)>(GetProcAddress(module, "ConptyResizePseudoConsole"));
    auto close = reinterpret_cast<decltype(api.close)>(GetProcAddress(module, "ConptyClosePseudoConsole"));
    if (create == NULL || resize == NULL || close == NULL) {
      FreeLibrary(module);
      return;
    }
    api.create = create;
    api.resize = resize;
    api.close = close;
    int count = WideCharToMultiByte(CP_UTF8, 0, path.c_str(), (int)path.size(), NULL, 0, NULL, NULL);
    std::string narrow((std::size_t)count, '\0');
    WideCharToMultiByte(CP_UTF8, 0, path.c_str(), (int)path.size(), &narrow[0], count, NULL, NULL);
    api.description = "bundled " + narrow;
  });
  return api;
}

}  // namespace

std::string ConPTYProcess::implementation() {
  return PseudoConsole().description;
}

std::vector<std::pair<std::string, std::string>> ConPTYProcess::currentEnvironment() {
  std::vector<std::pair<std::string, std::string>> result;
  wchar_t *block = GetEnvironmentStringsW();
  if (block == NULL) {
    return result;
  }
  auto utf8 = [](const wchar_t *text, int length) {
    int count = WideCharToMultiByte(CP_UTF8, 0, text, length, NULL, 0, NULL, NULL);
    std::string out(count > 0 ? (std::size_t)count : 0, '\0');
    if (count > 0) WideCharToMultiByte(CP_UTF8, 0, text, length, &out[0], count, NULL, NULL);
    return out;
  };
  for (const wchar_t *entry = block; *entry != L'\0'; entry += wcslen(entry) + 1) {
    // "=C:=C:\dir" and the like (a drive's current directory) start with '=': not variables.
    const wchar_t *equals = entry[0] == L'=' ? NULL : wcschr(entry, L'=');
    if (equals == NULL) continue;
    result.emplace_back(utf8(entry, (int)(equals - entry)), utf8(equals + 1, (int)wcslen(equals + 1)));
  }
  FreeEnvironmentStringsW(block);
  return result;
}

struct ConPTYProcess::State {
  HPCON console = NULL;
  HANDLE input = INVALID_HANDLE_VALUE;   // we write the keyboard here
  HANDLE output = INVALID_HANDLE_VALUE;  // we read the screen here
  HANDLE process = NULL;
  std::mutex consoleMutex;  // console
  std::mutex inputMutex;    // input
  std::atomic<bool> terminating{false};
  bool terminated = false;
  std::thread reader;
  std::thread watcher;
  Callbacks callbacks;

  // Closing the console ends its pipe, so the reader sees end of file after the last of the output.
  void closeConsole() {
    std::lock_guard<std::mutex> lock(consoleMutex);
    if (console != NULL) {
      PseudoConsole().close(console);
      console = NULL;
    }
  }

  void readLoop() {
    std::vector<char> buffer(64 * 1024);
    for (;;) {
      DWORD count = 0;
      if (!ReadFile(output, buffer.data(), (DWORD)buffer.size(), &count, NULL) || count == 0) {
        break;
      }
      if (!terminating.load() && callbacks.output) {
        callbacks.output(buffer.data(), (std::size_t)count);
      }
    }
    if (terminating.load()) {
      return;
    }
    WaitForSingleObject(process, INFINITE);
    DWORD exitCode = 0;
    GetExitCodeProcess(process, &exitCode);
    if (!terminating.load() && callbacks.exited) {
      callbacks.exited((std::uint32_t)exitCode);
    }
  }

  void watch() {
    WaitForSingleObject(process, INFINITE);
    closeConsole();
  }
};

std::wstring ConPTYProcess::commandLine(const std::vector<std::string> &argv) {
  std::wstring line;
  for (std::size_t index = 0; index < argv.size(); ++index) {
    std::wstring argument = Widen(argv[index]);
    if (index > 0) {
      line += L' ';
    }
    if (!argument.empty() && argument.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
      line += argument;
      continue;
    }
    line += L'"';
    std::size_t backslashes = 0;
    for (wchar_t c : argument) {
      if (c == L'\\') {
        ++backslashes;
        continue;
      }
      if (c == L'"') {
        line.append(backslashes * 2 + 1, L'\\');
      } else {
        line.append(backslashes, L'\\');
      }
      backslashes = 0;
      line += c;
    }
    line.append(backslashes * 2, L'\\');
    line += L'"';
  }
  return line;
}

std::unique_ptr<ConPTYProcess> ConPTYProcess::spawn(const std::vector<std::string> &argv,
                                                    const std::vector<std::pair<std::string, std::string>> &environment,
                                                    const std::string &workingDirectory,
                                                    unsigned columns,
                                                    unsigned rows,
                                                    Callbacks callbacks,
                                                    std::string *error) {
  auto fail = [error](std::string message) -> std::unique_ptr<ConPTYProcess> {
    if (error != NULL) {
      *error = std::move(message);
    }
    return nullptr;
  };
  if (argv.empty()) {
    return fail("no shell command");
  }

  std::unique_ptr<State> state(new State());
  state->callbacks = std::move(callbacks);

  HANDLE consoleInput = INVALID_HANDLE_VALUE;   // the console reads the keyboard here
  HANDLE consoleOutput = INVALID_HANDLE_VALUE;  // the console writes the screen here
  if (!CreatePipe(&consoleInput, &state->input, NULL, 0)) {
    return fail(LastErrorMessage("CreatePipe", GetLastError()));
  }
  if (!CreatePipe(&state->output, &consoleOutput, NULL, 0)) {
    DWORD code = GetLastError();
    CloseHandle(consoleInput);
    CloseHandle(state->input);
    return fail(LastErrorMessage("CreatePipe", code));
  }

  COORD size;
  size.X = (SHORT)std::max(1u, std::min(columns, 32767u));
  size.Y = (SHORT)std::max(1u, std::min(rows, 32767u));
  HRESULT result = PseudoConsole().create(size, consoleInput, consoleOutput, 0, &state->console);
  // The console holds its own references to its ends of the pipes.
  CloseHandle(consoleInput);
  CloseHandle(consoleOutput);
  if (FAILED(result)) {
    CloseHandle(state->input);
    CloseHandle(state->output);
    return fail(LastErrorMessage("CreatePseudoConsole", (DWORD)result));
  }

  SIZE_T attributeSize = 0;
  InitializeProcThreadAttributeList(NULL, 1, 0, &attributeSize);
  std::vector<unsigned char> attributeStorage(attributeSize);
  STARTUPINFOEXW startup;
  ZeroMemory(&startup, sizeof(startup));
  startup.StartupInfo.cb = sizeof(startup);
  // Without this a GUI parent's std handles (or lack of them) leak into the child in place of the console's.
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = INVALID_HANDLE_VALUE;
  startup.StartupInfo.hStdOutput = INVALID_HANDLE_VALUE;
  startup.StartupInfo.hStdError = INVALID_HANDLE_VALUE;
  startup.lpAttributeList = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(attributeStorage.data());
  if (!InitializeProcThreadAttributeList(startup.lpAttributeList, 1, 0, &attributeSize) ||
      !UpdateProcThreadAttribute(startup.lpAttributeList, 0, PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE, state->console,
                                 sizeof(state->console), NULL, NULL)) {
    DWORD code = GetLastError();
    PseudoConsole().close(state->console);
    CloseHandle(state->input);
    CloseHandle(state->output);
    return fail(LastErrorMessage("UpdateProcThreadAttribute", code));
  }

  std::wstring line = commandLine(argv);
  std::wstring block = EnvironmentBlock(environment);
  std::wstring directory = Widen(workingDirectory);
  PROCESS_INFORMATION info;
  ZeroMemory(&info, sizeof(info));
  BOOL created = CreateProcessW(NULL, &line[0], NULL, NULL, FALSE,
                                EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT,
                                environment.empty() ? NULL : (LPVOID)block.c_str(),
                                directory.empty() ? NULL : directory.c_str(), &startup.StartupInfo, &info);
  DWORD createError = GetLastError();
  DeleteProcThreadAttributeList(startup.lpAttributeList);
  if (!created) {
    PseudoConsole().close(state->console);
    CloseHandle(state->input);
    CloseHandle(state->output);
    return fail(LastErrorMessage(("Starting " + argv[0]).c_str(), createError));
  }
  CloseHandle(info.hThread);
  state->process = info.hProcess;

  State *raw = state.get();
  state->reader = std::thread([raw]() { raw->readLoop(); });
  state->watcher = std::thread([raw]() { raw->watch(); });
  return std::unique_ptr<ConPTYProcess>(new ConPTYProcess(std::move(state)));
}

ConPTYProcess::ConPTYProcess(std::unique_ptr<State> state) : _state(std::move(state)) {}

ConPTYProcess::~ConPTYProcess() {
  terminate();
}

bool ConPTYProcess::write(const char *bytes, std::size_t length) {
  std::lock_guard<std::mutex> lock(_state->inputMutex);
  if (_state->input == INVALID_HANDLE_VALUE) {
    return false;
  }
  std::size_t total = 0;
  while (total < length) {
    DWORD written = 0;
    DWORD chunk = (DWORD)std::min<std::size_t>(length - total, 1 << 20);
    if (!WriteFile(_state->input, bytes + total, chunk, &written, NULL) || written == 0) {
      return false;
    }
    total += written;
  }
  return true;
}

void ConPTYProcess::resize(unsigned columns, unsigned rows) {
  std::lock_guard<std::mutex> lock(_state->consoleMutex);
  if (_state->console == NULL) {
    return;
  }
  COORD size;
  size.X = (SHORT)std::max(1u, std::min(columns, 32767u));
  size.Y = (SHORT)std::max(1u, std::min(rows, 32767u));
  PseudoConsole().resize(_state->console, size);
}

void ConPTYProcess::terminate() {
  State *state = _state.get();
  if (state == nullptr || state->terminated) {
    return;
  }
  state->terminated = true;
  state->terminating.store(true);
  // The process first: closing a console whose shell still runs can wait on it.
  TerminateProcess(state->process, 1);
  state->closeConsole();  // the reader then reaches end of file; a blocked write fails
  {
    std::lock_guard<std::mutex> lock(state->inputMutex);
    if (state->input != INVALID_HANDLE_VALUE) {
      CloseHandle(state->input);
      state->input = INVALID_HANDLE_VALUE;
    }
  }
  std::thread::id self = std::this_thread::get_id();
  for (std::thread *thread : {&state->reader, &state->watcher}) {
    if (!thread->joinable()) {
      continue;
    }
    if (thread->get_id() == self) {
      thread->detach();
    } else {
      thread->join();
    }
  }
  if (state->output != INVALID_HANDLE_VALUE) {
    CloseHandle(state->output);
    state->output = INVALID_HANDLE_VALUE;
  }
  if (state->process != NULL) {
    CloseHandle(state->process);
    state->process = NULL;
  }
}

}  // namespace cot

#endif
