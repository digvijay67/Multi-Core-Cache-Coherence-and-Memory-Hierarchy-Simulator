#include "cache_simulator.hpp"

#include <algorithm>
#include <limits>
#include <stdexcept>

namespace cache_sim {
namespace {

constexpr std::size_t kMaximumCores = 256;
constexpr std::size_t kMaximumCacheLines = 1'000'000;
constexpr std::size_t kMaximumPrivateCacheLines = 8'000'000;

std::size_t setIndex(std::uint64_t block, std::size_t setCount) {
    return static_cast<std::size_t>(block % setCount);
}

} // namespace

void CacheConfig::validate() const {
    if (cores == 0 || cores > kMaximumCores) {
        throw std::invalid_argument("core count must be between 1 and 256");
    }
    if (l1Sets == 0 || l1Ways == 0 || l2Sets == 0 || l2Ways == 0) {
        throw std::invalid_argument("cache set and way counts must be greater than zero");
    }
    if (l1Sets > (kMaximumPrivateCacheLines / cores) / l1Ways
        || l2Sets > kMaximumCacheLines / l2Ways) {
        throw std::invalid_argument("L1 caches may contain at most 8,000,000 lines total; L2 may contain at most 1,000,000");
    }
    if (blockSize == 0) {
        throw std::invalid_argument("block size must be greater than zero");
    }
    if (l1Latency == 0 || l2Latency == 0 || memoryLatency == 0) {
        throw std::invalid_argument("L1, L2, and memory latencies must be greater than zero");
    }
}

bool Simulator::EventLater::operator()(const Event& left, const Event& right) const noexcept {
    if (left.cycle != right.cycle) {
        return left.cycle > right.cycle;
    }
    if (left.kind != right.kind) {
        return left.kind > right.kind;
    }
    return left.sequence > right.sequence;
}

Simulator::Simulator(CacheConfig config) : config_(config) {
    config_.validate();
    stats_.cores.resize(config_.cores);
    coreAvailableCycles_.resize(config_.cores);
    corePendingQueues_.resize(config_.cores);

    l1Caches_.resize(config_.cores);
    for (Cache& cache : l1Caches_) {
        cache.sets.resize(config_.l1Sets);
        for (auto& set : cache.sets) {
            set.resize(config_.l1Ways);
        }
    }

    l2Cache_.sets.resize(config_.l2Sets);
    for (auto& set : l2Cache_.sets) {
        set.resize(config_.l2Ways);
    }
}

Simulator::CacheLine* Simulator::findLine(Cache& cache, std::uint64_t block) {
    auto& set = cache.sets[setIndex(block, cache.sets.size())];
    const auto found = std::find_if(set.begin(), set.end(), [block](const CacheLine& line) {
        return line.state != MesiState::Invalid && line.block == block;
    });
    return found == set.end() ? nullptr : &*found;
}

const Simulator::CacheLine* Simulator::findLine(const Cache& cache, std::uint64_t block) const {
    const auto& set = cache.sets[setIndex(block, cache.sets.size())];
    const auto found = std::find_if(set.begin(), set.end(), [block](const CacheLine& line) {
        return line.state != MesiState::Invalid && line.block == block;
    });
    return found == set.end() ? nullptr : &*found;
}

std::uint64_t Simulator::addCycles(std::uint64_t cycle, std::uint64_t duration) const {
    if (duration > std::numeric_limits<std::uint64_t>::max() - cycle) {
        throw std::overflow_error("simulated cycle counter overflow");
    }
    return cycle + duration;
}

std::uint64_t Simulator::addLatency(std::uint64_t base, std::uint64_t extra) const {
    return addCycles(base, extra);
}

void Simulator::schedule(std::uint64_t cycle, std::uint64_t requestId, EventKind kind) {
    if (eventSequence_ == std::numeric_limits<std::uint64_t>::max()) {
        throw std::overflow_error("event sequence counter overflow");
    }
    events_.push(Event{cycle, eventSequence_++, requestId, kind});
}

std::uint64_t Simulator::submit(CacheRequest request) {
    if (request.core >= config_.cores) {
        throw std::out_of_range("core index is outside the configured range");
    }
    if (request.operation != Operation::Read && request.operation != Operation::Write) {
        throw std::invalid_argument("unsupported memory operation");
    }
    if (requests_.size() == std::numeric_limits<std::uint64_t>::max()) {
        throw std::overflow_error("request identifier overflow");
    }

    const std::uint64_t requestId = static_cast<std::uint64_t>(requests_.size());
    PendingRequest pending;
    pending.request = request;
    pending.block = request.address / config_.blockSize;
    pending.result.requestId = requestId;
    pending.result.core = request.core;
    pending.result.operation = request.operation;
    pending.result.address = request.address;
    pending.result.value = request.value;
    pending.result.issueCycle = request.issueCycle;
    requests_.push_back(pending);
    auto& coreQueue = corePendingQueues_[request.core];
    coreQueue.push_back(requestId);
    auto& blockQueue = blockPendingQueues_[requests_.back().block];
    blockQueue.push_back(requestId);
    scheduleEligible(requestId, request.issueCycle);
    return requestId;
}

void Simulator::scheduleEligible(std::uint64_t requestId, std::uint64_t cycle) {
    PendingRequest& pending = requests_.at(static_cast<std::size_t>(requestId));
    const auto& coreQueue = corePendingQueues_[pending.request.core];
    const auto block = blockPendingQueues_.find(pending.block);
    if (pending.startScheduled || coreQueue.empty() || block == blockPendingQueues_.end()
        || block->second.empty() || coreQueue.front() != requestId
        || block->second.front() != requestId) {
        return;
    }
    pending.startScheduled = true;
    schedule(std::max(cycle, pending.request.issueCycle), requestId, EventKind::Start);
}

Simulator::CacheLine& Simulator::insertLine(Cache& cache, std::uint64_t block, std::size_t core) {
    auto& set = cache.sets[setIndex(block, cache.sets.size())];
    auto found = std::find_if(set.begin(), set.end(), [](const CacheLine& line) {
        return line.state == MesiState::Invalid;
    });
    if (found == set.end()) {
        found = std::min_element(set.begin(), set.end(), [](const CacheLine& left, const CacheLine& right) {
            return left.lastUsed < right.lastUsed;
        });
        if (found->state == MesiState::Modified) {
            CacheLine* l2Line = findLine(l2Cache_, found->block);
            if (l2Line == nullptr) {
                throw std::logic_error("modified L1 line is missing from inclusive L2");
            }
            l2Line->data = found->data;
            l2Line->dirty = true;
            l2Line->lastUsed = ++useClock_;
            ++stats_.cores[core].writebacks;
        }
        found->state = MesiState::Invalid;
    }
    *found = CacheLine{block, ++useClock_, 0, MesiState::Invalid, false};
    return *found;
}

std::uint64_t Simulator::insertL2Line(std::uint64_t block) {
    auto& set = l2Cache_.sets[setIndex(block, l2Cache_.sets.size())];
    std::uint64_t writebackLatency = 0;
    auto found = std::find_if(set.begin(), set.end(), [](const CacheLine& line) {
        return line.state == MesiState::Invalid;
    });
    if (found == set.end()) {
        found = std::min_element(set.begin(), set.end(), [](const CacheLine& left, const CacheLine& right) {
            return left.lastUsed < right.lastUsed;
        });

        for (std::size_t core = 0; core < l1Caches_.size(); ++core) {
            if (CacheLine* l1Line = findLine(l1Caches_[core], found->block)) {
                if (l1Line->state == MesiState::Modified) {
                    found->data = l1Line->data;
                    found->dirty = true;
                    ++stats_.cores[core].writebacks;
                }
                l1Line->state = MesiState::Invalid;
                l1Line->dirty = false;
                ++stats_.cores[core].invalidations;
                ++stats_.invalidations;
            }
        }

        if (found->dirty) {
            memory_[found->block] = found->data;
            ++stats_.memoryWritebacks;
            writebackLatency = config_.memoryLatency;
        }
        found->state = MesiState::Invalid;
    }

    const std::uint64_t data = memory_[block];
    *found = CacheLine{block, ++useClock_, data, MesiState::Shared, false};
    return writebackLatency;
}

std::uint64_t Simulator::accessL2(std::uint64_t block) {
    ++stats_.l2Accesses;
    if (CacheLine* line = findLine(l2Cache_, block)) {
        ++stats_.l2Hits;
        line->lastUsed = ++useClock_;
        return 0;
    }

    ++stats_.l2Misses;
    ++stats_.memoryReads;
    const std::uint64_t writebackLatency = insertL2Line(block);
    return addLatency(config_.memoryLatency, writebackLatency);
}

void Simulator::invalidateL1Copies(std::uint64_t block, std::size_t exceptCore) {
    CacheLine* l2Line = findLine(l2Cache_, block);
    for (std::size_t core = 0; core < l1Caches_.size(); ++core) {
        if (core == exceptCore) {
            continue;
        }
        if (CacheLine* line = findLine(l1Caches_[core], block)) {
            if (line->state == MesiState::Modified) {
                if (l2Line == nullptr) {
                    throw std::logic_error("modified L1 line is missing from inclusive L2");
                }
                l2Line->data = line->data;
                l2Line->dirty = true;
                ++stats_.interventions;
                ++stats_.cacheToCacheTransfers;
            }
            line->state = MesiState::Invalid;
            line->dirty = false;
            ++stats_.cores[core].invalidations;
            ++stats_.invalidations;
        }
    }
}

void Simulator::startRequest(std::uint64_t requestId, std::uint64_t cycle) {
    PendingRequest& pending = requests_.at(static_cast<std::size_t>(requestId));
    const std::size_t core = pending.request.core;
    const std::uint64_t block = pending.block;

    const auto& coreQueue = corePendingQueues_[core];
    if (coreQueue.empty() || coreQueue.front() != requestId) {
        throw std::logic_error("per-core request queue ordering was violated");
    }
    std::uint64_t readyCycle = std::max(coreAvailableCycles_[core], blockAvailableCycles_[block]);
    if (readyCycle > cycle) {
        pending.startScheduled = true;
        schedule(readyCycle, requestId, EventKind::Start);
        return;
    }

    CacheLine* line = findLine(l1Caches_[core], block);
    pending.hit = line != nullptr;
    ++stats_.cores[core].accesses;

    if (line != nullptr) {
        ++stats_.cores[core].hits;
        line->lastUsed = ++useClock_;
        const std::uint64_t lookupDone = addCycles(cycle, config_.l1Latency);
        pending.data = line->data;
        pending.finishCycle = lookupDone;

        if (pending.request.operation == Operation::Write
            && line->state == MesiState::Shared) {
            const std::uint64_t busStart = std::max(lookupDone, busAvailableCycle_);
            stats_.busWaitCycles += busStart - lookupDone;
            pending.busGrantCycle = busStart;
            pending.finishCycle = addCycles(busStart, config_.coherenceLatency);
            busAvailableCycle_ = pending.finishCycle;
            ++stats_.coherenceTransactions;
            busArbiterPointer_ = (core + 1) % config_.cores;
            schedule(busStart, requestId, EventKind::BusGrant);
        } else if (pending.request.operation == Operation::Write
                   && line->state == MesiState::Exclusive) {
            pending.busGrantCycle = lookupDone;
            schedule(lookupDone, requestId, EventKind::BusGrant);
        }
    } else {
        ++stats_.cores[core].misses;
        const std::uint64_t lookupDone = addCycles(cycle, config_.l1Latency);

        auto& l2Set = l2Cache_.sets[setIndex(block, l2Cache_.sets.size())];
        const bool l2Hit = findLine(l2Cache_, block) != nullptr;
        if (!l2Hit) {
            const auto victim = std::find_if(l2Set.begin(), l2Set.end(), [](const CacheLine& candidate) {
                return candidate.state == MesiState::Invalid;
            });
            if (victim == l2Set.end()) {
                const auto lru = std::min_element(l2Set.begin(), l2Set.end(),
                    [](const CacheLine& left, const CacheLine& right) {
                        return left.lastUsed < right.lastUsed;
                    });
                const auto busy = blockAvailableCycles_.find(lru->block);
                if (busy != blockAvailableCycles_.end() && busy->second > cycle) {
                    pending.startScheduled = true;
                    schedule(busy->second, requestId, EventKind::Start);
                    return;
                }
            }
        }

        pending.hasModifiedPeer = false;
        bool hasPeerCopy = false;
        for (std::size_t other = 0; other < l1Caches_.size(); ++other) {
            if (other == core) continue;
            if (const CacheLine* peer = findLine(l1Caches_[other], block)) {
                hasPeerCopy = true;
                if (peer->state == MesiState::Modified) {
                    pending.hasModifiedPeer = true;
                    pending.data = peer->data;
                    break;
                }
            }
        }
        if (hasPeerCopy && !l2Hit) {
            throw std::logic_error("inclusive L2 is missing a line present in a private L1");
        }

        pending.l2DataLatency = accessL2(block);
        const std::uint64_t busStart = std::max(lookupDone, busAvailableCycle_);
        stats_.busWaitCycles += busStart - lookupDone;
        pending.busGrantCycle = busStart;
        const std::uint64_t busFinish = addCycles(busStart, config_.coherenceLatency);
        busAvailableCycle_ = busFinish;
        ++stats_.coherenceTransactions;
        busArbiterPointer_ = (core + 1) % config_.cores;

        std::uint64_t serviceLatency = config_.l2Latency;
        if (pending.hasModifiedPeer) {
            serviceLatency = addLatency(serviceLatency, config_.cacheTransferLatency);
        } else {
            serviceLatency = addLatency(serviceLatency, pending.l2DataLatency);
        }
        pending.finishCycle = addCycles(busFinish, serviceLatency);
        schedule(busStart, requestId, EventKind::BusGrant);
    }

    coreAvailableCycles_[core] = pending.finishCycle;
    blockAvailableCycles_[block] = pending.finishCycle;
    schedule(pending.finishCycle, requestId, EventKind::Complete);
}

void Simulator::grantBus(std::uint64_t requestId, std::uint64_t cycle) {
    PendingRequest& pending = requests_.at(static_cast<std::size_t>(requestId));
    const std::size_t core = pending.request.core;
    const std::uint64_t block = pending.block;
    const bool write = pending.request.operation == Operation::Write;

    if (pending.hit) {
        CacheLine* line = findLine(l1Caches_[core], block);
        if (line == nullptr) {
            throw std::logic_error("L1 hit line disappeared before its coherence event");
        }
        if (write && line->state == MesiState::Shared) {
            invalidateL1Copies(block, core);
            line->state = MesiState::Modified;
            line->dirty = true;
            ++stats_.cores[core].upgrades;
        } else if (write && line->state == MesiState::Exclusive) {
            line->state = MesiState::Modified;
            line->dirty = true;
        }
        line->lastUsed = ++useClock_;
        checkInvariants();
        return;
    }

    bool peerCopy = false;
    CacheLine* l2Line = findLine(l2Cache_, block);
    if (l2Line == nullptr) {
        throw std::logic_error("L1 fill is missing from inclusive L2");
    }
    for (std::size_t other = 0; other < l1Caches_.size(); ++other) {
        if (other == core) continue;
        if (CacheLine* peer = findLine(l1Caches_[other], block)) {
            peerCopy = true;
            if (peer->state == MesiState::Modified) {
                pending.data = peer->data;
                l2Line->data = peer->data;
                l2Line->dirty = true;
                ++stats_.interventions;
                ++stats_.cacheToCacheTransfers;
                peer->state = write ? MesiState::Invalid : MesiState::Shared;
                peer->dirty = false;
                if (write) {
                    ++stats_.cores[other].invalidations;
                    ++stats_.invalidations;
                }
            } else if (peer->state == MesiState::Exclusive) {
                peer->state = write ? MesiState::Invalid : MesiState::Shared;
                if (write) {
                    ++stats_.cores[other].invalidations;
                    ++stats_.invalidations;
                }
            } else if (write && peer->state == MesiState::Shared) {
                peer->state = MesiState::Invalid;
                peer->dirty = false;
                ++stats_.cores[other].invalidations;
                ++stats_.invalidations;
            }
        }
    }

    if (write) {
        CacheLine& line = insertLine(l1Caches_[core], block, core);
        line.data = pending.data;
        line.state = MesiState::Modified;
        line.dirty = true;
    } else {
        CacheLine& line = insertLine(l1Caches_[core], block, core);
        line.data = pending.hasModifiedPeer ? pending.data : l2Line->data;
        line.state = peerCopy ? MesiState::Shared : MesiState::Exclusive;
        line.dirty = false;
        pending.data = line.data;
    }
    l2Line->lastUsed = ++useClock_;
    checkInvariants();
    (void)cycle;
}

void Simulator::completeRequest(std::uint64_t requestId, std::uint64_t cycle) {
    PendingRequest& pending = requests_.at(static_cast<std::size_t>(requestId));
    const std::size_t core = pending.request.core;
    CacheLine* line = findLine(l1Caches_[core], pending.block);

    if (pending.request.operation == Operation::Write) {
        if (line == nullptr || line->state != MesiState::Modified) {
            throw std::logic_error("write completed without modified ownership");
        }
        line->data = pending.request.value;
        line->dirty = true;
        pending.result.value = pending.request.value;
        pending.result.state = line->state;
    } else {
        if (line == nullptr) {
            throw std::logic_error("read completed without a valid L1 copy");
        }
        pending.result.value = line->data;
        pending.result.state = line->state;
    }

    line->lastUsed = ++useClock_;
    pending.result.hit = pending.hit;
    pending.result.completionCycle = cycle;
    pending.result.latency = cycle - pending.request.issueCycle;
    stats_.totalCycles = std::max(stats_.totalCycles, cycle);
    checkInvariants();

    auto& coreQueue = corePendingQueues_[core];
    if (coreQueue.empty() || coreQueue.front() != requestId) {
        throw std::logic_error("completed request was not at the head of its core queue");
    }
    coreQueue.pop_front();
    auto& blockQueue = blockPendingQueues_[pending.block];
    if (blockQueue.empty() || blockQueue.front() != requestId) {
        throw std::logic_error("completed request was not at the head of its block queue");
    }
    blockQueue.pop_front();
    coreAvailableCycles_[core] = cycle;
    if (!coreQueue.empty()) {
        const std::uint64_t nextRequestId = coreQueue.front();
        scheduleEligible(nextRequestId, cycle);
    }
    if (!blockQueue.empty()) {
        const std::uint64_t nextRequestId = blockQueue.front();
        scheduleEligible(nextRequestId, cycle);
    }
}

std::vector<AccessResult> Simulator::run() {
    std::vector<AccessResult> completed;
    while (!events_.empty()) {
        const Event event = events_.top();
        events_.pop();
        if (event.kind == EventKind::Start) {
            std::vector<std::uint64_t> sameCycleStarts{event.requestId};
            while (!events_.empty() && events_.top().cycle == event.cycle
                   && events_.top().kind == EventKind::Start) {
                sameCycleStarts.push_back(events_.top().requestId);
                events_.pop();
            }
            const std::size_t arbitrationStart = busArbiterPointer_;
            std::sort(sameCycleStarts.begin(), sameCycleStarts.end(),
                [this, arbitrationStart](std::uint64_t left, std::uint64_t right) {
                    const std::size_t leftCore = requests_[static_cast<std::size_t>(left)].request.core;
                    const std::size_t rightCore = requests_[static_cast<std::size_t>(right)].request.core;
                    const std::size_t leftDistance = (leftCore + config_.cores - arbitrationStart) % config_.cores;
                    const std::size_t rightDistance = (rightCore + config_.cores - arbitrationStart) % config_.cores;
                    return leftDistance == rightDistance ? left < right : leftDistance < rightDistance;
                });
            for (const std::uint64_t requestId : sameCycleStarts) {
                    requests_[static_cast<std::size_t>(requestId)].startScheduled = false;
                    startRequest(requestId, event.cycle);
                }
            continue;
        }
        switch (event.kind) {
        case EventKind::Start:
            break;
        case EventKind::BusGrant:
            grantBus(event.requestId, event.cycle);
            break;
        case EventKind::Complete:
            completeRequest(event.requestId, event.cycle);
            completed.push_back(requests_.at(static_cast<std::size_t>(event.requestId)).result);
            break;
        }
    }
    return completed;
}

AccessResult Simulator::access(std::size_t core, Operation operation, std::uint64_t address,
                               std::uint64_t value) {
    if (nextIssueCycle_ == std::numeric_limits<std::uint64_t>::max()) {
        throw std::overflow_error("trace issue cycle overflow");
    }
    const std::uint64_t requestId = submit(CacheRequest{core, operation, address, value, nextIssueCycle_});
    ++nextIssueCycle_;
    const auto completed = run();
    const auto found = std::find_if(completed.begin(), completed.end(), [requestId](const AccessResult& result) {
        return result.requestId == requestId;
    });
    if (found == completed.end()) {
        throw std::logic_error("synchronous access did not complete");
    }
    return *found;
}

MesiState Simulator::stateOf(std::size_t core, std::uint64_t address) const {
    if (core >= config_.cores) {
        throw std::out_of_range("core index is outside the configured range");
    }
    const std::uint64_t block = address / config_.blockSize;
    const CacheLine* line = findLine(l1Caches_[core], block);
    return line == nullptr ? MesiState::Invalid : line->state;
}

std::uint64_t Simulator::dataOf(std::size_t core, std::uint64_t address) const {
    if (core >= config_.cores) {
        throw std::out_of_range("core index is outside the configured range");
    }
    const std::uint64_t block = address / config_.blockSize;
    const CacheLine* line = findLine(l1Caches_[core], block);
    if (line == nullptr || line->state == MesiState::Invalid) {
        throw std::out_of_range("requested cache line is not present in the selected L1");
    }
    return line->data;
}

std::uint64_t Simulator::memoryValue(std::uint64_t address) const noexcept {
    const std::uint64_t block = address / config_.blockSize;
    const auto found = memory_.find(block);
    return found == memory_.end() ? 0 : found->second;
}

const SimulationStats& Simulator::stats() const noexcept {
    return stats_;
}

const CacheConfig& Simulator::config() const noexcept {
    return config_;
}

bool Simulator::validateInvariants(std::string* reason) const {
    for (std::size_t set = 0; set < l2Cache_.sets.size(); ++set) {
        for (const CacheLine& l2Line : l2Cache_.sets[set]) {
            if (l2Line.state == MesiState::Invalid) continue;
            std::size_t validCopies = 0;
            std::size_t modifiedCopies = 0;
            std::size_t exclusiveCopies = 0;
            bool haveCopyData = false;
            std::uint64_t sharedData = 0;
            for (std::size_t core = 0; core < l1Caches_.size(); ++core) {
                const CacheLine* l1Line = findLine(l1Caches_[core], l2Line.block);
                if (l1Line == nullptr) continue;
                ++validCopies;
                if (haveCopyData && l1Line->data != sharedData) {
                    if (reason != nullptr) *reason = "cache copies disagree on data for block "
                        + std::to_string(l2Line.block);
                    return false;
                }
                sharedData = l1Line->data;
                haveCopyData = true;
                if (l1Line->state == MesiState::Modified) ++modifiedCopies;
                if (l1Line->state == MesiState::Exclusive) ++exclusiveCopies;
            }
            if (modifiedCopies > 1 || (modifiedCopies != 0 && validCopies != 1)
                || exclusiveCopies > 1 || (exclusiveCopies != 0 && validCopies != 1)) {
                if (reason != nullptr) *reason = "MESI ownership invariant violated for block "
                    + std::to_string(l2Line.block);
                return false;
            }
        }
    }
    for (std::size_t core = 0; core < l1Caches_.size(); ++core) {
        for (std::size_t setIndexValue = 0; setIndexValue < l1Caches_[core].sets.size(); ++setIndexValue) {
            const auto& set = l1Caches_[core].sets[setIndexValue];
            for (std::size_t way = 0; way < set.size(); ++way) {
                const CacheLine& l1Line = set[way];
                if (l1Line.state != MesiState::Invalid && findLine(l2Cache_, l1Line.block) == nullptr) {
                    if (reason != nullptr) *reason = "inclusive L2 invariant violated for block "
                        + std::to_string(l1Line.block);
                    return false;
                }
                for (std::size_t otherWay = way + 1; otherWay < set.size(); ++otherWay) {
                    if (l1Line.state != MesiState::Invalid
                        && set[otherWay].state != MesiState::Invalid
                        && l1Line.block == set[otherWay].block) {
                        if (reason != nullptr) *reason = "duplicate valid L1 tag for block "
                            + std::to_string(l1Line.block);
                        return false;
                    }
                }
            }
        }
    }
    if (reason != nullptr) reason->clear();
    return true;
}

void Simulator::checkInvariants() const {
    std::string reason;
    if (!validateInvariants(&reason)) {
        throw std::logic_error(reason);
    }
}

std::string toString(MesiState state) {
    switch (state) {
    case MesiState::Invalid: return "I";
    case MesiState::Shared: return "S";
    case MesiState::Exclusive: return "E";
    case MesiState::Modified: return "M";
    }
    throw std::invalid_argument("unknown MESI state");
}

std::string toString(Operation operation) {
    switch (operation) {
    case Operation::Read: return "R";
    case Operation::Write: return "W";
    }
    throw std::invalid_argument("unknown memory operation");
}

} // namespace cache_sim
