#pragma once

// Exact operations explicitly reported by a verified script adapter. This is
// not a native DB detour and does not observe arbitrary quest graph writes.
#include <cmath>
#include <cstdint>
#include <deque>
#include <set>
#include <string>

namespace witcher_native_bridge {
struct FactOperation {
    int generation = 0;
    int revision = 0;
    std::string scope;
    std::string kind;
    std::string target;
    int value = 0;
    int validFor = 0;
    bool telemetry = false;
    float observedAt = 0;
};

class FactOperationJournal {
public:
    explicit FactOperationJournal(std::size_t capacity = 256, std::size_t watches = 128)
        : capacity_(capacity), maxWatches_(watches) {}

    static bool Allowed(const std::string& value) {
        if (value.size() <= 8 || value.size() > 96 || value.compare(0, 8, "sc_test_") != 0) return false;
        for (unsigned char ch : value)
            if (!((ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') ||
                  (ch >= '0' && ch <= '9') || ch == '_')) return false;
        return true;
    }

    int Reset() {
        generation_ = generation_ == INT32_MAX ? 1 : generation_ + 1;
        revision_ = 0;
        scope_.clear();
        watches_.clear();
        pending_.clear();
        remote_ = false;
        error_.clear();
        return generation_;
    }

    bool Begin(const std::string& scope) {
        if (!error_.empty() || !Allowed(scope) || remote_) return false;
        if (!scope_.empty()) return scope_ == scope;
        scope_ = scope;
        watches_.clear();
        return true;
    }

    bool Watch(const std::string& target) {
        if (!error_.empty() || scope_.empty() || remote_ || !Allowed(target)) return false;
        if (watches_.count(target)) return true;
        if (watches_.size() >= maxWatches_) return false;
        watches_.insert(target);
        return true;
    }

    bool End() {
        if (scope_.empty() || remote_) return false;
        scope_.clear();
        watches_.clear();
        return true;
    }

    bool BeginRemote() {
        if (!error_.empty() || scope_.empty() || remote_) return false;
        remote_ = true;
        return true;
    }

    bool EndRemote() {
        if (!remote_) return false;
        remote_ = false;
        return true;
    }

    bool Record(const std::string& kind, const std::string& target, int value,
                int validFor, bool telemetry, float observedAt) {
        if (!error_.empty() || scope_.empty() || !Allowed(target) || !watches_.count(target)) return false;
        if ((kind != "add" && kind != "remove") || !std::isfinite(observedAt) || observedAt < 0) return false;
        if (kind == "remove" && (value != 0 || validFor != 0 || telemetry)) return false;
        if (remote_) return true; // preserve earlier local pending operations; suppress only this bracket
        if (pending_.size() >= capacity_ || revision_ == INT32_MAX) {
            error_ = "OVERFLOW_RECONCILE_REQUIRED";
            return false; // do not replace the oldest event or silently advance revision
        }
        pending_.push_back({generation_, ++revision_, scope_, kind, target, value, validFor, telemetry, observedAt});
        return true;
    }

    bool Peek(FactOperation& operation) const {
        if (pending_.empty()) return false;
        operation = pending_.front();
        return true;
    }

    bool Ack(int generation, int revision) {
        if (!error_.empty() || pending_.empty() || pending_.front().generation != generation ||
            pending_.front().revision != revision) return false;
        pending_.pop_front();
        return true;
    }

    const std::string& Error() const { return error_; }
    bool Active() const { return !scope_.empty(); }
    bool ApplyingRemote() const { return remote_; }
    std::size_t PendingCount() const { return pending_.size(); }
    int Generation() const { return generation_; }
private:
    std::size_t capacity_;
    std::size_t maxWatches_;
    int generation_ = 1;
    int revision_ = 0;
    std::string scope_;
    std::set<std::string> watches_;
    std::deque<FactOperation> pending_;
    bool remote_ = false;
    std::string error_;
};
}
