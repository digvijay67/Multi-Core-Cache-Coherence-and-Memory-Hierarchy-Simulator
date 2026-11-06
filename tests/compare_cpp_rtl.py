#!/usr/bin/env python3
"""Compile both models and compare state/data for the shared trace."""

import argparse
import random
import re
import shutil
import subprocess
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RTL = ROOT / "rtl"
RESULT_RE = re.compile(
    r"^RESULT (\d+) (\d+) ([RW]) ([ISEM]) 0x([0-9a-fA-F]+)$", re.MULTILINE
)
FINAL_RE = re.compile(
    r"^FINAL (\d+) (\d+) ([ISEM]) 0x([0-9a-fA-F]+)$", re.MULTILINE
)
MEMORY_RE = re.compile(r"^MEMORY (\d+) 0x([0-9a-fA-F]+)$", re.MULTILINE)
COHERENCE_RE = re.compile(
    r"^COHERENCE invalidations=(\d+) interventions=(\d+) "
    r"cache_to_cache_transfers=(\d+) grants=(\d+)$",
    re.MULTILINE,
)
RTL_COHERENCE_RE = re.compile(
    r"^COHERENCE invalidations=(\d+) interventions=(\d+) "
    r"cache_to_cache_transfers=(\d+) grants=\[(\d+),(\d+)\]$",
    re.MULTILINE,
)


def find_tool(explicit, name, windows_path=None, option_name=None):
    if explicit:
        return explicit
    discovered = shutil.which(name)
    if discovered:
        return discovered
    if windows_path and Path(windows_path).is_file():
        return windows_path
    raise RuntimeError(
        f"Required tool '{name}' was not found. Pass its path using "
        f"--{option_name or name}."
    )


def run(command, cwd):
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(
            f"Command failed ({result.returncode}): {' '.join(map(str, command))}\n"
            f"{result.stdout}{result.stderr}"
        )
    return result.stdout, result.stderr


def parse_records(output, pattern, label):
    records = pattern.findall(output)
    if not records:
        raise RuntimeError(f"No {label} records were emitted by the simulator.")
    return records


def generate_trace(path, seed, operation_count):
    directed = [
        ("W", 0, 0x1111222233334444),
        ("R", 1, None),
        ("W", 0, 0x5555666677778888),
        ("R", 1, None),
        ("W", 1, 0x9999AAAABBBBCCCC),
        ("R", 0, None),
    ]
    rng = random.Random(seed)
    operations = list(directed[:operation_count])
    while len(operations) < operation_count:
        core = rng.randrange(2)
        if rng.randrange(2):
            operations.append(("W", core, rng.getrandbits(64)))
        else:
            operations.append(("R", core, None))
    with path.open("w", encoding="ascii", newline="\n") as trace:
        for operation, core, value in operations:
            if operation == "W":
                trace.write(f"W {core} 4096 0x{value:016X}\n")
            else:
                trace.write(f"R {core} 4096\n")
    return operations


def reference_results(operations):
    states = ["I", "I"]
    values = [0, 0]
    memory_value = 0
    expected = []
    grants = 0
    invalidations = 0
    interventions = 0

    for index, (operation, core, write_value) in enumerate(operations):
        peer = 1 - core
        if operation == "R":
            if states[core] == "I":
                peer_valid = states[peer] != "I"
                result_value = values[peer] if peer_valid else memory_value
                if states[peer] == "M":
                    interventions += 1
                if states[peer] in ("M", "E"):
                    states[peer] = "S"
                states[core] = "S" if peer_valid else "E"
                values[core] = result_value
                grants += 1
            else:
                result_value = values[core]
        else:
            if states[core] in ("I", "S"):
                grants += 1
                if states[peer] != "I":
                    if states[peer] == "M":
                        interventions += 1
                    invalidations += 1
                    states[peer] = "I"
            values[core] = write_value
            states[core] = "M"
            result_value = write_value
        expected.append((str(index), str(core), operation, states[core], f"{result_value:016x}"))

    final_states = [
        ("64", str(core), states[core], f"{values[core] if states[core] != 'I' else 0:016x}")
        for core in range(2)
    ]
    return expected, final_states, [("64", f"{memory_value:016x}")], (
        grants,
        invalidations,
        interventions,
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cxx", help="C++ compiler (default: g++)")
    parser.add_argument("--iverilog", help="Icarus compiler (default: iverilog)")
    parser.add_argument("--vvp", help="Icarus runtime (default: vvp)")
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x5EED1234)
    parser.add_argument("--operations", type=int, default=200)
    args = parser.parse_args()
    if args.operations < 1:
        parser.error("--operations must be positive")

    cxx = find_tool(args.cxx, "g++", option_name="cxx")
    iverilog = find_tool(args.iverilog, "iverilog", r"C:\iverilog\bin\iverilog.exe")
    vvp = find_tool(args.vvp, "vvp", r"C:\iverilog\bin\vvp.exe")

    with tempfile.TemporaryDirectory(prefix="cache-model-compare-") as temp_dir:
        temp = Path(temp_dir)
        cpp_exe = temp / "cache_sim.exe"
        rtl_image = temp / "mesi_2core_integrated_tb.vvp"
        trace = temp / "randomized.trace"
        operations = generate_trace(trace, args.seed, args.operations)
        expected_results, expected_finals, expected_memory, expected_counts = (
            reference_results(operations)
        )

        cpp_command = [
            cxx,
            "-std=c++17",
            "-Wall",
            "-Wextra",
            "-Wpedantic",
            "-Werror",
            f"-I{ROOT / 'include'}",
            str(ROOT / "src" / "cache_simulator.cpp"),
            str(ROOT / "src" / "main.cpp"),
            "-o",
            str(cpp_exe),
        ]
        stdout, stderr = run(cpp_command, ROOT)
        if stderr:
            print(stderr, end="")
        print("PASS: C++ simulator compiled with warnings treated as errors.")

        rtl_command = [
            iverilog,
            "-g2012",
            "-Wall",
            "-s",
            "mesi_2core_integrated_tb",
            "-o",
            str(rtl_image),
            str(RTL / "mesi_controller.sv"),
            str(RTL / "mesi_bus_arbiter.sv"),
            str(RTL / "mesi_coherence_fabric.sv"),
            str(RTL / "tb" / "mesi_2core_integrated_tb.sv"),
        ]
        stdout, stderr = run(rtl_command, ROOT)
        if stdout:
            print(stdout, end="")
        if stderr:
            print(stderr, end="")
        print("PASS: integrated RTL testbench compiled.")

        cpp_output, cpp_stderr = run(
            [str(cpp_exe), "--cores", "2", "--trace", str(trace)], ROOT
        )
        if cpp_stderr:
            print(cpp_stderr, end="")
        rtl_output, rtl_stderr = run(
            [vvp, str(rtl_image), "+CROSS_MODEL", f"+TRACE={trace}"], ROOT
        )
        if rtl_stderr:
            print(rtl_stderr, end="")

        cpp_results = parse_records(cpp_output, RESULT_RE, "C++ request result")
        rtl_results = parse_records(rtl_output, RESULT_RE, "RTL request result")
        if len(cpp_results) != len(operations) or len(rtl_results) != len(operations):
            raise RuntimeError(
                f"Expected {len(operations)} request results; "
                f"C++ emitted {len(cpp_results)} and RTL emitted {len(rtl_results)}."
            )
        normalized_results = {}
        for model, records in (("C++", cpp_results), ("RTL", rtl_results)):
            normalized_records = []
            for index, (actual, expected) in enumerate(zip(records, expected_results)):
                normalized = (*actual[:4], f"{int(actual[4], 16):016x}")
                normalized_records.append(normalized)
                if normalized != expected:
                    operation, core, value = operations[index]
                    address = 4096
                    raise RuntimeError(
                        f"{model} reference mismatch txn={index} core={core} "
                        f"address=0x{address:x} op={operation}: "
                        f"expected state={expected[3]} data=0x{expected[4]}, "
                        f"actual state={actual[3]} data=0x{actual[4]}"
                        + (f" write_data=0x{value:016x}" if value is not None else "")
                    )
            normalized_results[model] = normalized_records
        if normalized_results["C++"] != normalized_results["RTL"]:
            raise RuntimeError(
                "Per-request C++/RTL results differ.\n"
                f"C++: {normalized_results['C++']}\nRTL: {normalized_results['RTL']}"
            )

        cpp_finals = parse_records(cpp_output, FINAL_RE, "C++ final-state")
        rtl_finals = parse_records(rtl_output, FINAL_RE, "RTL final-state")
        if len(cpp_finals) != 2 or len(rtl_finals) != 2:
            raise RuntimeError(
                "Expected final cache records for exactly two cores; "
                f"C++ emitted {len(cpp_finals)} and RTL emitted {len(rtl_finals)}."
            )
        normalized_expected_finals = [
            (*record[:3], record[3].lower()) for record in expected_finals
        ]
        normalized_cpp_finals = [
            (*record[:3], f"{int(record[3], 16):016x}") for record in cpp_finals
        ]
        normalized_rtl_finals = [
            (*record[:3], f"{int(record[3], 16):016x}") for record in rtl_finals
        ]
        if (
            normalized_cpp_finals != normalized_expected_finals
            or normalized_rtl_finals != normalized_expected_finals
        ):
            raise RuntimeError(
                "Independent reference final-state mismatch.\n"
                f"Expected: {normalized_expected_finals}\n"
                f"C++: {normalized_cpp_finals}\nRTL: {normalized_rtl_finals}"
            )
        if normalized_cpp_finals != normalized_rtl_finals:
            raise RuntimeError(
                "Final C++/RTL states or line values differ.\n"
                f"C++: {normalized_cpp_finals}\nRTL: {normalized_rtl_finals}"
            )

        cpp_memory = parse_records(cpp_output, MEMORY_RE, "C++ backing-memory")
        rtl_memory = parse_records(rtl_output, MEMORY_RE, "RTL backing-memory")
        normalized_cpp_memory = [
            (address, int(value, 16)) for address, value in cpp_memory
        ]
        normalized_rtl_memory = [
            (address, int(value, 16)) for address, value in rtl_memory
        ]
        if len(cpp_memory) != 1 or len(rtl_memory) != 1:
            raise RuntimeError(
                "Expected one backing-memory record for the shared trace; "
                f"C++ emitted {len(cpp_memory)} and RTL emitted {len(rtl_memory)}."
            )
        expected_memory_values = [(block, int(value, 16)) for block, value in expected_memory]
        if (
            normalized_cpp_memory != normalized_rtl_memory
            or normalized_cpp_memory != expected_memory_values
        ):
            raise RuntimeError(
                "Backing-memory values differ from each other or the reference model.\n"
                f"Expected: {expected_memory_values}\n"
                f"C++: {normalized_cpp_memory}\nRTL: {normalized_rtl_memory}"
            )

        cpp_coherence = parse_records(cpp_output, COHERENCE_RE, "C++ coherence")
        rtl_coherence = parse_records(rtl_output, RTL_COHERENCE_RE, "RTL coherence")
        if len(cpp_coherence) != 1 or len(rtl_coherence) != 1:
            raise RuntimeError("Expected one coherence summary from each model.")
        rtl_grants = str(int(rtl_coherence[0][3]) + int(rtl_coherence[0][4]))
        normalized_rtl_coherence = [
            rtl_coherence[0][0],
            rtl_coherence[0][1],
            rtl_coherence[0][2],
            rtl_grants,
        ]
        expected_coherence = [
            str(expected_counts[1]),
            str(expected_counts[2]),
            str(expected_counts[2]),
            str(expected_counts[0]),
        ]
        if list(cpp_coherence[0]) != normalized_rtl_coherence or list(cpp_coherence[0]) != expected_coherence:
            raise RuntimeError(
                "Coherence outcomes differ from each other or the reference model.\n"
                f"Expected: {expected_coherence}\n"
                f"C++: {cpp_coherence[0]}\nRTL: {normalized_rtl_coherence}"
            )

        print(
            f"PASS: {len(cpp_results)} randomized/directed operations match the "
            f"independent model (seed=0x{args.seed:X})."
        )
        print(f"PASS: {len(cpp_finals)} final per-core state/data records match.")
        print(f"PASS: {len(cpp_memory)} backing-memory records match.")
        print("PASS: invalidations, interventions, cache transfers, and bus grants match.")
        print("Timing is intentionally not compared: C++ is cycle-counted; RTL is protocol-level.")

if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"FAIL: {error}")
