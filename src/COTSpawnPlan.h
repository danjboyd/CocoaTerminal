// SPDX-License-Identifier: LGPL-2.1-or-later
// Prereq F (goal 693): everything the forked child needs is built in the parent
// BEFORE fork, so the child runs only async-signal-safe calls (chdir, execve,
// write, _exit): no Objective-C, no allocation, no setenv, no PATH search.
#pragma once
#include <string>
#include <utility>
#include <vector>

namespace cot {
struct SpawnFailure { int stage; int error; };  // the child's fixed-size startup record
enum SpawnStage { SpawnStageChdir = 1, SpawnStageExec = 2 };

class SpawnPlan {
 public:
  // command[0] is resolved like execvp (PATH from the child's final
  // environment; a name containing '/' is used as given). The environment is
  // `inherited`, then each override in order (replacing by name), minus every
  // name IsWithheldVariable() matches, from either source. An empty
  // workingDirectory means "inherit the parent's".
  static SpawnPlan Make(const std::vector<std::string> &command,
                        const std::vector<std::string> &inherited,
                        const std::vector<std::pair<std::string, std::string>> &overrides,
                        const std::string &workingDirectory);
  // Never passed to a terminal child: the multiplexer/window markers TMUX,
  // TMUX_PANE, STY and WINDOWID, AIManager's own AIMGR_* variables, and any
  // name ending in _TOKEN, _SECRET or _KEY, so the host app's credentials can't
  // leak into a shell started from a pane.
  static bool IsWithheldVariable(const std::string &name);
  bool ok() const { return problem_.empty(); }
  const std::string &problem() const { return problem_; }  // why it was rejected before fork
  const std::string &executable() const { return executable_; }
  const std::string &workingDirectory() const { return cwd_; }
  const std::vector<std::string> &arguments() const { return argv_; }
  const std::vector<std::string> &environment() const { return env_; }
  // Stable NULL-terminated arrays into the strings above, valid while the plan
  // lives and is not modified. Built once, before fork.
  char *const *argv() const { return argvPtrs_.data(); }
  char *const *envp() const { return envPtrs_.data(); }
  // For the child, after fork: chdir (if set) then execve. On failure writes
  // one SpawnFailure to errorFd (if >= 0) and _exits 126 (chdir) or 127
  // (exec). Uses only async-signal-safe calls and touches no heap.
  [[noreturn]] void execInChild(int errorFd) const noexcept;

 private:
  void freeze();
  std::string problem_, executable_, cwd_;
  std::vector<std::string> argv_, env_;
  std::vector<char *> argvPtrs_, envPtrs_;
};

// The parent side of the startup pipe. Launched: EOF with no record (execve
// succeeded and closed the O_CLOEXEC end). Failed: one valid record (stage and
// errno in `failure`). Malformed: a short or invalid record. TimedOut: nothing
// within timeoutMs; the parent never blocks longer than that.
enum class SpawnRead { Launched, Failed, Malformed, TimedOut };
SpawnRead ReadSpawnFailure(int readFd, int timeoutMs, SpawnFailure &failure);
}
