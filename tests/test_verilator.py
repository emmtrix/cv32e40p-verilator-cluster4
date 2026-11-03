# SPDX-FileCopyrightText: 2024 emmtrix Technologies GmbH
# SPDX-License-Identifier: Apache-2.0

import os
import shutil
import subprocess
from functools import lru_cache
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SIM_EXE = REPO_ROOT / "build" / "verilator" / "obj_dir" / "Vtb_top_verilator"
SW_DIR = REPO_ROOT / "sw"
DEMO_APPS = sorted(path.stem for path in SW_DIR.glob("*-demo.c"))
APP_MAXCYCLES_OVERRIDES = {
    "barrier-skew-demo": "20000000",
}


@lru_cache(maxsize=1)
def make_env_overrides() -> dict[str, str]:
    corev_gcc = Path("/opt/corev/bin/riscv32-corev-elf-gcc")
    if corev_gcc.exists():
        return {}

    local_corev = shutil.which("riscv32-corev-elf-gcc")
    if local_corev is not None:
        return {
            "TOOLCHAIN_ROOT": str(Path(local_corev).resolve().parents[1]),
            "RISCV_PREFIX": "riscv32-corev-elf-",
        }

    pytest.skip(
        "No CORE-V RISC-V toolchain found "
        "(expected /opt/corev/bin/riscv32-corev-elf-gcc or riscv32-corev-elf-gcc in PATH)."
    )


def run_make(*args: str, expect_success: bool = True) -> subprocess.CompletedProcess[str]:
    make_env = os.environ.copy()
    make_env.update(make_env_overrides())
    result = subprocess.run(
        ["make", *args],
        cwd=REPO_ROOT,
        env=make_env,
        capture_output=True,
        text=True,
        check=False,
    )
    if expect_success and result.returncode != 0:
        pytest.fail(
            f"make {' '.join(args)} failed with exit code {result.returncode}\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )
    return result


@pytest.fixture(scope="session", autouse=True)
def prepare_verilator_build() -> None:
    run_make("verilate")


def test_verilator_build() -> None:
    assert SIM_EXE.exists()


def test_demo_app_list_non_empty() -> None:
    assert DEMO_APPS, f"No demo apps found under {SW_DIR}"


@pytest.mark.parametrize("app", DEMO_APPS)
def test_demo_applications_pass(app: str) -> None:
    maxcycles = APP_MAXCYCLES_OVERRIDES.get(app)
    args = [f"APP={app}", "run"]
    if maxcycles is not None:
        args.append(f"MAXCYCLES={maxcycles}")
    result = run_make(*args)
    output = result.stdout + result.stderr

    # Every demo is expected to print a PASS banner before terminating.
    assert "PASS" in output
    assert "[TB] CLUSTER EXIT SUCCESS" in output


def test_latency_test_pass() -> None:
    result = run_make("APP=latency-test", "run")
    output = result.stdout + result.stderr

    assert "LATENCY TEST PASS" in output
    assert "[TB] CLUSTER EXIT SUCCESS" in output


def test_latency_scratchpad_faster_than_shared() -> None:
    """Verify that measured scratchpad cycles < shared-memory cycles."""
    import re

    result = run_make("APP=latency-test", "run")
    output = result.stdout + result.stderr

    assert "LATENCY TEST PASS" in output

    m = re.search(r"spm_cycles=(\d+)\s+shared_cycles=(\d+)", output)
    assert m is not None, f"Could not parse cycle counts from output:\n{output}"

    spm_cycles = int(m.group(1))
    shared_cycles = int(m.group(2))

    assert spm_cycles < shared_cycles, (
        f"Scratchpad ({spm_cycles}) should be faster than shared memory ({shared_cycles})"
    )


def test_custom_stack_size_demo_pass() -> None:
    """A non-default STACK_SIZE moves SPM_DATA_ADDR and still runs cleanly."""
    result = run_make("APP=scratchpad-demo", "STACK_SIZE=8192", "run")
    output = result.stdout + result.stderr

    assert "PASS" in output
    assert "[TB] CLUSTER EXIT SUCCESS" in output


@pytest.mark.parametrize(
    "stack_size, stack_top",
    [
        (None, 0x1808_4000),   # default 16 KiB
        (4096, 0x1808_1000),
    ],
)
def test_stack_overflow_hits_guard_gap(stack_size: int | None, stack_top: int) -> None:
    """Hart 1's stack sits at the start of its SPM; overflowing it must fault
    in the unmapped guard gap that follows core 0's scratchpad."""
    import re

    args = ["APP=stack-overflow-test", "run"]
    if stack_size is not None:
        args.append(f"STACK_SIZE={stack_size}")
    result = run_make(*args, expect_success=False)
    output = result.stdout + result.stderr

    assert result.returncode != 0, f"Simulation was expected to fail:\n{output}"
    assert "STACK CHECK PASS" in output, output
    assert f"stack=[0x18080000, 0x{stack_top:08x})" in output, output
    assert "STACK OVERFLOW START" in output, output

    m = re.search(r"\[TB\] UNMAPPED WRITE ACCESS addr=0x([0-9a-fA-F]{8})", output)
    assert m is not None, f"Expected guard-gap fault, got:\n{output}"
    fault_addr = int(m.group(1), 16)
    # Core 0's guard gap: 0x1804_0000 .. 0x1807_FFFF, just below SPM_ADDR(1).
    assert 0x1804_0000 <= fault_addr < 0x1808_0000, hex(fault_addr)
