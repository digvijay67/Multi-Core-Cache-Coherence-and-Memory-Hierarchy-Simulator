# Project progress

## Current status

This project is functionally validated as a cache-coherence and memory-hierarchy research platform aligned with a Meta ASIC Engineer Intern / CPU Memory Systems Intern scope. The work spans a C++ timing model, synthesizable RTL, and verification-driven validation for MESI protocol behavior, arbitration, and cache-system interactions.

## Phase 1: C++ simulation model

Completed a trace-driven C++ cache simulator that captures:

- per-core private L1 caches
- shared L2 hierarchy
- MESI state transitions
- LRU replacement policy
- event-driven latency accounting
- coherence and writeback behavior

The simulator provides a fast way to explore protocol behavior and quantify hit/miss, latency, and coherence activity under configurable workloads.

## Phase 2: RTL protocol blocks and fabric validation

Implemented a set of RTL modules for:

- MESI controller logic
- round-robin ready/valid arbiter
- coherence fabric
- protocol-level system integration

Key validation work included fixing a fabric race condition in which a second same-line request could be accepted before the first transaction completed. The fix introduced conservative serialization until `req_done`, preventing two Modified owners from being created under a delayed-completion scenario.

This phase also added targeted regression checks for:

- same-line delayed completion
- clean eviction behavior
- arbitration fairness and safety
- high-contention request sequences

## Phase 3: address-bearing cache-system verification

Extended the design to a two-core address-bearing cache-system prototype with:

- private L1 caches and inclusive L2 behavior
- shared service FSM
- dirty eviction and back-invalidation handling
- MSHR-style request accounting
- control and data-path interactions

Verification work included:

- C++ debug and release regression runs
- RTL bench execution for controller, arbiter, fabric, and cache-system tests
- parameterized core-count validation
- independent C++/RTL/Python comparison
- formal property checks for controller, arbiter, and fabric logic
- Yosys synthesis and structural checks
- Verilator lint for the top cache-system module

## Verification snapshot

Validated under the current project assumptions and environment:

- C++ debug and release tests: PASS
- Controller, arbiter, integrated, serialization, and concurrent RTL benches: PASS
- Parameterized arbiter/fabric tests for 1–4 cores: PASS
- C++/RTL/Python comparison: PASS
- Formal controller, arbiter, and fabric checks: PASS
- Yosys structural and latch checks: PASS
- Verilator cache-system lint: PASS
- CMake/CTest: not run because CMake is unavailable in this environment
- GTKWave GUI review: not completed; waveform outputs were generated and parsed programmatically

## Scope and limitations

The design remains intentionally scoped:

- The coherence fabric is single-line and conservative; it does not claim independent-line parallelism without additional address-aware control.
- The cache-system prototype is a two-core model with one MSHR per core and a shared service FSM.
- The formal results apply to the current harnesses and assumptions, not full ASIC readiness.
- No timing closure, physical design, area estimate, power calculation, or PPA claim is made.

## Next steps

Planned future work includes:

- broadening the cache-system formal environment to more realistic scenarios
- improving address-aware concurrency at the fabric level
- validating deeper dirty-eviction and forwarding sequences
- continuing synthesis and verification on larger or more complete configurations
- documenting any additional design constraints needed for production ASIC development

## Summary

The project has reached a strong verification checkpoint for a microarchitecture-focused cache-coherence prototype. The current evidence supports the correctness of the modeled protocol and the implemented RTL within the documented assumptions, while keeping the scope honest and appropriate for an academic and internship-style ASIC design project.
