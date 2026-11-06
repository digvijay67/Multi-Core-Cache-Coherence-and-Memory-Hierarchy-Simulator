#include "cache_simulator.hpp"

#include <algorithm>
#include <iostream>
#include <random>
#include <stdexcept>
#include <string>
#include <unordered_map>
#include <vector>

using cache_sim::CacheConfig;
using cache_sim::CacheRequest;
using cache_sim::MesiState;
using cache_sim::Operation;
using cache_sim::Simulator;

namespace {

void require(bool condition, const std::string& message) {
    if (!condition) {
        throw std::runtime_error(message);
    }
}

CacheConfig smallConfig() {
    CacheConfig config;
    config.cores = 2;
    config.l1Sets = 2;
    config.l1Ways = 2;
    config.l2Sets = 4;
    config.l2Ways = 2;
    config.blockSize = 64;
    return config;
}

void testMesiTransitionsAndInvariants() {
    Simulator simulator(smallConfig());

    auto result = simulator.access(0, Operation::Read, 0x100);
    require(!result.hit && result.state == MesiState::Exclusive, "cold read must enter E");

    result = simulator.access(1, Operation::Read, 0x100);
    require(!result.hit && result.state == MesiState::Shared, "second reader must enter S");
    require(simulator.stateOf(0, 0x100) == MesiState::Shared, "E peer must downgrade to S");

    result = simulator.access(0, Operation::Write, 0x100, 0xABCD);
    require(result.hit && result.state == MesiState::Modified, "S write must upgrade to M");
    require(simulator.stateOf(1, 0x100) == MesiState::Invalid, "S copies must be invalidated");
    require(simulator.stats().cores[0].upgrades == 1, "upgrade counter must increment once");

    result = simulator.access(1, Operation::Read, 0x100);
    require(!result.hit && result.state == MesiState::Shared, "read of M line must obtain S");
    require(result.value == 0xABCD, "intervention must return latest modified data");
    require(simulator.stateOf(0, 0x100) == MesiState::Shared, "M owner must downgrade to S");
    require(simulator.stats().interventions == 1, "M read must count an intervention");
    require(simulator.stats().cacheToCacheTransfers == 1, "M read must count a cache transfer");

    result = simulator.access(1, Operation::Write, 0x100, 0x1234);
    require(result.state == MesiState::Modified, "S writer must become M");
    require(simulator.stateOf(0, 0x100) == MesiState::Invalid, "upgrade must invalidate peer");
    require(simulator.dataOf(1, 0x100) == 0x1234, "write must update line payload");

    std::string reason;
    require(simulator.validateInvariants(&reason), "MESI/inclusion invariant failed: " + reason);
}

void testMemoryValueSurvivesDirtyL1Eviction() {
    CacheConfig config = smallConfig();
    config.cores = 1;
    config.l1Sets = 1;
    config.l1Ways = 1;
    config.l2Sets = 2;
    config.l2Ways = 2;
    Simulator simulator(config);

    simulator.access(0, Operation::Write, 0, 0xCAFE);
    simulator.access(0, Operation::Read, 64);
    require(simulator.stats().cores[0].writebacks == 1, "M eviction must write back to L2");
    const auto reloaded = simulator.access(0, Operation::Read, 0);
    require(reloaded.value == 0xCAFE, "reloaded line must preserve dirty data");
}

void testMemoryValueSurvivesDirtyInclusiveL2Eviction() {
    CacheConfig config = smallConfig();
    config.cores = 1;
    config.l1Sets = 4;
    config.l1Ways = 2;
    config.l2Sets = 1;
    config.l2Ways = 1;
    config.l1Latency = 2;
    config.l2Latency = 3;
    config.memoryLatency = 7;
    config.coherenceLatency = 4;
    Simulator simulator(config);

    const auto writeId = simulator.submit(CacheRequest{0, Operation::Write, 0, 0xDEADBEEF, 0});
    const auto evictionId = simulator.submit(CacheRequest{0, Operation::Read, 64, 0, 16});
    const auto reloadId = simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 39});
    const auto completed = simulator.run();
    const auto findResult = [&completed](std::uint64_t id) {
        return std::find_if(completed.begin(), completed.end(),
            [id](const auto& result) { return result.requestId == id; });
    };
    const auto write = findResult(writeId);
    const auto eviction = findResult(evictionId);
    const auto reload = findResult(reloadId);
    require(write != completed.end() && eviction != completed.end() && reload != completed.end(),
            "dirty eviction and reload requests must complete");
    require(eviction->latency == 23, "dirty inclusive eviction must charge L2 lookup, fill, and writeback");
    require(reload->value == 0xDEADBEEF, "memory must retain data after dirty L2 eviction");
    require(simulator.memoryValue(0) == 0xDEADBEEF,
            "backing memory must contain the dirty line after L2 eviction");
    require(simulator.stats().invalidations >= 1, "inclusive L2 eviction must invalidate the L1 copy");
    require(simulator.stats().memoryWritebacks == 1, "dirty L2 eviction must write back to memory");
}

void testExactL1L2MemoryAndTransferTiming() {
    CacheConfig config = smallConfig();
    config.cores = 2;
    config.l1Sets = 1;
    config.l1Ways = 1;
    config.l2Sets = 4;
    config.l2Ways = 2;
    config.l1Latency = 2;
    config.l2Latency = 3;
    config.memoryLatency = 7;
    config.coherenceLatency = 4;
    config.cacheTransferLatency = 5;

    Simulator simulator(config);
    const auto first = simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 0});
    const auto l1Hit = simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 16});
    const auto conflict = simulator.submit(CacheRequest{0, Operation::Read, 64, 0, 18});
    const auto l2Hit = simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 34});
    const auto completed = simulator.run();
    const auto resultFor = [&completed](std::uint64_t id) -> const cache_sim::AccessResult& {
        const auto found = std::find_if(completed.begin(), completed.end(),
            [id](const auto& result) { return result.requestId == id; });
        if (found == completed.end()) throw std::runtime_error("expected request did not complete");
        return *found;
    };

    require(resultFor(first).latency == 16, "cold miss must include L1, bus, L2, and memory");
    require(resultFor(l1Hit).latency == 2, "L1 hit must charge only L1 lookup latency");
    require(resultFor(conflict).latency == 16, "second cold miss must use memory latency");
    require(resultFor(l2Hit).latency == 9, "L2 hit must include L1, bus, and L2 latency");

    Simulator transferSimulator(config);
    const auto write = transferSimulator.submit(CacheRequest{0, Operation::Write, 0, 0x55, 0});
    const auto remoteRead = transferSimulator.submit(CacheRequest{1, Operation::Read, 0, 0, 16});
    const auto transferResults = transferSimulator.run();
    const auto writeResult = std::find_if(transferResults.begin(), transferResults.end(),
        [write](const auto& result) { return result.requestId == write; });
    const auto readResult = std::find_if(transferResults.begin(), transferResults.end(),
        [remoteRead](const auto& result) { return result.requestId == remoteRead; });
    require(writeResult != transferResults.end() && readResult != transferResults.end(),
            "write and cache-to-cache read must complete");
    require(readResult->value == 0x55, "cache-to-cache response must carry latest data");
    require(readResult->latency == 14, "M intervention must charge cache-to-cache latency");
}

void testEventQueueArbitrationAndOverlap() {
    CacheConfig config = smallConfig();
    config.l1Sets = 2;
    config.l1Ways = 1;
    config.l2Sets = 4;
    config.l2Ways = 1;
    config.l1Latency = 1;
    config.l2Latency = 2;
    config.memoryLatency = 10;
    config.coherenceLatency = 3;
    config.cacheTransferLatency = 4;
    Simulator simulator(config);

    const auto first = simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 0});
    const auto second = simulator.submit(CacheRequest{1, Operation::Read, 64, 0, 0});
    const auto completed = simulator.run();
    require(completed.size() == 2, "both concurrently issued requests must complete");
    require(completed[0].requestId == first && completed[1].requestId == second,
            "same-cycle bus grants must be deterministic and fair by arrival order");
    require(completed[0].completionCycle == 16, "cold miss timing must include L2 lookup and memory");
    require(completed[1].completionCycle == 19, "second miss must wait for bus arbitration");
    require(simulator.stats().busWaitCycles == 3, "bus wait must count the second request's wait");
    require(simulator.stats().totalCycles == 19, "completion time must be the latest event");
}

void testRoundRobinTieBreakAfterPreviousGrant() {
    CacheConfig config = smallConfig();
    config.l1Latency = 1;
    config.l2Latency = 1;
    config.memoryLatency = 1;
    config.coherenceLatency = 4;
    Simulator simulator(config);

    simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 0});
    simulator.run();

    const auto core0 = simulator.submit(CacheRequest{0, Operation::Read, 64, 0, 20});
    const auto core1 = simulator.submit(CacheRequest{1, Operation::Read, 128, 0, 20});
    const auto completed = simulator.run();
    const auto resultFor = [&completed](std::uint64_t id) {
        return std::find_if(completed.begin(), completed.end(),
            [id](const auto& result) { return result.requestId == id; });
    };
    const auto core0Result = resultFor(core0);
    const auto core1Result = resultFor(core1);
    require(core0Result != completed.end() && core1Result != completed.end(),
            "both round-robin contenders must complete");
    require(core1Result->completionCycle < core0Result->completionCycle,
            "after core 0 wins, simultaneous contention must rotate priority to core 1");
}

void testSameLineRequestsSerializeAndForwardData() {
    CacheConfig config = smallConfig();
    config.l1Latency = 1;
    config.l2Latency = 2;
    config.memoryLatency = 10;
    config.coherenceLatency = 3;
    config.cacheTransferLatency = 4;
    Simulator simulator(config);

    simulator.submit(CacheRequest{0, Operation::Write, 0, 0x77, 0});
    simulator.submit(CacheRequest{1, Operation::Read, 0, 0, 1});
    const auto completed = simulator.run();
    require(completed.size() == 2, "both same-line requests must complete");
    const auto& read = completed[1];
    require(read.operation == Operation::Read && read.value == 0x77,
            "later reader must observe the completed write");
    require(read.state == MesiState::Shared, "reader and former M owner must be S");
    require(simulator.stateOf(0, 0) == MesiState::Shared, "writer must downgrade after BusRd");
}

void testPerCoreIssueOrderWhenEarlierRequestStalls() {
    CacheConfig config = smallConfig();
    config.l1Latency = 1;
    config.l2Latency = 2;
    config.memoryLatency = 10;
    config.coherenceLatency = 3;
    Simulator simulator(config);

    simulator.submit(CacheRequest{0, Operation::Read, 0, 0, 0});
    const auto firstCore1Request = simulator.submit(CacheRequest{1, Operation::Read, 0, 0, 1});
    const auto secondCore1Request = simulator.submit(CacheRequest{1, Operation::Write, 64, 0x99, 2});
    const auto completed = simulator.run();

    const auto first = std::find_if(completed.begin(), completed.end(),
        [firstCore1Request](const auto& result) { return result.requestId == firstCore1Request; });
    const auto second = std::find_if(completed.begin(), completed.end(),
        [secondCore1Request](const auto& result) { return result.requestId == secondCore1Request; });
    require(first != completed.end() && second != completed.end(), "both queued core requests must complete");
    require(first->completionCycle < second->completionCycle,
            "a later same-core request must not bypass a stalled earlier request");
    require(simulator.dataOf(1, 64) == 0x99, "later queued write must commit its data");
}

void testConfigurationValidation() {
    CacheConfig config = smallConfig();
    config.l1Ways = 0;
    bool threw = false;
    try {
        Simulator simulator(config);
    } catch (const std::invalid_argument&) {
        threw = true;
    }
    require(threw, "invalid cache configuration must be rejected");
}

void testDeterministicRandomTraceAgainstMemoryScoreboard() {
    CacheConfig config = smallConfig();
    config.cores = 4;
    config.l1Sets = 2;
    config.l1Ways = 2;
    config.l2Sets = 4;
    config.l2Ways = 2;
    config.l1Latency = 1;
    config.l2Latency = 2;
    config.memoryLatency = 5;
    config.coherenceLatency = 2;
    config.cacheTransferLatency = 3;
    Simulator simulator(config);

    std::mt19937_64 random(0x4D455349);
    std::vector<CacheRequest> requests;
    requests.reserve(500);
    for (std::uint64_t issue = 0; issue < 500; ++issue) {
        const auto core = static_cast<std::size_t>(random() % config.cores);
        const std::uint64_t block = random() % 16;
        const bool write = (random() % 3) == 0;
        requests.push_back(CacheRequest{
            core,
            write ? Operation::Write : Operation::Read,
            block * config.blockSize,
            write ? random() : 0,
            issue
        });
        simulator.submit(requests.back());
    }

    auto completed = simulator.run();
    require(completed.size() == requests.size(), "random trace must complete every request");
    std::vector<cache_sim::AccessResult> resultById(requests.size());
    for (const auto& result : completed) {
        resultById.at(static_cast<std::size_t>(result.requestId)) = result;
    }

    std::unordered_map<std::uint64_t, std::uint64_t> referenceMemory;
    for (std::size_t index = 0; index < requests.size(); ++index) {
        const CacheRequest& request = requests[index];
        const std::uint64_t block = request.address / config.blockSize;
        if (request.operation == Operation::Write) {
            referenceMemory[block] = request.value;
        } else {
            const auto expected = referenceMemory.find(block);
            const std::uint64_t expectedValue = expected == referenceMemory.end() ? 0 : expected->second;
            require(resultById[index].value == expectedValue,
                    "random trace read differs from the backing-memory reference scoreboard");
        }
    }

    std::string reason;
    require(simulator.validateInvariants(&reason), "random trace violated invariant: " + reason);
}

} // namespace

int main() {
    try {
        testMesiTransitionsAndInvariants();
        testMemoryValueSurvivesDirtyL1Eviction();
        testMemoryValueSurvivesDirtyInclusiveL2Eviction();
        testExactL1L2MemoryAndTransferTiming();
        testEventQueueArbitrationAndOverlap();
        testRoundRobinTieBreakAfterPreviousGrant();
        testSameLineRequestsSerializeAndForwardData();
        testPerCoreIssueOrderWhenEarlierRequestStalls();
        testConfigurationValidation();
        testDeterministicRandomTraceAgainstMemoryScoreboard();
        std::cout << "All cache simulator tests passed.\n";
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Test failure: " << error.what() << '\n';
        return 1;
    }
}
