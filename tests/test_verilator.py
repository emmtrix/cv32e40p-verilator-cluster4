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


def run_make(*args: str) -> subprocess.CompletedProcess[str]:
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
    if result.returncode != 0:
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
