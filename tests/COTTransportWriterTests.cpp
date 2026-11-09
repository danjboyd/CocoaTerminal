// SPDX-License-Identifier: LGPL-2.1-or-later
#include "COTTransportWriter.h"
#include <cerrno>
#include <cstdlib>
#include <deque>
#include <iostream>
#include <string>
using namespace cot;
static void expect(bool condition, const char *message) { if (!condition) { std::cerr<<message<<"\n"; std::exit(1); } }
struct Fake {
  std::deque<WriteResult> script;
  std::string bytes;
  int calls=0, arms=0, disarms=0, closes=0;
  TransportWriter::Adapter adapter() {
    return {
      [this](int,const char *data,std::size_t length) {
        ++calls; WriteResult r{static_cast<std::ptrdiff_t>(length),0};
        if (!script.empty()) { r=script.front(); script.pop_front(); }
        if (r.count>0 && static_cast<std::size_t>(r.count)<=length) bytes.append(data,r.count);
        return r;
      },
      [this](int,std::uint64_t){ ++arms; }, [this](){ ++disarms; }, [this](int){ ++closes; }
    };
  }
};
int main() {
  {
    Fake f; TransportWriter w(f.adapter()); expect(w.open(10,true),"open");
    f.script={{2,0},{-1,EINTR},{-1,EAGAIN}};
    std::string a="abcdef";
    expect(w.enqueue(a.data(),a.size())==EnqueueResult::Accepted,"whole admission");
    a.assign("XXXXXX"); expect(w.pendingBytes()==4 && f.bytes=="ab" && f.arms==1,"suffix retained");
    expect(w.enqueue("GH",2)==EnqueueResult::Accepted,"second transaction admitted");
    expect(f.arms==1 && w.pendingBytes()==6,"no duplicate arm or dropped suffix");
    w.writable(w.generation()); expect(f.bytes=="abcdefGH" && w.pendingBytes()==0 && f.disarms==1,"FIFO immutable complete stream");
  }
  {
    Fake f; TransportWriter w(f.adapter()); w.open(10,true); f.script={{-1,EAGAIN}};
    std::string full(TransportWriter::MaximumPendingBytes,'x');
    expect(w.enqueue(full.data(),full.size())==EnqueueResult::Accepted,"limit admitted");
    int calls=f.calls; expect(w.enqueue("z",1)==EnqueueResult::Backpressured,"overflow whole reject");
    expect(w.pendingBytes()==full.size() && f.calls==calls,"overflow no write or trim");
    auto old=w.generation(); w.close(); expect(f.closes==1 && w.pendingBytes()==0 && f.disarms==1,"close cancels suffix");
    expect(w.open(10,true),"descriptor reused new generation"); w.writable(old);
    expect(f.bytes.empty() && f.calls==calls,"old generation never replayed");
    w.enqueue("new",3); expect(f.bytes=="new","new generation works"); w.close(); w.close(); expect(f.closes==2,"close once each owned fd");
  }
  {
    Fake f; TransportWriter w(f.adapter()); w.open(10,false);
    expect(w.enqueue("input",5)==EnqueueResult::Closed && f.calls==0 && f.arms==0,"Observe denies enqueue");
    w.writable(w.generation()); expect(f.calls==0,"Observe denies final drain");
    expect(!w.open(11,true),"cannot promote or replace open generation");
  }
  {
    Fake f; TransportWriter w(f.adapter());
    expect(w.enqueue("x",1)==EnqueueResult::Closed,"closed result"); w.open(10,true); f.script={{-1,EIO}};
    expect(w.enqueue("bad",3)==EnqueueResult::Accepted,"admission is not child execution");
    expect(!w.error().empty() && f.closes==1 && w.pendingBytes()==0,"permanent error visible and closes");
    expect(w.enqueue("retry",5)==EnqueueResult::Failed,"failed result no auto replay");
    w.open(11,true); expect(w.error().empty(),"new explicit generation clears error");
    w.enqueue("ok",2); expect(f.bytes=="ok","failed bytes not replayed");
  }
  {
    Fake f; TransportWriter w(f.adapter()); w.open(10,true);
    const std::string paste="\033[200~payload\033[201~";
    f.script={{3,0},{-1,EAGAIN}}; w.enqueue(paste.data(),paste.size());
    int pausedCalls=f.calls;
    expect(w.enqueue("reply",5)==EnqueueResult::Accepted && f.calls==pausedCalls,"armed writer waits for readiness");
    f.script={{-1,EAGAIN}}; w.writable(w.generation());
    expect(f.calls==pausedCalls+1 && w.pendingBytes()==paste.size()+5-3,"EAGAIN readiness retains exact suffix");
    w.writable(w.generation()); expect(f.bytes==paste+"reply","paste transaction cannot interleave with reply");
  }
  {
    Fake f; TransportWriter w(f.adapter()); w.open(10,true); f.script={{-1,EAGAIN}};
    w.enqueue("old",3); auto generation=w.generation(); f.script={{-1,EPIPE}};
    w.writable(generation); expect(!w.error().empty() && f.closes==1 && w.pendingBytes()==0,"asynchronous failure observable and cancelled");
    w.writable(generation); expect(f.calls==2,"stale readiness cannot retry failed suffix");
  }
  {
    Fake f; TransportWriter w(f.adapter()); w.open(10,true);
    expect(w.enqueue("x",TransportWriter::MaximumPendingBytes+1)==EnqueueResult::Backpressured && f.calls==0 && w.pendingBytes()==0,"oversize rejected before copy or write");
  }
  for (WriteResult r : {WriteResult{0,0},WriteResult{9,0}}) {
    Fake f; TransportWriter w(f.adapter()); w.open(10,true); f.script={r}; w.enqueue("x",1);
    expect(!w.error().empty(),"zero/invalid writer result fails instead of spinning");
  }
  std::cout<<"injected writer admission/backpressure/FIFO/partial/EINTR/EAGAIN/Observe/generation/error checks pass\n";
}
