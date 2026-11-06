# Multi-Core Cache Coherence and Memory Hierarchy Simulator

A learning and verification project for cache hierarchy, MESI coherence,
arbitration, event-based timing, SystemVerilog RTL, and hardware verification.
It contains three related but distinct implementations:

1. A configurable C++17 trace-driven cache simulator.
2. Synthesizable single-line MESI controller, round-robin arbiter, and
   parameterized control fabric.
3. A separate address-bearing, two-core RTL cache-system prototype.

The project is not a processor implementation or a complete ASIC. Generic
Yosys cell statistics are not silicon area, timing, power, or PPA.

## Project status

Validation snapshot: **November 6, 2026** (Windows).

- C++ debug/release tests, direct Icarus RTL tests, parameterized tests, and
  the independent C++/RTL/Python comparison passed.
- Arbiter, controller, fabric, and reduced cache-system formal jobs passed
  under their documented assumptions and scopes.
- The final Verilator cache-system lint completed without warnings.
- Yosys structural and latch checks passed. Cache arrays map to registers.
- CMake/CTest was not run because CMake was unavailable in the validation
  environment. GTKWave GUI inspection was not completed; VCDs were generated
  and checked programmatically.

See [PROJECT_PROGRESS.md](PROJECT_PROGRESS.md) for phase history and the
latest detailed results.

## Architecture

### C++ timing/cache model

```text
Trace / CLI
    |
    v
Event scheduler
    |
    +-- per-core private, set-associative L1 caches
    |       MESI state, LRU, 64-bit line value
    |
    +-- round-robin coherence bus
            |
            +-- shared inclusive L2
                    |
                    +-- abstract main memory
```

The C++ simulator queues requests per core and cache block and processes
timestamped start, bus-grant, and completion events. It models L1/L2 hits and
misses, coherence transactions, modified-owner interventions, cache-to-cache
data transfers, invalidations, LRU replacement, dirty writebacks, and latency
statistics.

### RTL control plane

```text
MESI controller per core
          |
          v
round-robin ready/valid arbiter
          |
          v
coherence fabric: shared status, grant routing, snoop fanout
```

The controller/fabric interface describes one abstract line and has no address
tag or data array. To avoid a real delayed-completion race, the fabric blocks
later grants until the current granted core asserts `req_done`. This is
conservative serialization; it does not support overlapping transactions to
independent lines.

### Address-bearing RTL cache prototype

```text
Core 0 req/rsp -> [L1 tags/data/MESI/LRU/MSHR] --+
                                                  +--> shared service FSM
Core 1 req/rsp -> [L1 tags/data/MESI/LRU/MSHR] --+          |
                                             [L2 tags/data/dirty/LRU]
                                                          |
                                                ready/valid line memory
```

The default simulation configuration is two 1-KiB, 2-way L1 caches and one
4-KiB, 2-way inclusive L2, with 16-byte lines and a 128-bit memory data path.
Each core has one request slot/MSHR. A shared service FSM serializes misses,
peer coherence actions, evictions, and memory transactions. While that service
is active, a non-active core can complete an aligned resident-L1 read or
E/M-state write to a different line. This prototype is separate from the
address-less control fabric; it is not an integrated processor subsystem.

## Repository map

| Path | Purpose |
|---|---|
| `include/cache_simulator.hpp` | Public C++ configuration, request, result, stats, and simulator API |
| `src/cache_simulator.cpp` | Event scheduler, cache hierarchy, MESI behavior, timing, and invariants |
| `src/main.cpp` | Trace parser, CLI, result and statistics output |
| `tests/cache_simulator_tests.cpp` | C++ unit, directed, invariant, and randomized tests |
| `tests/compare_cpp_rtl.py` | Independent Python reference model and C++/RTL cross-check |
| `examples/` | Sample and cross-model traces |
| `rtl/mesi_controller.sv` | Single-line MESI controller |
| `rtl/mesi_bus_arbiter.sv` | Parameterized round-robin ready/valid arbiter |
| `rtl/mesi_coherence_fabric.sv` | Parameterized controller/arbiter/snoop integration |
| `rtl/mesi_cache_system.sv` | Address-bearing two-core L1/L2 cache prototype |
| `rtl/tb/` | Self-checking controller, arbiter, fabric, concurrent, and cache benches |
| `rtl/synth/` | Reproducible Yosys script and report runner |
| `formal/` | SymbiYosys harnesses, SBY configurations, and historical counterexample test |

## Tools and setup

| Workflow | Required tools |
|---|---|
| C++ simulator/tests | C++17 compiler (MinGW g++, GCC, or MSVC) |
| RTL simulation | Icarus Verilog with `iverilog` and `vvp` |
| CMake regression | CMake 3.16+ and a supported C++17 toolchain |
| Cross-model comparison | Python 3, C++ compiler, Icarus Verilog |
| Formal, synthesis, lint, waveform GUI | OSS CAD Suite (SymbiYosys, Yosys, Verilator, GTKWave) |

Download CMake from [cmake.org/download](https://cmake.org/download/), and
OSS CAD Suite from its [release page](https://github.com/YosysHQ/oss-cad-suite-build/releases/latest).
On Windows, initialize OSS CAD Suite in each PowerShell session before
running its tools:

```powershell
. C:\tools\oss-cad-suite\environment.ps1
```

## C++ simulator

### Configuration

The C++ model defaults are defined in `CacheConfig`:

| Parameter | Default |
|---|---:|
| Cores | 4 |
| L1 per core | 64 sets × 4 ways |
| Shared L2 | 256 sets × 8 ways |
| Cache-line size | 64 bytes |
| L1 hit latency | 1 cycle |
| L2 hit latency | 10 cycles |
| Memory latency | 100 cycles |
| Coherence transaction latency | 5 cycles |
| Cache-to-cache transfer latency | 5 cycles |

The C++ model accepts 1–256 cores and positive set/way/block-size values,
subject to configured cache-line-count limits. Set lookup uses modulo and does
not require power-of-two set counts.

Each simulated cache line carries one 64-bit value. A write replaces that
value; C++ does not model byte lanes or a line full of addressable words.

### Build and run

Requirements: a C++17 compiler. From the project root, with MinGW:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Iinclude src\cache_simulator.cpp src\main.cpp -o build\cache_sim.exe
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Iinclude src\cache_simulator.cpp tests\cache_simulator_tests.cpp -o build\cache_sim_tests.exe
.\build\cache_sim_tests.exe
.\build\cache_sim.exe --trace examples\mesi.trace
```

The CLI also accepts standard input:

```powershell
Get-Content examples\mesi.trace | .\build\cache_sim.exe --cores 4 --l1-sets 32 --l1-ways 2
```

Use `.\build\cache_sim.exe --help` for all options:
`--cores`, `--l1-sets`, `--l1-ways`, `--l2-sets`, `--l2-ways`,
`--block-size`, `--l1-latency`, `--l2-latency`, `--memory-latency`,
`--coherence-latency`, and `--cache-transfer-latency`.

### Trace format

Each non-empty line contains an operation, core index, byte address, and
optionally one write value:

```text
R 0 0x1000
W 1 4096 0x5A
```

Operations may be `R`/`READ` or `W`/`WRITE`. Addresses and write values may be
decimal or `0x`-prefixed hexadecimal. `#` begins a comment. A read cannot
include a data value; a write may include only one. Trace entries are issued
one cycle apart. Each core and each cache block preserves request order.

The program emits per-request `RESULT` records, final per-core cache states,
backing-memory values for touched blocks, and summary hit/miss, coherence,
writeback, bus-wait, and simulated-cycle statistics.

Timing is an event-based abstraction, not a cycle-accurate processor model.
The model does not implement pipelined arrays, physical bus bandwidth, real
MSHR structures, or write buffers. Its latency convention and queueing
behavior are described in the source-level simulation API.

The public C++ API provides `Simulator::submit()`/`run()` for queued concurrent
requests and `Simulator::access()` for a synchronous access. It also exposes
state/data/memory queries, statistics, configuration, and
`validateInvariants()`.

## MESI model

| State | Meaning and behavior |
|---|---|
| **I — Invalid** | No usable local copy. Read miss requests `BusRd`; write miss requests `BusRdX`. |
| **S — Shared** | Clean read-only copy; multiple cores may hold equal data. A writer requests `BusUpgr` and invalidates peers before entering `M`. |
| **E — Exclusive** | Clean copy held by one core. A local write changes `E` to `M`; a peer read downgrades `E` to `S`. |
| **M — Modified** | Sole writable, potentially dirty copy. A peer read obtains the latest data and downgrades the owner to `S`; a peer write invalidates it. |

The intended stable-state invariant is: either one `M` owner, one `E` owner,
or one or more matching `S` copies. Dirty L1 victims update L2; a dirty
inclusive-L2 victim writes the latest line to memory and back-invalidates L1
copies.

## RTL modules

- **`mesi_controller.sv`** issues `BusRd`, `BusRdX`, or `BusUpgr`, holds its
  request until an accepted grant, consumes snoops, and applies the response
  when the request completes.
- **`mesi_bus_arbiter.sv`** scans requesters round-robin. It locks the selected
  requester and command while downstream is backpressured and advances its
  pointer only after `grant_valid && grant_ready`.
- **`mesi_coherence_fabric.sv`** instantiates the configured controllers,
  derives shared status, routes accepted grants, and broadcasts snoops.
  Parameterized simulation tests cover 1–4 cores.
- **`mesi_cache_system.sv`** implements address/tag lookup, private L1 and
  shared inclusive L2 arrays, byte/halfword/word accesses, line transfers,
  dirty writeback, and a per-core L1-hit bypass. Its normal simulation
  configuration is constrained to two cores, 32-bit data, 16-byte lines,
  2-way caches, and power-of-two set counts. Its external memory interface
  transfers full lines.

CPU accesses to the RTL cache system must be naturally aligned and cannot
span cache lines. Misaligned or reserved-size requests complete with
`cpu_rsp_error`. Reset invalidates cache state and cancels pending local work;
it does not flush dirty data or recover an accepted external memory operation.

## Verification

### Strategy

The project uses multiple, distinct forms of evidence:

- Directed and deterministic randomized simulation.
- Independent transaction/reference scoreboards for data and request
  accounting.
- Immediate simulation assertions for state, ownership, and ready/valid
  behavior.
- Functional coverage counters reported by testbenches.
- Formal properties in SymbiYosys harnesses under explicit assumptions.
- C++/RTL/Python output comparison.
- Yosys structural checks and generic synthesis statistics.

Simulation assertions and coverage counters are not formal proofs or
simulator-native functional coverage.

### Test matrix and latest results

The following results were executed directly in the Windows environment:

| Area | Result |
|---|---|
| C++ debug (`-O0 -g`, strict warnings) and release (`-O2`, strict warnings) | **PASS** |
| Standalone controller and arbiter tests | **PASS** |
| Integrated directed and random two-core test | **PASS**; 210 transactions, seed `0x5EED1234` |
| Delayed-completion fabric serialization test | **PASS** |
| Concurrent two-core test | **PASS**; seed `1592594996`, `PAIRS=100`, 214 requests completed |
| Parameterized arbiter and fabric | **PASS**; core counts 1, 2, 3, and 4 |
| Address-bearing cache system | **PASS**; seed `1592594996`/100 ops and `12345`/300 ops |
| Cache-system accepted/completed accounting | **PASS**; 142/141 plus 1 reset abort, and 342/341 plus 1 reset abort; zero outstanding |
| C++/RTL/Python comparison | **PASS**; 200 operations, seed `0x5EED1234` |
| Verilator cache-system top lint | **PASS**; no warnings |
| CMake/CTest | **NOT RUN**; CMake was unavailable |
| GTKWave visual review | **NOT COMPLETED**; VCDs were parsed, but no GUI inspection is claimed |

The cache-system coverage counters observed all nine tracked transitions:
`I→S`, `I→E`, `I→M`, `S→I`, `S→M`, `E→I`, `E→M`, `M→I`, and `M→S`.
They also report L1/L2 hits and misses, clean/dirty eviction, writebacks,
invalidation, intervention/forwarding, upgrade, same-line RR/RW/WW,
independent-line overlap, arbitration contention, memory/request/response
stalls, reset cases, and access sizes/alignment. These are observed
testbench counters, not a claim of exhaustive or 100% coverage.

The cross-model test uses an independent Python reference model and compares
per-operation results, final cache states/data, memory values, and coherence
event counts. It intentionally tests a single line and does not compare timing:
the C++ model is cycle-counted while RTL is protocol-level.

### Direct regression commands

Requirements for RTL simulation: Icarus Verilog and `vvp`. Run from the
project root:

```powershell
New-Item -ItemType Directory -Force build | Out-Null
iverilog -g2012 -Wall -s mesi_controller_tb -o build\mesi_controller_tb.vvp rtl\mesi_controller.sv rtl\tb\mesi_controller_tb.sv
vvp build\mesi_controller_tb.vvp

iverilog -g2012 -Wall -s mesi_bus_arbiter_tb -o build\mesi_bus_arbiter_tb.vvp rtl\mesi_bus_arbiter.sv rtl\tb\mesi_bus_arbiter_tb.sv
vvp build\mesi_bus_arbiter_tb.vvp

iverilog -g2012 -Wall -s mesi_2core_integrated_tb -o build\mesi_2core_integrated_tb.vvp rtl\mesi_controller.sv rtl\mesi_bus_arbiter.sv rtl\mesi_coherence_fabric.sv rtl\tb\mesi_2core_integrated_tb.sv
vvp build\mesi_2core_integrated_tb.vvp

iverilog -g2012 -Wall -s mesi_fabric_completion_serialization_tb -o build\mesi_fabric_completion_serialization_tb.vvp rtl\mesi_controller.sv rtl\mesi_bus_arbiter.sv rtl\mesi_coherence_fabric.sv rtl\tb\mesi_fabric_completion_serialization_tb.sv
vvp build\mesi_fabric_completion_serialization_tb.vvp

iverilog -g2012 -Wall -s mesi_2core_concurrent_tb -o build\mesi_2core_concurrent_tb.vvp rtl\mesi_controller.sv rtl\mesi_bus_arbiter.sv rtl\tb\mesi_2core_concurrent_tb.sv
vvp build\mesi_2core_concurrent_tb.vvp +SEED=1592594996 +PAIRS=100

iverilog -g2012 -Wall -s mesi_cache_system_tb -o build\mesi_cache_system_tb.vvp rtl\mesi_cache_system.sv rtl\tb\mesi_cache_system_tb.sv
vvp build\mesi_cache_system_tb.vvp +SEED=1592594996 +OPS=100
vvp build\mesi_cache_system_tb.vvp +SEED=12345 +OPS=300
```

Run the C++ tests in debug and optimized modes and the cross-model comparison:

```powershell
g++ -std=c++17 -O0 -g -Wall -Wextra -Wpedantic -Werror -Iinclude src\cache_simulator.cpp tests\cache_simulator_tests.cpp -o build\cache_tests_debug.exe
.\build\cache_tests_debug.exe
g++ -std=c++17 -O2 -Wall -Wextra -Wpedantic -Werror -Iinclude src\cache_simulator.cpp tests\cache_simulator_tests.cpp -o build\cache_tests_release.exe
.\build\cache_tests_release.exe
python tests\compare_cpp_rtl.py --cxx C:\MinGW\bin\g++.exe --iverilog C:\iverilog\bin\iverilog.exe --vvp C:\iverilog\bin\vvp.exe --seed 0x5EED1234 --operations 200
```

The parameterized benches can be run for each core count:

```powershell
foreach ($n in 1, 2, 3, 4) {
    $image = "$env:TEMP\mesi_arbiter_${n}core.vvp"
    iverilog -g2012 -Wall "-Pmesi_bus_arbiter_param_tb.CORE_COUNT=$n" -s mesi_bus_arbiter_param_tb -o $image rtl\mesi_bus_arbiter.sv rtl\tb\mesi_bus_arbiter_param_tb.sv
    if ($LASTEXITCODE -ne 0) { throw "arbiter compile failed for $n cores" }
    vvp $image
    if ($LASTEXITCODE -ne 0) { throw "arbiter test failed for $n cores" }
}
foreach ($n in 1, 2, 3, 4) {
    $image = "$env:TEMP\mesi_fabric_${n}core.vvp"
    iverilog -g2012 -Wall "-Pmesi_coherence_fabric_param_tb.CORE_COUNT=$n" -s mesi_coherence_fabric_param_tb -o $image rtl\mesi_controller.sv rtl\mesi_bus_arbiter.sv rtl\mesi_coherence_fabric.sv rtl\tb\mesi_coherence_fabric_param_tb.sv
    if ($LASTEXITCODE -ne 0) { throw "fabric compile failed for $n cores" }
    vvp $image
    if ($LASTEXITCODE -ne 0) { throw "fabric test failed for $n cores" }
}
```

### CMake/CTest

The project uses CMake 3.16 or later. When CMake, a C++17 compiler, Icarus,
`vvp`, and optionally Python are on `PATH`, configure, build, and run tests:

```powershell
cmake -S . -B build -G "MinGW Makefiles" -DBUILD_TESTING=ON
cmake --build build --parallel
ctest --test-dir build --output-on-failure
```

The CMake configuration registers the C++ test, standalone RTL tests,
parameterized arbiter/fabric tests, integrated, serialization, concurrent,
and cache-system RTL tests. The Python cross-model test is registered when
Python and a GNU/Clang C++ compiler are found. In the latest validation
environment, CMake was unavailable, so these CTest commands were not run.

## Assertions and formal results

### Simulation checks

The testbenches check controller state transitions, request/grant/completion
ordering, grant stability under backpressure, legal observed MESI transitions,
exclusive M/E ownership, matching data in shared copies, inclusion, stalled
CPU/memory payload stability, and response accounting. The cache testbench
reports accepted, completed, reset-aborted, and outstanding request totals.
These checks execute in simulation and do not prove all possible traces.

### SymbiYosys jobs

| Job | Result and scope |
|---|---|
| Arbiter safety | **PASS**, Boolector k-induction for grant/payload stability under backpressure |
| Arbiter fairness | **PASS**, Boolector k-induction assuming continuously asserted requests and always-ready grant acceptance |
| MESI controller | **PASS**, ABC PDR and Boolector BMC through 24 frames under the interface assumptions in its harness |
| Coherence fabric | **PASS**, ABC PDR for state legality/transitions and M/E ownership in the address-less two-core fabric |
| Cache system | **PASS**, Boolector BMC to depth 12 on two cores, 8-bit addresses, 4-byte lines, and two-way caches |

The cache-system harness assumes an initial reset, no CPU request during reset,
stable CPU request payloads while stalled, memory responses only after an
accepted memory request, and stable memory response payloads while stalled.
It does not assume eventual readiness. Its checks cover reset clearing, MESI
transitions, L1/L2 inclusion, ownership/shared-data invariants,
back-invalidation, dirty L1-to-L2 writeback, memory write payload, forwarding,
and request/response behavior.

The depth-12 cache-system result is bounded, not inductive or unbounded. It
does not prove the default cache geometry, system-wide liveness, or that deep
dirty-eviction/forwarding scenarios are reachable within the bound. Formal
PASS applies only to the properties and assumptions in each harness.

Run the formal suite from an initialized OSS CAD Suite PowerShell:

```powershell
. C:\tools\oss-cad-suite\environment.ps1
sby -f -d build\formal\mesi_bus_arbiter_safety formal\mesi_bus_arbiter_safety.sby
sby -f -d build\formal\mesi_bus_arbiter_fairness formal\mesi_bus_arbiter_fairness.sby
sby -f -d build\formal\mesi_controller formal\mesi_controller.sby
sby -f -d build\formal\mesi_controller_bmc formal\mesi_controller_bmc.sby
sby -f -d build\formal\mesi_coherence_fabric formal\mesi_coherence_fabric.sby
sby -f -d build\formal\mesi_cache_system formal\mesi_cache_system.sby
```

The historical `formal/counterexamples/mesi_fabric_delayed_completion_tb.sv`
captures the pre-fix dual-M race. The old behavior can be replayed against
the pre-change source snapshot; the current serialization regression checks
the fixed behavior.

## Synthesis and lint

### Yosys

Run the checked-in generic synthesis flow with OSS CAD Suite:

```powershell
. C:\tools\oss-cad-suite\environment.ps1
.\rtl\synth\run_yosys.ps1 -Yosys C:\tools\oss-cad-suite\bin\yosys.exe
```

The flow synthesizes the controller, arbiter, two-core fabric, and cache
system. It runs `check -assert` and fails if `$dlatch`/`$_DLATCH_*` cells are
present. Reports and logs are written under `build\synthesis`.

Yosys `0.70+336` completed the flow with zero reported structural problems
and no inferred latch cells. Generic statistics:

| RTL top | Generic cells |
|---|---:|
| `mesi_controller` | 74 |
| `mesi_bus_arbiter` | 36 |
| `mesi_coherence_fabric` | 204 |
| `mesi_cache_system` | 902,729 |

The cache-system count is from `synth -noabc` and comprises 59,237 sequential
and 843,492 combinational cells. Ten memory-to-register warnings report that
the cache arrays were expanded into registers. ABC also emitted
combinational-network notices on control blocks. The cache count is not
directly comparable with ABC-mapped control counts. These results are generic
logic statistics only—not ASIC area, timing, power, or PPA.

### Verilator

The final cache-system top lint command completed without warnings:

```powershell
$env:VERILATOR_ROOT = "C:\tools\oss-cad-suite\share\verilator"
& "C:\tools\oss-cad-suite\bin\verilator_bin.exe" --lint-only --timing -Wall --top-module mesi_cache_system rtl\mesi_cache_system.sv
```

Icarus prints informational constant-select notices for some `always_*`
processes, but the cache-system bench compiles and runs. No timing constraints,
standard-cell library, STA, physical implementation, or PPA analysis is part
of this project.

## Waveforms

The control-plane waveform script generates seven directed VCDs and
transaction logs:

```powershell
.\rtl\tb\run_waveforms.ps1 -Iverilog C:\iverilog\bin\iverilog.exe -Vvp C:\iverilog\bin\vvp.exe
```

The cache-system testbench supports four scenario traces. After compiling it
as shown above:

```powershell
New-Item -ItemType Directory -Force build\waves | Out-Null
foreach ($caseId in 1, 2, 3, 4) {
    vvp build\mesi_cache_system_tb.vvp "+CASE=$caseId" +OPS=0 "+WAVE=build\waves\cache_case_$caseId.vcd"
}
```

| Case | Scenario |
|---|---|
| 1 | Dirty eviction and L2 back-invalidation |
| 2 | Modified-owner forwarding |
| 3 | CPU request backpressure |
| 4 | Reset recovery with a pending stalled request |

Open any generated trace with GTKWave when available, for example:

```powershell
gtkwave build\waves\cache_case_2.vcd
```

The cache VCDs include CPU/memory request-response handshakes, FSM state,
active address, victim data/status, MSHRs, fast-path signals, and packed L1
MESI state/valid taps. The latest run parsed the files and confirmed
scenario-signal transitions. GTKWave visual inspection was not completed and
is not claimed.

## Known limitations and next work

- The C++ model stores one 64-bit value per line, not a byte-addressable line
  with byte enables.
- The C++ timing model abstracts pipelines, physical bandwidth, MSHRs, and
  write buffers. Inclusive-L2 back-invalidations are not separately
  arbitrated transactions in that model.
- The address-less control fabric serializes through request completion and
  has no cache arrays, addresses, or data path.
- The address-bearing RTL is a two-core prototype with one MSHR per core and
  a shared service FSM. Misses, snoops, evictions, and memory transfers
  serialize; only selected different-line resident L1 hits bypass that work.
- Cache arrays map to registers, not SRAM macros. Reset invalidates local
  state but does not flush dirty data or recover an accepted memory operation.
- Cache-system formal evidence is bounded at depth 12 in a reduced
  configuration. There is no full-size/unbounded proof or liveness proof.
- Coverage is based on testbench counters, not simulator-native coverage.
- CMake/CTest was unavailable and GTKWave visual review was not completed in
  the latest validation.
- No processor execution, physical design, timing closure, power analysis, or
  ASIC PPA is implemented or claimed.

Recommended next steps are to target SRAM inference or macros, improve
independent-miss concurrency, strengthen full-geometry cache-system formal
properties, add simulator-native coverage, and perform timing analysis only
after a target library and constraints are available.
