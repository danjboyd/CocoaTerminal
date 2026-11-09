// SPDX-License-Identifier: LGPL-2.1-or-later
#include "Model.h"
#include <cstdlib>
#include <deque>
#include <iostream>
using namespace cot::review;
static void expect(bool x,const char *message) { if (!x) { std::cerr<<message<<"\n"; std::exit(1); } }
int main() {
  {
    State s; Gate g; auto token=std::make_shared<Token>(s);
    Task task{token}; task.releaseExternalAfterAcquire=true;
    expect(task.run(g)==Result::Worked,"acquire-before-final-release must own a lease");
    expect(s.accesses==1 && s.leases==0 && s.deallocating,"dealloc must wait until final callback access and lease release");
  }
  {
    State s; Gate g; auto token=std::make_shared<Token>(s); std::deque<Task> q{{token}};
    s.finalExternalRelease(); // Exact paused-before-owner-fence interleaving.
    expect(s.deallocating && !s.ownerFenced && g.open,"dealloc-before-fence setup");
    expect(q.front().run(g)==Result::Nil && s.accesses==0 && s.leases==0,"weak acquisition after begin-dealloc must be nil before fence");
    g.shutdown(*token,s); expect(s.stores==1 && q.front().run(g)==Result::Nil,"late fence cannot resurrect");
  }
  for (Path path:{Path::Work,Path::Cancel,Path::CancelAfterAcquire,Path::Error,Path::Throw}) {
    State s; Gate g; auto token=std::make_shared<Token>(s); Task task{token}; task.path=path;
    try { task.run(g); } catch(const std::runtime_error &) { expect(path==Path::Throw,"unexpected exception"); }
    expect(s.leases==0,"lease leaked on return/error/cancel/exception");
    s.finalExternalRelease();
    if (path==Path::Error) { expect(!s.deallocating && s.notifications==1,"valid notification must own lifetime"); s.deliverNotification(); }
    expect(s.deallocating && s.notifications==0,"all session ownership must retire");
  }
  {
    State s; Gate g; auto token=std::make_shared<Token>(s);
    Lease lease=token->atomicWeakRetainedLoad(); s.finalExternalRelease();
    expect(!s.deallocating && s.leases==1,"lease keeps session alive");
    g.shutdown(*token,s); expect(!token->atomicWeakRetainedLoad(),"explicit weak invalidation prevents new leases");
    expect(!g.matches(1,1,1),"shutdown gate invalidates queued work");
    lease.get().access(); // Already-owned lease is not forcibly released.
  }
  for (unsigned mismatch=0;mismatch<3;++mismatch) {
    State s; Gate g; auto token=std::make_shared<Token>(s); Task task{token};
    if (mismatch==0) ++task.owner; else if(mismatch==1) ++task.generation; else ++task.ticket;
    expect(task.run(g)==Result::Stale && s.accesses==0 && s.leases==0,"owner/generation/ticket mismatch leaked or accessed");
    g.supersede(); expect(task.run(g)==Result::Stale && s.leases==0,"superseded callback accessed session");
  }
  {
    State s; Gate g; std::deque<Task> q; std::weak_ptr<Token> weak;
    { auto token=std::make_shared<Token>(s); weak=token; q.push_back(Task{token}); q.push_back(Task{token}); }
    expect(!weak.expired(),"queued blocks must own token"); s.finalExternalRelease();
    while(!q.empty()) { expect(q.front().run(g)==Result::Nil,"late task resurrected deallocating session"); q.pop_front(); }
    expect(weak.expired() && s.accesses==0,"token lifetime must end after last queued block");
  }
  {
    State s; Gate g; auto token=std::make_shared<Token>(s); Task task{token};
    s.finalExternalRelease(); task.path=Path::Error;
    expect(task.run(g)==Result::Nil && s.notifications==0,"error path retained session after dealloc began");
    Retirement retirement; token.reset(); retirement.acknowledge(); retirement.acknowledge();
    expect(retirement.closes==1,"late fd-only retirement must be idempotent and session-free");
  }
  for (bool supersede:{false,true}) {
    State s; Gate g; auto token=std::make_shared<Token>(s); Task task{token};
    task.fenceAfterAcquire=!supersede; task.supersedeAfterAcquire=supersede;
    expect(task.run(g)==Result::Stale && s.leases==0 && s.accesses==0,"shutdown/supersession between acquire and guard leaked lease or performed work");
    s.finalExternalRelease(); expect(s.deallocating,"post-guard path retained session");
  }
  std::cout<<"pure assumed-atomic lifetime model: acquire/release ordering, pre-fence dealloc, all paths, token ownership, stale/cancel/error/supersession checks pass\n";
}
