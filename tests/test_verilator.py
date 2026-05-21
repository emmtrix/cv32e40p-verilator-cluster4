import os
import subprocess
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]


def run_make(*args: str) -> str:
    env = os.environ.copy()
    result = subprocess.run(
        ["make", *args],
        cwd=REPO_ROOT,
        env=env,
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
    return result.stdout + result.stderr


@pytest.fixture(scope="session", autouse=True)
def clean_build_artifacts() -> None:
    run_make("clean")


def test_verilator_build() -> None:
    run_make("verilate")


@pytest.mark.parametrize(
    ("app", "expected_output"),
    [
        ("shared-memory-demo", "SHARED MEM DEMO PASS sum=10"),
        ("reduction-demo", "REDUCTION DEMO PASS"),
    ],
)
def test_app_runs_with_success(app: str, expected_output: str) -> None:
    output = run_make("run", f"APP={app}", "MAXCYCLES=5000000")
    assert expected_output in output
    assert "[TB] CLUSTER EXIT SUCCESS" in output
