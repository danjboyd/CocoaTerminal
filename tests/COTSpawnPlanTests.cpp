// SPDX-License-Identifier: LGPL-2.1-or-later
// Prereq F (goal 693): the spawn plan is built before fork, and the child path
// runs only chdir/execve/write/_exit. Plain fork() children of this process in
// a scratch directory; no PTY, SSH, network, clipboard or GUI. 5 s alarm.
#include "COTSpawnPlan.h"
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <iostream>
#include <string>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>
using namespace cot;
static int failures = 0;
#define EXPECT(cond, msg) do { if (!(cond)) { std::cerr << __LINE__ << ": " << msg << "\n"; ++failures; } } while (0)

static std::string Scratch() {
  char pattern[] = "/tmp/cot-spawn-XXXXXX";
  const char *base = getenv("COT_SCRATCH");
  std::string templ = base ? std::string(base) + "/cot-spawn-XXXXXX" : pattern;
  std::vector<char> buffer(templ.begin(), templ.end()); buffer.push_back('\0');
  return mkdtemp(buffer.data()) ? std::string(buffer.data()) : std::string();
}
static void WriteFile(const std::string &path, const std::string &text, mode_t mode) {
  int fd = open(path.c_str(), O_WRONLY | O_CREAT | O_TRUNC, mode);
  if (fd >= 0) { (void)!write(fd, text.data(), text.size()); close(fd); }
  chmod(path.c_str(), mode);
}
// Forks, runs the plan's child path, and returns {raw status, read result, record}.
struct Run { int status; SpawnRead read; SpawnFailure failure; };
static Run Spawn(const SpawnPlan &plan) {
  int pipeFds[2];
  Run run{-1, SpawnRead::Malformed, {0, 0}};
  if (pipe2(pipeFds, O_CLOEXEC) != 0) return run;
  pid_t pid = fork();
  if (pid == 0) { close(pipeFds[0]); plan.execInChild(pipeFds[1]); }
  close(pipeFds[1]);
  run.read = ReadSpawnFailure(pipeFds[0], 2000, run.failure);
  close(pipeFds[0]);
  waitpid(pid, &run.status, 0);
  return run;
}

int main() {
  alarm(5);
  const std::string dir = Scratch();
  EXPECT(!dir.empty(), "scratch dir");

  // 1. Rejected before fork: empty command, NUL bytes, bad env name, missing cwd/executable.
  EXPECT(!SpawnPlan::Make({}, {}, {}, "").ok(), "empty command");
  EXPECT(!SpawnPlan::Make({""}, {}, {}, "").ok(), "empty name");
  EXPECT(!SpawnPlan::Make({std::string("/bin/sh\0x", 9)}, {}, {}, "").ok(), "NUL in argument");
  EXPECT(!SpawnPlan::Make({"/bin/sh"}, {}, {{"A=B", "1"}}, "").ok(), "'=' in env name");
  EXPECT(!SpawnPlan::Make({"/bin/sh"}, {}, {{"", "1"}}, "").ok(), "empty env name");
  {
    SpawnPlan plan = SpawnPlan::Make({"/bin/sh"}, {}, {}, dir + "/missing");
    EXPECT(!plan.ok() && plan.problem().find("working directory") != std::string::npos, "missing cwd: " << plan.problem());
  }
  EXPECT(!SpawnPlan::Make({"/nonexistent/cot-685"}, {}, {}, "").ok(), "missing absolute executable");
  {
    SpawnPlan plan = SpawnPlan::Make({"cot-no-such-685"}, {"PATH=/bin:/usr/bin"}, {}, "");
    EXPECT(!plan.ok() && plan.problem().find("not found") != std::string::npos, "not on PATH");
  }

  // 2. Environment: inherited, then overrides in order, replacing by name.
  {
    SpawnPlan plan = SpawnPlan::Make({"/bin/sh"}, {"A=1", "PATH=/bin:/usr/bin", "TERM=dumb", "junk"},
                                     {{"TERM", "xterm-256color"}, {"B", "2"}, {"A", "3"}}, "");
    EXPECT(plan.ok(), plan.problem());
    std::vector<std::string> want{"A=3", "PATH=/bin:/usr/bin", "TERM=xterm-256color", "B=2"};
    EXPECT(plan.environment() == want, "environment merge");
    char *const *envp = plan.envp();
    EXPECT(envp[4] == nullptr && std::string(envp[2]) == "TERM=xterm-256color", "envp terminated and stable");
    char *const *argv = plan.argv();
    EXPECT(std::string(argv[0]) == "/bin/sh" && argv[1] == nullptr, "argv terminated");
  }

  // 3. PATH search from the child's final environment, like execvp.
  {
    WriteFile(dir + "/cot-probe-685", "#!/bin/sh\nexit 5\n", 0755);
    SpawnPlan plan = SpawnPlan::Make({"cot-probe-685"}, {"PATH=/bin"}, {{"PATH", "/nonexistent:" + dir}}, "");
    EXPECT(plan.ok() && plan.executable() == dir + "/cot-probe-685", "resolved via overridden PATH: " << plan.executable());
    Run run = Spawn(plan);
    EXPECT(run.read == SpawnRead::Launched && WIFEXITED(run.status) && WEXITSTATUS(run.status) == 5, "ran the resolved file");
    SpawnPlan fallback = SpawnPlan::Make({"sh"}, {}, {}, "");  // PATH unset: /bin:/usr/bin
    EXPECT(fallback.ok() && (fallback.executable() == "/bin/sh" || fallback.executable() == "/usr/bin/sh"), "default PATH");
    WriteFile(dir + "/not-exec", "x", 0644);
    EXPECT(!SpawnPlan::Make({dir + "/not-exec"}, {}, {}, "").ok(), "non-executable rejected");
  }

  // 4. The child gets exactly the planned cwd, argv and environment.
  {
    SpawnPlan plan = SpawnPlan::Make({"/bin/sh", "-c", "test \"$COT_X\" = y && test \"$(pwd -P)\" = \"$1\" && exit 7; exit 1", "sh", dir},
                                     {"PATH=/bin:/usr/bin"}, {{"COT_X", "y"}}, dir);
    char resolved[4096];
    EXPECT(plan.ok() && realpath(dir.c_str(), resolved), plan.problem());
    Run run = Spawn(plan);
    EXPECT(run.read == SpawnRead::Launched, "successful exec closes the pipe with no record");
    EXPECT(WIFEXITED(run.status) && WEXITSTATUS(run.status) == 7, "child saw cwd/env/argv: " << run.status);
  }

  // 5. chdir failure after planning: record {chdir, ENOENT}, exit 126.
  {
    const std::string sub = dir + "/sub";
    mkdir(sub.c_str(), 0755);
    SpawnPlan plan = SpawnPlan::Make({"/bin/sh", "-c", "exit 0"}, {}, {}, sub);
    EXPECT(plan.ok(), plan.problem());
    rmdir(sub.c_str());
    Run run = Spawn(plan);
    EXPECT(run.read == SpawnRead::Failed && run.failure.stage == SpawnStageChdir && run.failure.error == ENOENT, "chdir record");
    EXPECT(WIFEXITED(run.status) && WEXITSTATUS(run.status) == 126, "exit 126");
  }

  // 6. execve failure after planning: record {exec, EACCES}, exit 127.
  {
    const std::string file = dir + "/goes-away";
    WriteFile(file, "#!/bin/sh\nexit 0\n", 0755);
    SpawnPlan plan = SpawnPlan::Make({file}, {}, {}, "");
    EXPECT(plan.ok(), plan.problem());
    chmod(file.c_str(), 0644);
    Run run = Spawn(plan);
    EXPECT(run.read == SpawnRead::Failed && run.failure.stage == SpawnStageExec && run.failure.error == EACCES, "exec record");
    EXPECT(WIFEXITED(run.status) && WEXITSTATUS(run.status) == 127, "exit 127");
  }

  // 7. Parent-side reader: malformed and timed-out records.
  {
    int p[2]; SpawnFailure f{0, 0};
    (void)!pipe(p); (void)!write(p[1], "abc", 3); close(p[1]);
    EXPECT(ReadSpawnFailure(p[0], 100, f) == SpawnRead::Malformed, "short record is malformed");
    close(p[0]);
    (void)!pipe(p);
    SpawnFailure bogus{99, 1};
    (void)!write(p[1], &bogus, sizeof bogus); close(p[1]);
    EXPECT(ReadSpawnFailure(p[0], 100, f) == SpawnRead::Malformed, "unknown stage is malformed");
    close(p[0]);
    (void)!pipe(p);
    EXPECT(ReadSpawnFailure(p[0], 50, f) == SpawnRead::TimedOut, "nothing yet: timed out, bounded");
    close(p[0]); close(p[1]);
  }

  unlink((dir + "/cot-probe-685").c_str()); unlink((dir + "/not-exec").c_str());
  unlink((dir + "/goes-away").c_str()); rmdir(dir.c_str());
  alarm(0);
  if (failures) { std::cerr << failures << " failure(s)\n"; return 1; }
  std::cout << "COTSpawnPlanTests: all passed\n";
  return 0;
}
