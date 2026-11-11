// SPDX-License-Identifier: LGPL-2.1-or-later
#include "COTSpawnPlan.h"
#include <cerrno>
#include <cstring>
#include <poll.h>
#include <sys/stat.h>
#include <unistd.h>

namespace cot {
namespace {
std::string NameOf(const std::string &entry) {
  const auto equals = entry.find('=');
  return equals == std::string::npos ? entry : entry.substr(0, equals);
}
bool IsExecutableFile(const std::string &path) {
  struct stat info;
  return stat(path.c_str(), &info) == 0 && S_ISREG(info.st_mode) && access(path.c_str(), X_OK) == 0;
}
}

SpawnPlan SpawnPlan::Make(const std::vector<std::string> &command,
                          const std::vector<std::string> &inherited,
                          const std::vector<std::pair<std::string, std::string>> &overrides,
                          const std::string &workingDirectory) {
  SpawnPlan plan;
  if (command.empty() || command[0].empty()) {
    plan.problem_ = "The terminal command is empty.";
    return plan;
  }
  for (const auto &argument : command)
    if (argument.find('\0') != std::string::npos) { plan.problem_ = "A command argument contains a NUL byte."; return plan; }
  plan.argv_ = command;

  for (const auto &entry : inherited)
    if (entry.find('=') != std::string::npos && entry.find('\0') == std::string::npos) plan.env_.push_back(entry);
  for (const auto &item : overrides) {
    if (item.first.empty() || item.first.find('=') != std::string::npos ||
        item.first.find('\0') != std::string::npos || item.second.find('\0') != std::string::npos) {
      plan.problem_ = "Invalid environment variable name or value: " + item.first;
      return plan;
    }
    const std::string entry = item.first + "=" + item.second;
    bool replaced = false;
    for (auto &existing : plan.env_)
      if (NameOf(existing) == item.first) { existing = entry; replaced = true; }
    if (!replaced) plan.env_.push_back(entry);
  }

  if (!workingDirectory.empty()) {
    struct stat info;
    if (stat(workingDirectory.c_str(), &info) != 0 || !S_ISDIR(info.st_mode)) {
      plan.problem_ = "The working directory does not exist: " + workingDirectory;
      return plan;
    }
    plan.cwd_ = workingDirectory;
  }

  const std::string &name = command[0];
  if (name.find('/') != std::string::npos) {
    // Relative paths resolve against the child's cwd, as execve would.
    std::string candidate = (name[0] != '/' && !plan.cwd_.empty()) ? plan.cwd_ + "/" + name : name;
    if (!IsExecutableFile(candidate)) { plan.problem_ = "Not an executable file: " + name; return plan; }
    plan.executable_ = name;
  } else {
    std::string path = "/bin:/usr/bin";  // execvp's default when PATH is unset
    for (const auto &entry : plan.env_)
      if (NameOf(entry) == "PATH") path = entry.substr(5);
    std::size_t start = 0;
    while (start <= path.size()) {
      std::size_t end = path.find(':', start);
      if (end == std::string::npos) end = path.size();
      std::string directory = path.substr(start, end - start);
      if (directory.empty()) directory = ".";
      std::string candidate = directory + "/" + name;
      if (directory[0] != '/' && !plan.cwd_.empty()) candidate = plan.cwd_ + "/" + candidate;
      if (IsExecutableFile(candidate)) { plan.executable_ = candidate; break; }
      start = end + 1;
    }
    if (plan.executable_.empty()) { plan.problem_ = "Command not found on PATH: " + name; return plan; }
  }
  plan.freeze();
  return plan;
}

void SpawnPlan::freeze() {
  argvPtrs_.clear(); envPtrs_.clear();
  for (auto &argument : argv_) argvPtrs_.push_back(const_cast<char *>(argument.c_str()));
  argvPtrs_.push_back(nullptr);
  for (auto &entry : env_) envPtrs_.push_back(const_cast<char *>(entry.c_str()));
  envPtrs_.push_back(nullptr);
}

void SpawnPlan::execInChild(int errorFd) const noexcept {
  // Async-signal-safe only from here: no allocation, no locks, no Objective-C.
  SpawnFailure failure{0, 0};
  if (!cwd_.empty() && chdir(cwd_.c_str()) != 0) {
    failure = {SpawnStageChdir, errno};
  } else {
    execve(executable_.c_str(), argvPtrs_.data(), envPtrs_.data());
    failure = {SpawnStageExec, errno};
  }
  if (errorFd >= 0) {
    const char *bytes = reinterpret_cast<const char *>(&failure);
    std::size_t left = sizeof failure;
    while (left > 0) {
      ssize_t written = write(errorFd, bytes, left);
      if (written < 0 && errno == EINTR) continue;
      if (written <= 0) break;
      bytes += written; left -= static_cast<std::size_t>(written);
    }
  }
  _exit(failure.stage == SpawnStageChdir ? 126 : 127);
}

SpawnRead ReadSpawnFailure(int readFd, int timeoutMs, SpawnFailure &failure) {
  char buffer[sizeof(SpawnFailure)];
  std::size_t got = 0;
  while (got < sizeof buffer) {
    struct pollfd ready{readFd, POLLIN, 0};
    int polled = poll(&ready, 1, timeoutMs);
    if (polled < 0 && errno == EINTR) continue;
    if (polled == 0) return SpawnRead::TimedOut;  // exec not finished yet: treat as started
    if (polled < 0) return SpawnRead::Malformed;
    ssize_t count = read(readFd, buffer + got, sizeof buffer - got);
    if (count < 0 && errno == EINTR) continue;
    if (count < 0) return SpawnRead::Malformed;
    if (count == 0) return got == 0 ? SpawnRead::Launched : SpawnRead::Malformed;
    got += static_cast<std::size_t>(count);
  }
  SpawnFailure record;
  std::memcpy(&record, buffer, sizeof record);
  if (record.stage != SpawnStageChdir && record.stage != SpawnStageExec) return SpawnRead::Malformed;
  failure = record;
  return SpawnRead::Failed;
}
}
