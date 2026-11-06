# Multi-Core Cache Coherence and Memory Hierarchy Simulator

A clean, portfolio-ready project focused on cache-coherence protocols, microarchitectural modeling, and validation workflows relevant to ASIC and CPU design roles. The work spans a high-level C++ timing model, synthesizable RTL, and structured verification to study how shared-memory systems behave under MESI coherence and arbitration.

## Role fit

This project is aligned with a Meta ASIC Engineer Intern / CPU Memory Systems Intern role and emphasizes the type of work expected in that environment:

- Cache coherence and memory hierarchy analysis
- Protocol design and state-machine reasoning
- RTL development and debug
- Simulation, formal, and synthesis-based verification
- Clear documentation of assumptions, limitations, and validation evidence

## Project scope

The repository contains three related but distinct implementations:

1. A configurable C++17 trace-driven cache simulator for timing and protocol behavior.
2. Synthesizable RTL for a single-line MESI controller, round-robin arbiter, and coherence fabric.
3. An address-bearing two-core cache-system prototype for an L1/L2 hierarchy and shared service logic.

This is a research and verification project for cache-system design. It is not a full processor, not a complete ASIC implementation, and not a PPA-ready silicon design.

## Highlights

- MESI coherence modeling for read/write, invalidation, downgrade, upgrade, and dirty writeback flows.
- Round-robin arbitration and ready/valid protocol control across multiple coherence requesters.
- Event-driven timing model with configurable latency and queue behavior.
- Address-bearing cache prototype with private L1 caches and a shared inclusive L2.
- Directed simulation, randomized tests, cross-model validation, and formal harness checks.
- Yosys synthesis and Verilator lint validation with explicit scope documentation.

## Architecture overview

### C++ timing model

```text
Trace / CLI
  -> event scheduler
      -> per-core private L1 caches
      -> round-robin coherence bus
          -> shared L2
              -> abstract main memory
```

The simulator models MESI state transitions, LRU replacement, cache-to-cache transfers, invalidations, writebacks, and latency statistics.

### RTL control-plane model

```text
MESI controller per core
  -> ready/valid round-robin arbiter
      -> coherence fabric
          -> snoop and grant routing
```

The control fabric abstracts a single coherence line so the protocol can be checked under conservative serialization assumptions.

### Address-bearing cache prototype

```text
Core 0 -> L1 -> shared service FSM -> L2 / memory
Core 1 -> L1 -> shared service FSM -> L2 / memory
```

The prototype captures more realistic cache-system activity, including per-core MSHR behavior, line lookup, dirty eviction, and shared-memory service coordination.

## Repository map

| Path                                | Purpose                                                           |
| ----------------------------------- | ----------------------------------------------------------------- |
| `include/cache_simulator.hpp`     | C++ simulator API, configuration, statistics, and request model   |
| `src/cache_simulator.cpp`         | Event scheduler, MESI behavior, timing, and cache hierarchy logic |
| `src/main.cpp`                    | Trace parser and CLI entry point                                  |
| `tests/cache_simulator_tests.cpp` | Deterministic and randomized validation                           |
| `tests/compare_cpp_rtl.py`        | Independent scoreboarding and cross-model comparison              |
| `rtl/mesi_controller.sv`          | MESI controller                                                   |
| `rtl/mesi_bus_arbiter.sv`         | Round-robin arbiter                                               |
| `rtl/mesi_coherence_fabric.sv`    | Controller + arbiter + fabric integration                         |
| `rtl/mesi_cache_system.sv`        | Two-core cache-system prototype                                   |
| `rtl/tb/`                         | Directed RTL benches and validation cases                         |
| `formal/`                         | SymbiYosys formal harnesses                                       |
| `rtl/synth/`                      | Yosys synthesis flow and reports                                  |
| `examples/`                       | Example workload traces                                           |

## Quick start

### C++ simulator build

From the project root:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Iinclude src\cache_simulator.cpp src\main.cpp -o build\cache_sim.exe
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Iinclude src\cache_simulator.cpp tests\cache_simulator_tests.cpp -o build\cache_sim_tests.exe
.\build\cache_sim_tests.exe
.\build\cache_sim.exe --trace examples\mesi.trace
```

### RTL simulation

Requirements: Icarus Verilog.

```powershell
iverilog -g2012 -Wall -s mesi_controller_tb -o build\mesi_controller_tb.vvp rtl\mesi_controller.sv rtl\tb\mesi_controller_tb.sv
vvp build\mesi_controller_tb.vvp
```

### Cross-model comparison

```powershell
python tests\compare_cpp_rtl.py --seed 0x5EED1234 --operations 200
```

## Verification status

As of November 2026, the project has completed the following checks under its documented assumptions:

- C++ debug and release test runs pass.
- RTL benches for controller, arbiter, fabric, concurrent access, and cache-system scenarios pass.
- Delayed-completion serialization regression passes.
- Parameterized arbiter and fabric tests pass for 1–4 cores.
- Independent C++/RTL/Python comparison passes.
- Formal checks for controller, arbiter, and fabric pass under explicit assumptions.
- Yosys structural and latch checks pass.
- Verilator lint passes for the cache-system top and protocol blocks.

See [project_progress.md](project_progress.md) for phase history and the detailed verification log.

## Important limitations

- This is a protocol and microarchitecture prototype, not a silicon-ready ASIC.
- The reduced control fabric is intentionally conservative and serializes grants until completion.
- The cache-system prototype is still a two-core design with one MSHR per core and a shared service FSM.
- Formal and synthesis results are valid only within the stated assumptions and configuration scopes.
- Timing, power, and PPA are not claimed.

## Summary

This project demonstrates a practical, end-to-end approach to designing and validating a cache-coherence subsystem: from protocol modeling to RTL implementation and verification. It reflects the type of thinking and rigor expected in ASIC, microarchitecture, and hardware verification work.
