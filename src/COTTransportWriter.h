// SPDX-License-Identifier: LGPL-2.1-or-later
#pragma once
#include <cstddef>
#include <cstdint>
#include <deque>
#include <functional>
#include <string>
#include <vector>

namespace cot {
enum class EnqueueResult { Accepted, Backpressured, Closed, Failed };
struct WriteResult { std::ptrdiff_t count; int error; };
// Every method must run on the same serial owner. Adapter callbacks must not
// reenter. The owner also serializes fd replacement/close and readiness events.
class TransportWriter {
 public:
  struct Adapter {
    std::function<WriteResult(int,const char *,std::size_t)> write;
    std::function<void(int,std::uint64_t)> armWritable;
    std::function<void()> disarmWritable;
    std::function<void(int)> close;
  };
  static constexpr std::size_t MaximumPendingBytes = 1024 * 1024;
  explicit TransportWriter(Adapter adapter);
  ~TransportWriter();
  TransportWriter(const TransportWriter &) = delete;
  TransportWriter &operator=(const TransportWriter &) = delete;
  // Takes fd ownership only on success. Policy is frozen for this generation.
  bool open(int fd, bool allowsInput);
  EnqueueResult enqueue(const char *data, std::size_t length);
  void writable(std::uint64_t generation);
  void close();
  std::size_t pendingBytes() const { return pendingBytes_; }
  std::uint64_t generation() const { return generation_; }
  int descriptor() const { return fd_; }
  const std::string &error() const { return error_; }
 private:
  void drain();
  void fail(const char *message);
  Adapter adapter_;
  int fd_ = -1;
  bool allowsInput_ = false;
  bool armed_ = false;
  std::uint64_t generation_ = 0;
  std::deque<std::vector<char>> pending_;
  std::size_t offset_ = 0;
  std::size_t pendingBytes_ = 0;
  std::string error_;
};
}
