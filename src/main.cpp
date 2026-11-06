#include "cache_simulator.hpp"

#include <algorithm>
#include <cctype>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

namespace {

using cache_sim::CacheConfig;
using cache_sim::Operation;
using cache_sim::Simulator;

void printUsage(std::ostream& output) {
    output << "Multi-Core Cache Coherence and Memory Hierarchy Simulator\n"
           << "Usage: cache_sim [options] [--trace FILE]\n\n"
           << "Trace input is read from stdin when --trace is omitted. Each line is:\n"
           << "  R <core> <address>    read a byte address\n"
           << "  W <core> <address>    write a byte address\n"
           << "Lines may contain # comments. Addresses accept decimal or 0x-prefixed hex.\n\n"
           << "Options:\n"
           << "  --cores N             Number of processor cores (default 4)\n"
           << "  --l1-sets N           Number of sets in each private L1 (default 64)\n"
           << "  --l1-ways N           Associativity of each private L1 (default 4)\n"
           << "  --l2-sets N           Number of sets in shared L2 (default 256)\n"
           << "  --l2-ways N           Associativity of shared L2 (default 8)\n"
           << "  --block-size N        Cache-line size in bytes (default 64)\n"
           << "  --l1-latency N        L1 hit latency in cycles (default 1)\n"
           << "  --l2-latency N        L2 hit latency in cycles (default 10)\n"
           << "  --memory-latency N    Memory access latency in cycles (default 100)\n"
           << "  --coherence-latency N Bus transaction latency in cycles (default 5)\n"
           << "  --cache-transfer-latency N Cache-to-cache data transfer latency (default 5)\n"
           << "  --help                Show this help\n";
}

std::uint64_t parseUnsigned(const std::string& value, const std::string& option) {
    if (value.empty() || value.front() == '-') {
        throw std::invalid_argument(option + " requires a non-negative integer");
    }
    std::size_t parsed = 0;
    const unsigned long long number = std::stoull(value, &parsed, 0);
    if (parsed != value.size()) {
        throw std::invalid_argument("invalid value for " + option + ": " + value);
    }
    return static_cast<std::uint64_t>(number);
}

std::size_t parseSize(const std::string& value, const std::string& option) {
    const std::uint64_t number = parseUnsigned(value, option);
    if (number > std::numeric_limits<std::size_t>::max()) {
        throw std::invalid_argument(option + " is too large");
    }
    return static_cast<std::size_t>(number);
}

void applyOption(CacheConfig& config, const std::string& option, const std::string& value) {
    if (option == "--cores") config.cores = parseSize(value, option);
    else if (option == "--l1-sets") config.l1Sets = parseSize(value, option);
    else if (option == "--l1-ways") config.l1Ways = parseSize(value, option);
    else if (option == "--l2-sets") config.l2Sets = parseSize(value, option);
    else if (option == "--l2-ways") config.l2Ways = parseSize(value, option);
    else if (option == "--block-size") config.blockSize = parseSize(value, option);
    else if (option == "--l1-latency") config.l1Latency = parseUnsigned(value, option);
    else if (option == "--l2-latency") config.l2Latency = parseUnsigned(value, option);
    else if (option == "--memory-latency") config.memoryLatency = parseUnsigned(value, option);
    else if (option == "--coherence-latency") config.coherenceLatency = parseUnsigned(value, option);
    else if (option == "--cache-transfer-latency") config.cacheTransferLatency = parseUnsigned(value, option);
    else throw std::invalid_argument("unknown option: " + option);
}

std::string uppercase(std::string text) {
    std::transform(text.begin(), text.end(), text.begin(), [](unsigned char ch) {
        return static_cast<char>(std::toupper(ch));
    });
    return text;
}

void printSummary(const Simulator& simulator) {
    const auto& stats = simulator.stats();
    std::cout << "\n=== Simulation Summary ===\n";
    std::cout << std::left << std::setw(8) << "Core"
              << std::right << std::setw(12) << "Accesses"
              << std::setw(10) << "Hits"
              << std::setw(10) << "Misses"
              << std::setw(12) << "Hit rate"
              << std::setw(11) << "Upgrades"
              << std::setw(14) << "Invalidations" << '\n';
    for (std::size_t core = 0; core < stats.cores.size(); ++core) {
        const auto& item = stats.cores[core];
        const double hitRate = item.accesses == 0
            ? 0.0
            : 100.0 * static_cast<double>(item.hits) / static_cast<double>(item.accesses);
        std::cout << std::left << std::setw(8) << core
                  << std::right << std::setw(12) << item.accesses
                  << std::setw(10) << item.hits
                  << std::setw(10) << item.misses
                  << std::setw(11) << std::fixed << std::setprecision(2) << hitRate << "%"
                  << std::setw(11) << item.upgrades
                  << std::setw(14) << item.invalidations << '\n';
    }

    std::uint64_t totalAccesses = 0;
    std::uint64_t totalHits = 0;
    std::uint64_t totalMisses = 0;
    for (const auto& core : stats.cores) {
        totalAccesses += core.accesses;
        totalHits += core.hits;
        totalMisses += core.misses;
    }
    const double overallHitRate = totalAccesses == 0
        ? 0.0
        : 100.0 * static_cast<double>(totalHits) / static_cast<double>(totalAccesses);
    const double overallMissRate = totalAccesses == 0
        ? 0.0
        : 100.0 * static_cast<double>(totalMisses) / static_cast<double>(totalAccesses);
    const double l2HitRate = stats.l2Accesses == 0
        ? 0.0
        : 100.0 * static_cast<double>(stats.l2Hits) / static_cast<double>(stats.l2Accesses);

    std::cout << "\nL1 accesses: " << totalAccesses
              << " | hits: " << totalHits
              << " | misses: " << totalMisses
              << " | hit rate: " << std::fixed << std::setprecision(2) << overallHitRate << "%"
              << " | miss rate: " << overallMissRate << "%\n"
              << "L2 accesses: " << stats.l2Accesses
              << " | hits: " << stats.l2Hits
              << " | misses: " << stats.l2Misses
              << " | hit rate: " << l2HitRate << "%\n"
              << "Memory reads: " << stats.memoryReads
              << " | memory writebacks: " << stats.memoryWritebacks
              << " | L1 writebacks: ";
    std::uint64_t writebacks = 0;
    for (const auto& core : stats.cores) writebacks += core.writebacks;
    std::cout << writebacks
              << "\nCoherence transactions: " << stats.coherenceTransactions
              << " | interventions: " << stats.interventions
              << " | cache-to-cache transfers: " << stats.cacheToCacheTransfers
              << " | invalidations: " << stats.invalidations
              << " | bus wait cycles: " << stats.busWaitCycles
              << "\nSimulated completion time: " << stats.totalCycles << " cycles\n";
}

} // namespace

int main(int argc, char* argv[]) {
    try {
        CacheConfig config;
        std::string tracePath;
        for (int index = 1; index < argc; ++index) {
            const std::string option = argv[index];
            if (option == "--help" || option == "-h") {
                printUsage(std::cout);
                return 0;
            }
            if (option == "--trace") {
                if (++index >= argc) {
                    throw std::invalid_argument("--trace requires a file path");
                }
                tracePath = argv[index];
            } else {
                if (++index >= argc) {
                    throw std::invalid_argument(option + " requires a value");
                }
                applyOption(config, option, argv[index]);
            }
        }
        config.validate();

        std::unique_ptr<std::istream> fileInput;
        std::istream* input = &std::cin;
        if (!tracePath.empty()) {
            auto file = std::make_unique<std::ifstream>(tracePath);
            if (!*file) {
                throw std::runtime_error("could not open trace file: " + tracePath);
            }
            input = file.get();
            fileInput = std::move(file);
        }

        Simulator simulator(config);
        std::string line;
        std::uint64_t issueCycle = 0;
        std::vector<std::uint64_t> traceBlocks;
        std::size_t lineNumber = 0;
        while (std::getline(*input, line)) {
            ++lineNumber;
            const std::size_t comment = line.find('#');
            if (comment != std::string::npos) line.erase(comment);
            std::istringstream parser(line);
            std::string operationText;
            std::string coreText;
            std::string addressText;
            std::string valueText;
            std::string extra;
            if (!(parser >> operationText)) continue;
            if (!(parser >> coreText >> addressText)) {
                throw std::runtime_error("line " + std::to_string(lineNumber)
                                         + ": expected: R|W <core> <address> [write-value]");
            }

            const std::string normalizedOperation = uppercase(operationText);
            Operation operation;
            if (normalizedOperation == "R" || normalizedOperation == "READ") {
                operation = Operation::Read;
            } else if (normalizedOperation == "W" || normalizedOperation == "WRITE") {
                operation = Operation::Write;
            } else {
                throw std::runtime_error("line " + std::to_string(lineNumber)
                                         + ": operation must be R or W");
            }

            std::size_t core = 0;
            std::uint64_t address = 0;
            std::uint64_t value = 0;
            try {
                core = parseSize(coreText, "core");
                address = parseUnsigned(addressText, "address");
                if (parser >> valueText) {
                    if (operation != Operation::Write || (parser >> extra)) {
                        throw std::invalid_argument("only writes may include one optional data value");
                    }
                    value = parseUnsigned(valueText, "write value");
                }
            } catch (const std::exception& error) {
                throw std::runtime_error("line " + std::to_string(lineNumber) + ": " + error.what());
            }

            simulator.submit(cache_sim::CacheRequest{core, operation, address, value, issueCycle});
            const std::uint64_t block = address / config.blockSize;
            if (std::find(traceBlocks.begin(), traceBlocks.end(), block) == traceBlocks.end()) {
                traceBlocks.push_back(block);
            }
            if (issueCycle == std::numeric_limits<std::uint64_t>::max()) {
                throw std::overflow_error("trace issue cycle overflow");
            }
            ++issueCycle;
        }
        if (input->bad()) {
            throw std::runtime_error("failed while reading trace input");
        }

        auto results = simulator.run();
        std::sort(results.begin(), results.end(), [](const auto& left, const auto& right) {
            return left.requestId < right.requestId;
        });
        for (const auto& result : results) {
            std::cout << "RESULT " << result.requestId << ' ' << result.core << ' '
                      << cache_sim::toString(result.operation) << ' '
                      << cache_sim::toString(result.state) << " 0x"
                      << std::hex << result.value << std::dec << '\n';
            std::cout << "Core " << result.core << ' '
                      << cache_sim::toString(result.operation) << " 0x"
                      << std::hex << result.address << std::dec
                      << (result.hit ? " HIT " : " MISS ")
                      << "-> " << cache_sim::toString(result.state)
                      << " latency=" << result.latency << " cycles"
                      << " complete@" << result.completionCycle;
            if (result.operation == Operation::Read) {
                std::cout << " value=0x" << std::hex << result.value << std::dec;
            }
            std::cout << '\n';
        }

        for (const std::uint64_t block : traceBlocks) {
            const std::uint64_t address = block * config.blockSize;
            for (std::size_t core = 0; core < config.cores; ++core) {
                const auto state = simulator.stateOf(core, address);
                const std::uint64_t value = state == cache_sim::MesiState::Invalid
                    ? 0
                    : simulator.dataOf(core, address);
                std::cout << "FINAL " << block << ' ' << core << ' '
                          << cache_sim::toString(state) << " 0x"
                          << std::hex << value << std::dec << '\n';
            }
            std::cout << "MEMORY " << block << " 0x"
                      << std::hex << simulator.memoryValue(address) << std::dec << '\n';
        }
        printSummary(simulator);
        std::cout << "COHERENCE invalidations=" << simulator.stats().invalidations
                  << " interventions=" << simulator.stats().interventions
                  << " cache_to_cache_transfers=" << simulator.stats().cacheToCacheTransfers
                  << " grants=" << simulator.stats().coherenceTransactions << '\n';
        return 0;
    } catch (const std::exception& error) {
        std::cerr << "Error: " << error.what() << "\nUse --help for usage.\n";
        return 1;
    }
}
