#include "../../WitcherNativeBridge/src/FactOperationJournal.h"
#include <cstdio>
#include <cstdlib>
#include <limits>

static int checks = 0;
#define CHECK(condition) do { ++checks; if (!(condition)) { std::fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); std::exit(1); } } while (false)
using witcher_native_bridge::FactOperation;
using witcher_native_bridge::FactOperationJournal;

int main() {
    FactOperationJournal journal;
    FactOperation event;
    CHECK(!journal.Record("add", "sc_test_fact", 7, -1, false, 10));
    CHECK(!journal.Begin("quest_real"));
    CHECK(!journal.Begin("sc_test_"));
    CHECK(!journal.Begin("sc_test_scope\n"));
    CHECK(journal.Begin("sc_test_scope"));
    CHECK(journal.Begin("sc_test_scope"));
    CHECK(!journal.Begin("sc_test_other"));
    CHECK(!journal.Watch("real_quest_fact"));
    CHECK(!journal.Watch("sc_test_a/b"));
    CHECK(journal.Watch("sc_test_fact"));
    CHECK(journal.Watch("sc_test_fact"));
    CHECK(!journal.Record("add", "sc_test_not_watched", 7, -1, false, 10));
    CHECK(!journal.Record("wrong", "sc_test_fact", 7, -1, false, 10));
    CHECK(!journal.Record("add", "sc_test_fact", 7, -1, false, -1));
    CHECK(!journal.Record("add", "sc_test_fact", 7, -1, false, std::numeric_limits<float>::quiet_NaN()));
    CHECK(!journal.Record("remove", "sc_test_fact", 7, 0, false, 10));
    CHECK(!journal.Record("remove", "sc_test_fact", 0, -1, false, 10));
    CHECK(!journal.Record("remove", "sc_test_fact", 0, 0, true, 10));
    CHECK(journal.Error().empty());
    CHECK(!journal.Peek(event));

    // Four writes which can occur and reverse within one engine frame. Exact
    // operations remain available; no polling snapshot could reconstruct them.
    CHECK(journal.Record("add", "sc_test_fact", 7, 30, true, 12.5f));
    CHECK(journal.Record("remove", "sc_test_fact", 0, 0, false, 12.5f));
    CHECK(journal.Record("add", "sc_test_fact", 0, -1, false, 12.5f));
    CHECK(journal.Record("add", "sc_test_fact", -3, 2, false, 12.5f));
    CHECK(journal.PendingCount() == 4);
    CHECK(journal.Peek(event));
    CHECK(event.generation == journal.Generation() && event.revision == 1);
    CHECK(event.scope == "sc_test_scope" && event.kind == "add" && event.target == "sc_test_fact");
    CHECK(event.value == 7 && event.validFor == 30 && event.telemetry && event.observedAt == 12.5f);
    int generation = event.generation;
    CHECK(!journal.Ack(generation, 2));
    CHECK(!journal.Ack(generation + 1, 1));
    CHECK(journal.Peek(event) && event.revision == 1 && event.value == 7);
    CHECK(journal.Ack(generation, 1));
    CHECK(journal.Peek(event) && event.revision == 2 && event.kind == "remove" && event.value == 0);
    CHECK(journal.Ack(generation, 2));
    CHECK(journal.Peek(event) && event.revision == 3 && event.kind == "add" && event.value == 0 && event.validFor == -1);
    CHECK(journal.Ack(generation, 3));
    CHECK(journal.Peek(event) && event.revision == 4 && event.value == -3 && event.validFor == 2);
    CHECK(journal.Ack(generation, 4));
    CHECK(!journal.Peek(event));

    // Remote apply must not swallow earlier local operations or produce an echo.
    CHECK(journal.Record("add", "sc_test_fact", 5, -1, false, 13));
    CHECK(journal.BeginRemote());
    CHECK(!journal.BeginRemote());
    CHECK(!journal.End());
    CHECK(!journal.Watch("sc_test_other"));
    CHECK(journal.Record("remove", "sc_test_fact", 0, 0, false, 14));
    CHECK(journal.Record("add", "sc_test_fact", 9, 20, false, 14));
    CHECK(journal.PendingCount() == 1);
    CHECK(journal.Peek(event) && event.value == 5 && event.revision == 5);
    CHECK(journal.EndRemote());
    CHECK(!journal.EndRemote());
    CHECK(journal.Record("add", "sc_test_fact", 11, -1, false, 15));
    CHECK(journal.PendingCount() == 2);
    CHECK(journal.Ack(generation, 5));
    CHECK(journal.Peek(event) && event.value == 11);
    CHECK(journal.Ack(generation, 6));
    CHECK(journal.End());
    CHECK(!journal.End());
    CHECK(!journal.Record("add", "sc_test_fact", 22, -1, false, 16));
    CHECK(journal.Begin("sc_test_different_scope"));
    CHECK(!journal.Record("add", "sc_test_fact", 23, -1, false, 16)); // watches do not leak across contexts
    CHECK(journal.Watch("sc_test_fact"));
    CHECK(journal.Record("add", "sc_test_fact", 24, -1, false, 16));
    CHECK(journal.Peek(event) && event.scope == "sc_test_different_scope");

    // A stale pre-load ACK cannot match an identically numbered post-load event.
    CHECK(journal.Reset() != generation);
    CHECK(!journal.Active() && !journal.ApplyingRemote() && !journal.Peek(event));
    CHECK(journal.Begin("sc_test_scope"));
    CHECK(journal.Watch("sc_test_fact"));
    CHECK(journal.Record("add", "sc_test_fact", 1, -1, false, 20));
    CHECK(journal.Peek(event) && event.revision == 1);
    CHECK(!journal.Ack(generation, 1));
    CHECK(journal.Ack(event.generation, 1));

    FactOperationJournal bounded(1, 1);
    CHECK(bounded.Begin("sc_test_scope"));
    CHECK(bounded.Watch("sc_test_a"));
    CHECK(!bounded.Watch("sc_test_b"));
    CHECK(bounded.Record("add", "sc_test_a", 1, -1, false, 1));
    CHECK(!bounded.Record("add", "sc_test_a", 2, -1, false, 2));
    CHECK(bounded.PendingCount() == 1);
    CHECK(!bounded.Error().empty());
    CHECK(bounded.Peek(event) && event.value == 1 && event.revision == 1);
    CHECK(!bounded.Ack(event.generation, event.revision)); // a gap cannot be acknowledged away
    CHECK(bounded.End());
    CHECK(!bounded.Begin("sc_test_scope"));
    CHECK(bounded.Reset() > 1);
    CHECK(bounded.Error().empty());
    CHECK(bounded.Begin("sc_test_scope"));
    CHECK(bounded.Watch("sc_test_a"));
    CHECK(bounded.Record("add", "sc_test_a", 3, -1, false, 3));
    CHECK(bounded.Peek(event) && event.revision == 1 && event.value == 3);

    FactOperationJournal empty(0);
    CHECK(empty.Begin("sc_test_scope") && empty.Watch("sc_test_fact"));
    CHECK(!empty.Record("add", "sc_test_fact", 1, -1, false, 1));
    CHECK(empty.PendingCount() == 0 && !empty.Error().empty());
    std::printf("Fact operation journal PASS: %d checks\n", checks);
}
