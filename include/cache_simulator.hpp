#pragma once

#include <cstddef>
#include <cstdint>
#include <deque>
#include <queue>
#include <string>
#include <unordered_map>
#include <vector>

namespace cache_sim {

enum class Operation {
    Read,
    Write
};

enum class MesiState {
    Invalid,
    Shared,
    Exclusive,
    Modified
};

struct CacheConfig {
    std::size_t cores = 4;
    std::size_t l1Sets = 64;
    std::size_t l1Ways = 4;
    std::size_t l2Sets = 256;
    std::size_t l2Ways = 8;
    std::size_t blockSize = 64;
    std::uint64_t l1Latency = 1;
    std::uint64_t l2Latency = 10;
    std::uint64_t memoryLatency = 100;
    std::uint64_t coherenceLatency = 5;
    std::uint64_t cacheTransferLatency = 5;

    void validate() const;
};

struct CoreStats {
    std::uint64_t accesses = 0;
    std::uint64_t hits = 0;
    std::uint64_t misses = 0;
    std::uint64_t upgrades = 0;
    std::uint64_t invalidations = 0;
    std::uint64_t writebacks = 0;
};

struct SimulationStats {
    std::vector<CoreStats> cores;
    std::uint64_t l2Accesses = 0;
    std::uint64_t l2Hits = 0;
    std::uint64_t l2Misses = 0;
    std::uint64_t memoryReads = 0;
    std::uint64_t memoryWritebacks = 0;
    std::uint64_t coherenceTransactions = 0;
    std::uint64_t interventions = 0;
    std::uint64_t cacheToCacheTransfers = 0;
    std::uint64_t invalidations = 0;
    std::uint64_t busWaitCycles = 0;
    std::uint64_t totalCycles = 0;
};

struct CacheRequest {
    std::size_t core = 0;
    Operation operation = Operation::Read;
    std::uint64_t address = 0;
    std::uint64_t value = 0;
    std::uint64_t issueCycle = 0;
};

struct AccessResult {
    std::uint64_t requestId = 0;
    std::size_t core = 0;
    Operation operation = Operation::Read;
    std::uint64_t address = 0;
    std::uint64_t value = 0;
    bool hit = false;
    MesiState state = MesiState::Invalid;
    std::uint64_t issueCycle = 0;
    std::uint64_t completionCycle = 0;
    std::uint64_t latency = 0;
};

class Simulator {
public:
    explicit Simulator(CacheConfig config);

    std::uint64_t submit(CacheRequest request);
    std::vector<AccessResult> run();
    AccessResult access(std::size_t core, Operation operation, std::uint64_t address,
                        std::uint64_t value = 0);
    MesiState stateOf(std::size_t core, std::uint64_t address) const;
    std::uint64_t dataOf(std::size_t core, std::uint64_t address) const;
    std::uint64_t memoryValue(std::uint64_t address) const noexcept;
    const SimulationStats& stats() const noexcept;
    const CacheConfig& config() const noexcept;
    bool validateInvariants(std::string* reason = nullptr) const;

private:
    struct CacheLine {
        std::uint64_t block = 0;
        std::uint64_t lastUsed = 0;
        std::uint64_t data = 0;
        MesiState state = MesiState::Invalid;
        bool dirty = false;
    };

    struct Cache {
        std::vector<std::vector<CacheLine>> sets;
    };

    enum class EventKind {
        BusGrant,
        Complete,
        Start
    };

    struct Event {
        std::uint64_t cycle = 0;
        std::uint64_t sequence = 0;
        std::uint64_t requestId = 0;
        EventKind kind = EventKind::Start;
    };

    struct EventLater {
        bool operator()(const Event& left, const Event& right) const noexcept;
    };

    struct PendingRequest {
        CacheRequest request;
        AccessResult result;
        std::uint64_t block = 0;
        std::uint64_t finishCycle = 0;
        std::uint64_t busGrantCycle = 0;
        std::uint64_t data = 0;
        std::uint64_t l2DataLatency = 0;
        bool hit = false;
        bool hasModifiedPeer = false;
        bool startScheduled = false;
    };

    CacheConfig config_;
    SimulationStats stats_;
    std::vector<Cache> l1Caches_;
    Cache l2Cache_;
    std::unordered_map<std::uint64_t, std::uint64_t> memory_;
    std::vector<PendingRequest> requests_;
    std::priority_queue<Event, std::vector<Event>, EventLater> events_;
    std::vector<std::uint64_t> coreAvailableCycles_;
    std::vector<std::deque<std::uint64_t>> corePendingQueues_;
    std::unordered_map<std::uint64_t, std::deque<std::uint64_t>> blockPendingQueues_;
    std::unordered_map<std::uint64_t, std::uint64_t> blockAvailableCycles_;
    std::uint64_t useClock_ = 0;
    std::uint64_t busAvailableCycle_ = 0;
    std::size_t busArbiterPointer_ = 0;
    std::uint64_t eventSequence_ = 0;
    std::uint64_t nextIssueCycle_ = 0;

    CacheLine* findLine(Cache& cache, std::uint64_t block);
    const CacheLine* findLine(const Cache& cache, std::uint64_t block) const;
    CacheLine& insertLine(Cache& cache, std::uint64_t block, std::size_t core);
    std::uint64_t insertL2Line(std::uint64_t block);
    std::uint64_t accessL2(std::uint64_t block);
    std::uint64_t addCycles(std::uint64_t cycle, std::uint64_t duration) const;
    std::uint64_t addLatency(std::uint64_t base, std::uint64_t extra) const;
    void schedule(std::uint64_t cycle, std::uint64_t requestId, EventKind kind);
    void startRequest(std::uint64_t requestId, std::uint64_t cycle);
    void scheduleEligible(std::uint64_t requestId, std::uint64_t cycle);
    void grantBus(std::uint64_t requestId, std::uint64_t cycle);
    void completeRequest(std::uint64_t requestId, std::uint64_t cycle);
    void invalidateL1Copies(std::uint64_t block, std::size_t exceptCore);
    void checkInvariants() const;
};

std::string toString(MesiState state);
std::string toString(Operation operation);

} // namespace cache_sim
