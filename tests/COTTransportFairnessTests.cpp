// SPDX-License-Identifier: LGPL-2.1-or-later
#include "COTTransportWriter.h"
#include <algorithm>
#include <cerrno>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <string>
using namespace cot;
static void expect(bool value,const char *message) { if (!value) { std::cerr<<message<<"\n"; std::exit(1); } }
struct Task { std::uint64_t generation, ticket; };
struct Fake {
  std::deque<Task> tasks;
  std::string bytes;
  unsigned calls=0, arms=0, disarms=0, closes=0, interrupts=0;
  std::size_t maxOffer=0, tiny=0;
  bool block=false, inlineCallback=false, closeInvariant=true;
  TransportWriter *writer=nullptr;
  TransportWriter::Adapter adapter() {
    return {
      [this](int,const char *p,std::size_t length)->WriteResult {
        ++calls; maxOffer=std::max(maxOffer,length);
        if (interrupts) { --interrupts; return {-1,EINTR}; }
        if (block) return {-1,EAGAIN};
        auto n=tiny?std::min(tiny,length):length; bytes.append(p,n); return {static_cast<std::ptrdiff_t>(n),0};
      },
      [this](int,std::uint64_t){ ++arms; }, [this]{ ++disarms; }, [this](int){ ++closes; if (writer) closeInvariant = closeInvariant && writer->driverState()==DriverState::Closed && writer->pendingBytes()==0; },
      [this](std::uint64_t generation,std::uint64_t ticket) {
        if (inlineCallback) writer->resume(generation,ticket); else tasks.push_back({generation,ticket});
      }
    };
  }
  Task pop() { expect(!tasks.empty(),"missing continuation"); Task t=tasks.front(); tasks.pop_front(); return t; }
  void step(TransportWriter &w) {
    Task t=pop(); auto before=calls; auto size=bytes.size(); w.resume(t.generation,t.ticket);
    expect(calls-before<=TransportWriter::MaximumCallsPerDrain,"call budget exceeded");
    expect(bytes.size()-size<=TransportWriter::MaximumBytesPerDrain,"byte budget exceeded");
    expect(tasks.size()<=1,"more than one continuation queued");
  }
};
int main() {
  {
    Fake f; f.interrupts=10000; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true);
    expect(w.enqueue("x",1)==EnqueueResult::Accepted,"admission failed");
    expect(f.calls==64 && f.tasks.size()==1 && f.arms==0,"initial EINTR work did not yield");
    auto before=f.calls; w.enqueue("y",1); expect(f.calls==before && f.tasks.size()==1,"pending enqueue drained or double-scheduled");
    unsigned turns=1; while (!f.tasks.empty()) { f.step(w); ++turns; }
    expect(turns==8 && f.calls==512 && !w.error().empty() && w.pendingBytes()==0 && f.closes==1,"all-EINTR no-progress must fail visibly after finite turns");
    expect(f.bytes.empty() && w.driverState()==DriverState::Closed && f.closeInvariant,"no bytes/replay after no-progress cancellation");
    expect(w.error().find("no progress")!=std::string::npos && w.error().find("cancelled")!=std::string::npos,"failure must explicitly surface admitted-suffix cancellation");
  }
  {
    Fake f; f.tiny=1; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true);
    std::string original(1000,'a'); w.enqueue(original.data(),original.size());
    expect(f.calls==64 && f.bytes.size()==64,"small positive writes unbounded");
    auto first=f.tasks.front(); f.step(w); expect(f.tasks.size()==1,"continuation missing");
    auto before=f.calls; w.resume(first.generation,first.ticket); expect(f.calls==before && f.tasks.size()==1,"old duplicate ticket drained next turn");
    w.writable(w.generation()); expect(f.calls==before,"readiness drained while continuation pending");
    w.enqueue("TAIL",4); expect(f.calls==before,"enqueue while pending drained");
    while (!f.tasks.empty()) f.step(w);
    expect(f.bytes==original+"TAIL" && w.pendingBytes()==0 && w.driverState()==DriverState::Idle,"FIFO/suffix loss during yielding");
    w.resume(first.generation,first.ticket); w.writable(w.generation()); expect(f.calls==1004,"duplicate idle callbacks wrote");
  }
  {
    Fake f; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true);
    std::string full(TransportWriter::MaximumPendingBytes,'b'); w.enqueue(full.data(),full.size());
    expect(f.calls==1 && f.bytes.size()==65536 && f.maxOffer==65536,"write offer/byte budget unbounded");
    while (!f.tasks.empty()) f.step(w);
    expect(f.bytes==full && f.calls==16,"byte-budget continuation stream wrong");
  }
  {
    Fake f; f.interrupts=1000; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true); w.enqueue("OLD",3);
    Task old=f.pop(); w.close(); expect(w.driverState()==DriverState::Closed,"close driver not cleared");
    w.open(10,true); f.interrupts=0; auto calls=f.calls; w.resume(old.generation,old.ticket); w.writable(old.generation);
    expect(f.calls==calls,"old generation touched reused descriptor"); w.enqueue("NEW",3);
    expect(f.bytes=="NEW" && w.pendingBytes()==0,"cancelled suffix replayed");
  }
  {
    Fake f; f.block=true; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true);
    std::string payload(1000,'c'); w.enqueue(payload.data(),payload.size());
    expect(f.arms==1 && f.tasks.empty() && w.driverState()==DriverState::WritableWaiting,"EAGAIN must wait, not self-reschedule");
    f.block=false; f.tiny=1; auto calls=f.calls; w.writable(w.generation());
    expect(f.calls-calls==64 && f.disarms==1 && f.tasks.size()==1 && w.driverState()==DriverState::ContinuationPending,"ready-to-budget driver overlap");
    calls=f.calls; w.writable(w.generation()); expect(f.calls==calls,"stale readiness bypassed continuation");
    f.block=true; f.step(w); expect(f.tasks.empty() && f.arms==2 && w.driverState()==DriverState::WritableWaiting,"continuation EAGAIN did not switch to readiness");
    f.block=false; f.tiny=0; w.writable(w.generation()); expect(f.bytes==payload && w.driverState()==DriverState::Idle,"ready completion lost bytes");
  }
  {
    Fake f; f.inlineCallback=true; f.interrupts=1000; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true); w.enqueue("x",1);
    expect(f.calls==64 && !w.error().empty() && w.driverState()==DriverState::Closed,"inline/reentrant scheduling must fail closed");
  }
  {
    Fake f; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,false);
    w.enqueue("denied",6); w.writable(w.generation()); w.resume(w.generation(),1);
    expect(f.calls==0 && f.tasks.empty() && f.arms==0,"Observe scheduled or wrote");
  }
  {
    Fake f; f.interrupts=100; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true); w.enqueue("recovered",9);
    expect(f.calls==64 && f.tasks.size()==1,"recoverable EINTR did not yield");
    f.step(w); expect(f.calls==101 && f.bytes=="recovered" && w.error().empty() && f.tasks.empty(),"EINTR suffix did not recover across turns");
  }
  {
    Fake f; f.tiny=1; TransportWriter w(f.adapter()); f.writer=&w; w.open(10,true);
    std::string old(1000,'o'); w.enqueue(old.data(),old.size()); Task stale=f.pop();
    expect(f.bytes==old.substr(0,64),"expected bounded delivered prefix");
    w.close(); w.open(10,true); f.tiny=0; auto calls=f.calls;
    w.resume(stale.generation,stale.ticket); expect(f.calls==calls,"old partial continuation wrote");
    w.enqueue("NEW",3); expect(f.bytes==old.substr(0,64)+"NEW" && f.closeInvariant,"old admitted suffix replayed on new generation");
  }
  {
    Fake f; auto adapter=f.adapter(); adapter.scheduleContinuation={};
    TransportWriter w(adapter); f.writer=&w; w.open(10,true);
    std::string payload(65537,'x'); w.enqueue(payload.data(),payload.size());
    expect(f.bytes.size()==65536 && !w.error().empty() && w.pendingBytes()==0 && f.closeInvariant,"missing asynchronous scheduler must fail visibly, not spin");
  }
  std::cout<<"fairness call/byte budgets, finite no-progress, FIFO, driver exclusion, generation/ticket, cancellation and Observe checks pass\n";
}
