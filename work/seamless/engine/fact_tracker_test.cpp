#include "../../WitcherOnline/client/seamless/FactDeltaTracker.h"
#include <cstdio>
#include <cstdlib>

#define CHECK(condition) do { if (!(condition)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); std::exit(1); } } while (false)
using seamless::FactChange;
using seamless::FactDeltaTracker;
using seamless::FactState;

int main() {
    FactDeltaTracker tracker;
    FactDeltaTracker::Snapshot state{{"sc_test_a", 5}};
    CHECK(!tracker.Watch("quest_real_branch", state));
    CHECK(!tracker.Watch("sc_test_bad\n", state));
    CHECK(!tracker.Watch("sc_test_", state));
    {
        // Only the exact vetted real quest fact; neighbours and lookalikes stay refused.
        FactDeltaTracker quest;
        FactDeltaTracker::Snapshot world{{"mh306_job_taken", 0}};
        CHECK(quest.Watch("mh306_job_taken", world));
        CHECK(!quest.Watch("mh306_job_taken_x", world));
        CHECK(!quest.Watch("mh307_job_taken", world));
        CHECK(!quest.Watch("mh306_job_take", world));
        world["mh306_job_taken"] = 1;
        CHECK(quest.Observe(world));
        FactChange taken;
        CHECK(quest.Peek(taken) && taken.target == "mh306_job_taken" && taken.after == FactState::Present(1));
    }
    CHECK(tracker.Watch("sc_test_a", state));
    CHECK(tracker.Watch("sc_test_b", state));
    CHECK(tracker.Observe(state));
    FactChange event;
    CHECK(!tracker.Peek(event));

    // Decrease is not a max merge. Existing-zero and absence are distinct.
    state["sc_test_a"] = 0;
    CHECK(tracker.Observe(state));
    CHECK(tracker.Peek(event));
    CHECK(event.before == FactState::Present(5));
    CHECK(event.after == FactState::Present(0));
    int first = event.revision;
    CHECK(!tracker.Ack(event.generation, first + 1));
    state.erase("sc_test_a");
    CHECK(tracker.Observe(state));
    CHECK(tracker.PendingCount() == 2);
    CHECK(tracker.Peek(event) && event.revision == first);
    CHECK(tracker.Ack(event.generation, event.revision));
    CHECK(tracker.Peek(event) && event.after == FactState::Absent());
    CHECK(tracker.Ack(event.generation, event.revision));

    // A local change before remote apply survives; remote apply doesn't echo;
    // unrelated local changes during apply are not swallowed; later local delta survives.
    state["sc_test_a"] = 7;
    CHECK(tracker.BeginRemote("sc_test_a", state));
    CHECK(!tracker.BeginRemote("sc_test_b", state));
    CHECK(!tracker.Observe(state));
    state["sc_test_a"] = 11;
    state["sc_test_b"] = 9;
    CHECK(tracker.EndRemote(state));
    CHECK(tracker.PendingCount() == 2);
    CHECK(tracker.Peek(event) && event.target == "sc_test_a" && event.after.value == 7);
    CHECK(tracker.Ack(event.generation, event.revision));
    CHECK(tracker.Peek(event) && event.target == "sc_test_b" && event.after.value == 9);
    CHECK(tracker.Ack(event.generation, event.revision));
    CHECK(tracker.Observe(state) && !tracker.Peek(event));
    state["sc_test_a"] = 12;
    CHECK(tracker.Observe(state));
    CHECK(tracker.Peek(event) && event.before.value == 11 && event.after.value == 12);

    int oldGeneration = event.generation;
    int oldRevision = event.revision;
    tracker.Reset();
    CHECK(tracker.WatchedCount() == 0 && tracker.PendingCount() == 0);
    CHECK(tracker.Watch("sc_test_a", state));
    state["sc_test_a"] = 20;
    CHECK(tracker.Observe(state));
    CHECK(!tracker.Ack(oldGeneration, oldRevision));
    CHECK(tracker.Peek(event) && event.generation != oldGeneration);
    CHECK(!tracker.Ack(oldGeneration, event.revision));

    // Bounded all-or-nothing snapshots and head-only ACK, no overwritten pending events.
    FactDeltaTracker bounded(1, 2);
    FactDeltaTracker::Snapshot small;
    CHECK(bounded.Watch("sc_test_a", small));
    CHECK(bounded.Watch("sc_test_b", small));
    CHECK(!bounded.Watch("sc_test_c", small));
    small["sc_test_a"] = 1;
    small["sc_test_b"] = 2;
    CHECK(!bounded.Observe(small));
    CHECK(bounded.PendingCount() == 0);
    small.erase("sc_test_b");
    CHECK(bounded.Observe(small));
    small["sc_test_a"] = 3;
    CHECK(!bounded.BeginRemote("sc_test_a", small));
    CHECK(bounded.Peek(event) && event.after.value == 1);
    CHECK(bounded.Ack(event.generation, event.revision));
    CHECK(bounded.Observe(small));
    CHECK(bounded.Peek(event) && event.before.value == 1 && event.after.value == 3);
    CHECK(!bounded.EndRemote(small));
    std::puts("PASS fact tracker: allowlist, decrease, zero/removal, immutable retry, remote interleave, load generation, bounded capture");
}
