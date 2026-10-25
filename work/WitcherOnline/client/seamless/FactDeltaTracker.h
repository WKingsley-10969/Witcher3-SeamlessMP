#pragma once

// Snapshot-based, allowlisted observation only. Not a quest effect hook: changes
// that occur and reverse between Observe calls cannot be reconstructed.
#include <cstdint>
#include <deque>
#include <map>
#include <string>
#include <vector>

namespace seamless {
struct FactState {
    bool exists = false;
    int value = 0;
    static FactState Absent() { return {}; }
    static FactState Present(int value) { return {true, value}; }
    bool operator==(const FactState& other) const {
        return exists == other.exists && (!exists || value == other.value);
    }
    bool operator!=(const FactState& other) const { return !(*this == other); }
};

struct FactChange {
    int generation = 0;
    int revision = 0;
    std::string target;
    FactState before;
    FactState after;
};

class FactDeltaTracker {
public:
    using Snapshot = std::map<std::string, int>;
    explicit FactDeltaTracker(std::size_t maxPending = 512, std::size_t maxWatched = 128)
        : maxPending_(maxPending), maxWatched_(maxWatched) {}

    // Real quest facts are enabled one at a time, each backed by probe evidence of what its
    // quest writes. mh306_job_taken: the "Novigrad Hunt: Da'o" notice (native FactsAdd).
    static bool IsVettedQuestFact(const std::string& target) {
        return target == "mh306_job_taken";
    }
    static bool IsAllowed(const std::string& target) {
        if (IsVettedQuestFact(target)) return true;
        if (target.size() <= 8 || target.size() > 96 || target.compare(0, 8, "sc_test_") != 0)
            return false;
        for (unsigned char ch : target)
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                  (ch >= '0' && ch <= '9') || ch == '_'))
                return false;
        return true;
    }

    // Reset on every game load. Old ACKs cannot consume the new generation.
    // Watched names are cleared: an explicit adapter must select and seed them.
    int Reset() {
        generation_ = generation_ == 2147483647 ? 1 : generation_ + 1;
        revision_ = 0;
        watched_.clear();
        pending_.clear();
        remoteTarget_.clear();
        return generation_;
    }

    bool Watch(const std::string& target, const Snapshot& current) {
        if (!IsAllowed(target) || !remoteTarget_.empty()) return false;
        if (watched_.find(target) != watched_.end()) return true;
        if (watched_.size() >= maxWatched_) return false;
        watched_.emplace(target, StateOf(current, target));
        return true;
    }

    // All-or-nothing capture: never advance the observed baseline if events
    // cannot be retained. A full queue or exhausted sequence blocks apply.
    bool Observe(const Snapshot& current) {
        if (!remoteTarget_.empty()) return false;
        return Capture(current);
    }

    bool Peek(FactChange& out) const {
        if (pending_.empty()) return false;
        out = pending_.front();
        return true;
    }

    bool Ack(int generation, int revision) {
        if (pending_.empty() || pending_.front().generation != generation ||
            pending_.front().revision != revision) return false;
        pending_.pop_front();
        return true;
    }

    // Must bracket one synchronous script apply, without a yield. Capture any
    // local changes FIRST; preserve those queued events when accepting remote state.
    bool BeginRemote(const std::string& target, const Snapshot& beforeApply) {
        if (!remoteTarget_.empty() || watched_.find(target) == watched_.end()) return false;
        if (!Capture(beforeApply)) return false;
        remoteTarget_ = target;
        return true;
    }

    // Read the actual engine state after apply (including on failed readback).
    // Only the bracketed target is suppressed; unrelated local changes still
    // become pending events. If capture is full, retain baseline for later retry.
    bool EndRemote(const Snapshot& afterApply) {
        if (remoteTarget_.empty()) return false;
        watched_[remoteTarget_] = StateOf(afterApply, remoteTarget_);
        remoteTarget_.clear();
        return Capture(afterApply);
    }

    int Generation() const { return generation_; }
    std::size_t PendingCount() const { return pending_.size(); }
    std::size_t WatchedCount() const { return watched_.size(); }
    bool ApplyingRemote() const { return !remoteTarget_.empty(); }

private:
    static FactState StateOf(const Snapshot& snapshot, const std::string& target) {
        auto found = snapshot.find(target);
        return found == snapshot.end() ? FactState::Absent() : FactState::Present(found->second);
    }
    bool Capture(const Snapshot& current) {
        std::vector<FactChange> changes;
        for (const auto& entry : watched_) {
            FactState after = StateOf(current, entry.first);
            if (after != entry.second)
                changes.push_back({generation_, 0, entry.first, entry.second, after});
        }
        if (changes.size() > maxPending_ - pending_.size() ||
            changes.size() > static_cast<std::size_t>(2147483647 - revision_)) return false;
        for (auto& change : changes) {
            change.revision = ++revision_;
            watched_[change.target] = change.after;
            pending_.push_back(change);
        }
        return true;
    }
    int generation_ = 1;
    int revision_ = 0;
    std::size_t maxPending_;
    std::size_t maxWatched_;
    std::map<std::string, FactState> watched_;
    std::deque<FactChange> pending_;
    std::string remoteTarget_;
};
} // namespace seamless
