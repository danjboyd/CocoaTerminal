// SPDX-License-Identifier: LGPL-2.1-or-later
// Copyright (C) 2026 Daniel Boyd

#pragma once

// A shell on a Windows pseudo console (ConPTY). Plain C++ so <windows.h> stays out of the Objective-C sources, where its
// BOOL and `interface` clash with the runtime's.

#if defined(_WIN32)

#include <cstddef>
#include <cstdint>
#include <functional>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace cot {

class ConPTYProcess {
public:
  struct Callbacks {
    // On the reader thread, for each chunk the console writes.
    std::function<void(const char *bytes, std::size_t length)> output;
    // On the reader thread, once, after the last output, when the shell has gone on its own. Never after terminate().
    std::function<void(std::uint32_t exitCode)> exited;
  };

  // argv, environment and workingDirectory are UTF-8. An empty workingDirectory inherits ours. On failure, null and a
  // message in *error.
  static std::unique_ptr<ConPTYProcess> spawn(const std::vector<std::string> &argv,
                                              const std::vector<std::pair<std::string, std::string>> &environment,
                                              const std::string &workingDirectory,
                                              unsigned columns,
                                              unsigned rows,
                                              Callbacks callbacks,
                                              std::string *error);

  ~ConPTYProcess();  // terminate()

  // Any thread.
  bool write(const char *bytes, std::size_t length);
  void resize(unsigned columns, unsigned rows);

  // Ends the shell and its console and waits for the threads. No callback runs once it returns. Safe to repeat.
  void terminate();

  // The command line CreateProcess gets for argv: each argument quoted the way CommandLineToArgvW reads it back.
  static std::wstring commandLine(const std::vector<std::string> &argv);

  ConPTYProcess(const ConPTYProcess &) = delete;
  ConPTYProcess &operator=(const ConPTYProcess &) = delete;

  struct State;

private:
  explicit ConPTYProcess(std::unique_ptr<State> state);
  std::unique_ptr<State> _state;
};

}  // namespace cot

#endif
