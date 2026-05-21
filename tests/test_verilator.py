import os
import shutil
import subprocess
from functools import lru_cache
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SIM_EXE = REPO_ROOT / "build" / "verilator" / "obj_dir" / "Vtb_top_verilator"


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


@pytest.mark.parametrize(
    ("app", "expected_pass_marker", "maxcycles"),
    [
        ("shared-memory-demo", "SHARED MEM DEMO PASS sum=10", None),
        ("reduction-demo", "REDUCTION DEMO PASS", None),
        ("tiled-matmul-demo", "TILED MATMUL DEMO PASS", None),
        ("scratchpad-demo", "SCRATCHPAD DEMO PASS", None),
        ("barrier-skew-demo", "BARRIER SKEW DEMO PASS", "5000000"),
        ("latency-test", "LATENCY TEST PASS", None),
    ],
)
def test_example_applications_pass(app: str, expected_pass_marker: str, maxcycles: str | None) -> None:
    args = [f"APP={app}", "run"]
    if maxcycles is not None:
        args.append(f"MAXCYCLES={maxcycles}")
    result = run_make(*args)
    output = result.stdout + result.stderr
    assert expected_pass_marker in output
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
