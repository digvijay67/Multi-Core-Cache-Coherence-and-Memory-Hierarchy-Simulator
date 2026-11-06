# Project progress

## Phase 2 verification and fabric race fix

### Bug found and corrected

The two-core fabric could accept a second same-line coherence request before
the first granted core completed. If the second request snooped the first
controller and invalidated it, the first request's later `req_done` could
restore `M`, creating two Modified owners. The fabric interface has no address
tag, so it cannot distinguish independent lines. The fabric now suppresses
further visible grants and arbiter acceptance until the granted core asserts
`req_done`. This is a conservative single-line behavior, not multi-line
parallelism.

A directed regression holds `bus_ready` high while both cores issue writes,
delays the first completion, verifies no second grant occurs during the delay,
then verifies grants resume and only the final owner is Modified.
The historical failure was replayed against the pre-change RTL from the source
backup; that replay reproduced dual-M state and saved
`build\formal\counterexamples\mesi_fabric_delayed_completion.vcd`.

The formal fabric counterexample also exposed a bookkeeping priority issue in
the harness's `grant_seen` monitor when grant and completion occurred in the
same cycle. The monitor now clears on completion before recording a grant, so
the completion assumptions are associated with the current transaction rather
than a stale grant.

### Verification added

- Added a cache-system functional coverage report sampled from RTL state and
  handshake signals: all nine requested MESI transitions, L1/L2 hits and
  misses, clean/dirty evictions, writebacks, invalidations, interventions and
  forwarding, upgrades, same-line RR/RW/WW, independent-line activity,
  arbitration contention, memory/request/response stalls, reset cases, and
  access sizes/alignment.
- Added a directed clean-eviction sequence and simultaneous same-line WW case.
- Added full-MSHR request backpressure with stable-payload checks, idle reset,
  and request/response accounting. The monitor reports accepted, completed,
  reset-aborted, and outstanding request totals; unexplained responses or
  nonzero outstanding work fail the test.
- Registered the new fabric serialization test in CMake/CTest.
- The standalone controller simulation checker and existing cache-system
  immediate assertions remain simulation-only; they are not formal proofs.

### Test results

Executed after the RTL/testbench changes:

- C++ debug (`-O0 -g`, strict warnings): PASS.
- C++ release (`-O2`, strict warnings): PASS.
- Controller, arbiter, integrated, concurrent, and cache-system RTL benches:
  PASS.
- New same-line delayed-completion serialization regression: PASS.
- Parameterized arbiter and fabric tests at 1, 2, 3, and 4 cores: PASS.
- Cache-system tests, seed `1592594996` / 100 random operations: PASS; 142
  accepted, 141 completed, 1 intentionally reset-aborted, 0 outstanding.
- Cache-system tests, seed `12345` / 300 random operations: PASS; 342 accepted,
  341 completed, 1 intentionally reset-aborted, 0 outstanding.
- Both cache seeds observed all nine tracked MESI transitions and all listed
  directed event categories. Coverage is testbench counters, not a simulator
  coverage engine.
- C++/RTL/Python independent-model comparison: PASS for 200 operations at seed
  `0x5EED1234`.
- Formal controller: ABC PDR PASS and Boolector BMC PASS through depth 24.
- Formal fabric: ABC PDR PASS for legal state encodings/transitions and M/E
  exclusivity in the two-core, address-less model.
- Formal arbiter safety and fairness: Boolector k-induction PASS under explicit
  persistent-request and always-ready assumptions.
- Verilator lint: controller/arbiter/fabric and the new serialization
  testbench PASS with no warnings. Cache-system lint did not finish within
  several minutes and was stopped; no cache-system lint result is claimed.
- Yosys synthesis/latch checks: PASS; refreshed Yosys `0.70+336` reports for
  controller (74 generic cells), arbiter (36), two-core fabric (204), and
  cache system (902,729; 59,237 sequential and 843,492 combinational). No
  `$dlatch` cells were inferred and all structural `check -assert` runs
  reported zero problems. The cache arrays map to registers; ABC emitted
  combinational-network notices on control blocks and Yosys emitted ten
  memory-to-register warnings for the cache arrays. These are generic
  synthesis statistics, not ASIC area/PPA.
- CMake/CTest was not run because CMake is unavailable. GTKWave GUI inspection
  was not performed.

### Formal scope and assumptions

Controller proofs assume reset-safe inputs, well-formed read/write requests,
request payload persistence through completion, grants only for active bus
requests, and bus-requiring completions only after a grant. The controller PDR
proof is unbounded for the harness properties; the separate Boolector result
is bounded to 24 frames.

The fabric PDR proof assumes well-formed persistent requests and completions
only after grants when a bus operation is required. It proves state legality,
legal transition relationships, and mutual exclusion of M/E owners for the
address-less two-core fabric. It does not prove cache data, cache-system
behavior, independent-line fabric concurrency, or liveness.

These are formal harness proofs under their stated assumptions. They do not
establish complete protocol correctness or ASIC readiness.

## Remaining limitations

- The control fabric has no line address or data path and now serializes grants
  through `req_done`; independent-line overlap is only in the separate
  address-bearing cache-system prototype.
- The cache system remains two-core with one MSHR per core and a shared
  service FSM. Cache arrays map to registers, not SRAM macros.
- Cache-system Verilator lint now passes with no warnings. The reduced
  cache-system formal harness passes bounded checking only; a full-size or
  unbounded proof remains unverified. GUI waveform inspection remains
  unverified.
- CMake/CTest is unavailable in this environment; direct compiler/simulator
  regressions were used.
- No physical implementation, timing analysis, area estimate, or PPA result is
  claimed.

## Next steps

Keep the refreshed synthesis reports with the project results and rerun the
documented direct regression after subsequent changes. Keep data correctness,
address aliasing, reset-abort semantics, SRAM inference, and timing constraints
as explicit future verification/design work.

## Phase 3 cache-system verification

### Changes completed

- Reviewed the existing cache-system RTL, formal harness, testbench, synthesis
  flow, and documentation before editing. The Phase 2 fabric serialization
  fix and its historical counterexample/replay were preserved.
- Created and verified a source-only pre-edit archive at
  `build\phase3-before.zip` (33 source/test/document entries; SHA256
  `1ACA69B2BF9EFB39955E4807C9A008F087A9EE44E12C37DA866DD3E0D15A3477`).
- Completed standalone cache-system top lint. Removed unused internal variables,
  made lookup/victim indices explicitly sized, corrected width-sensitive
  address arithmetic, and made the reset-aware transition-history checker
  use a consistent asynchronous-reset style. These are internal RTL cleanup
  changes; module ports and the C++ public API are unchanged.
- Retained the focused cache-system formal assertions/harness for MESI
  transitions, L1/L2 inclusion, ownership/data invariants, writeback,
  back-invalidation, modified-owner forwarding, reset, and handshake
  accounting/stability.
- Ran the Yosys synthesis flow and regenerated reports under
  `build\synthesis`.
- Generated four cache-system VCDs under
  `build\phase3-final\waves`: dirty eviction, modified-owner forwarding,
  request backpressure, and pending-request reset. Programmatic VCD parsing
  confirmed required CPU/memory handshakes, FSM/MESI taps, and scenario signal
  transitions. GTKWave GUI inspection was not completed.

### Verification results

| Check | Result |
|---|---|
| C++ debug (`-O0 -g`, `-Werror`) | PASS |
| C++ optimized (`-O2`, `-Werror`) | PASS |
| Controller, arbiter, integrated, serialization, and concurrent RTL benches | PASS |
| Parameterized arbiter and fabric, core counts 1–4 | PASS |
| Cache-system seed `1592594996`, 100 random operations | PASS; accepted 142, completed 141, reset-aborted 1, outstanding 0 |
| Cache-system seed `12345`, 300 random operations | PASS; accepted 342, completed 341, reset-aborted 1, outstanding 0 |
| Cache-system directed VCD cases 1–4 | PASS; scenario scoreboards balanced, with one intentional reset abort in case 4 |
| Independent C++/RTL/Python comparison | PASS; 200 operations, seed `0x5EED1234`; outputs and coherence event totals matched |
| Arbiter safety/fairness, controller PDR/BMC, fabric PDR | PASS; rerun in `build\phase3-final\formal` under documented assumptions |
| Cache-system formal | PASS; Boolector bounded model checking to depth 12 on 2 cores, 8-bit addresses, 4-byte lines, two-way caches |
| Verilator cache-system lint | PASS; `--lint-only --timing -Wall`, no warnings |
| Yosys synthesis | PASS; all structural checks passed and no latch cells remained |
| CMake/CTest | NOT RUN; CMake is unavailable |
| GTKWave visual review | NOT COMPLETED; VCDs were generated and parsed, but no GUI inspection is claimed |

The cache-system formal result is bounded, not inductive. Its environment
assumes an initial reset, no CPU request during reset, stable CPU request
payload under backpressure, memory responses only for accepted memory
transactions, and stable memory response payload under backpressure. No
eventual-ready assumption is made, so liveness is not proven. The reduced
configuration checks safety properties on the actual RTL, but does not prove
the default full-size configuration or demonstrate that deep dirty-eviction
and forwarding events are reachable within 12 cycles.

Yosys `0.70+336` generic cell counts were: controller 74, arbiter 36,
two-core fabric 204, and cache system 902,729. The cache top contains 59,237
sequential cells and 843,492 combinational cells in its `-noabc` report.
`check -assert` reported zero problems and latch assertions passed. The ten
cache-array memory-to-register warnings mean arrays were expanded into
registers; ABC also emitted combinational-network notices on control blocks.
These are not ASIC area, timing, power, or PPA results.

### Reproduction

Use the direct C++/Icarus commands and cache-case waveform loop in
`README.md`. The additional checks are:

```powershell
. C:\tools\oss-cad-suite\environment.ps1
sby -f formal\mesi_cache_system.sby
.\rtl\synth\run_yosys.ps1 -Yosys C:\tools\oss-cad-suite\bin\yosys.exe
$env:VERILATOR_ROOT = "C:\tools\oss-cad-suite\share\verilator"
& "C:\tools\oss-cad-suite\bin\verilator_bin.exe" --lint-only --timing -Wall --top-module mesi_cache_system rtl\mesi_cache_system.sv
```

### Remaining limitations

- The cache-system proof is bounded and reduced-configuration; no full-size,
  unbounded, or liveness proof is claimed.
- The RTL remains a two-core prototype with one MSHR per core and a shared
  service FSM. Cache arrays are registers, not SRAM macros.
- Reset invalidates cache state and aborts pending local work; it does not
  preserve/flush dirty data or provide recovery for an accepted external
  memory transaction.
- CMake/CTest and GTKWave visual inspection were unavailable/not completed.
- No timing constraints, standard-cell library, physical design, or PPA
  analysis were used.
