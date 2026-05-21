import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
SIM_EXE = REPO_ROOT / "build" / "verilator" / "obj_dir" / "Vtb_top_verilator"


def run_make(*args: str) -> None:
    result = subprocess.run(
        ["make", *args],
        cwd=REPO_ROOT,
        env=os.environ,
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
@pytest.fixture(scope="session", autouse=True)
def prepare_verilator_build() -> None:
    run_make("verilate")


def test_verilator_build() -> None:
    assert SIM_EXE.exists()


def test_simulator_requires_firmware_plusarg() -> None:
    result = subprocess.run(
        [str(SIM_EXE)],
        cwd=REPO_ROOT,
        env=os.environ,
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    assert result.returncode != 0
    assert "+firmware=<hex> plusarg is required" in output
