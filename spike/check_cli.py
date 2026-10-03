"""Run after compiling the spike; malformed input must fail before UI access."""
from pathlib import Path
import subprocess

binary = Path(__file__).parent / ".build" / "dictation-spike"
cases = [
    (["--check", "--insert-test"], "Choose one mode"),
    (["--insert-test"], "Insertion requires --expected-app"),
    (["--inspect", "--observe"], "Option does not belong"),
    (["--check", "--delay", "0"], "Option does not belong"),
    (["--listen", "--listen-seconds", "0"], "greater than 0"),
    (["--listen", "--listen-seconds", "nan"], "greater than 0"),
    (["--listen", "--listen-seconds", "61"], "greater than 0"),
    (["--inspect", "--delay"], "Missing value"),
    (["--check", "--check"], "Choose one mode"),
    (["--inspect", "--unknown"], "Unknown option"),
]
for arguments, message in cases:
    result = subprocess.run([str(binary), *arguments], capture_output=True, text=True, timeout=5)
    assert result.returncode == 1 and message in result.stderr, (arguments, result)
    assert not result.stdout, (arguments, "unexpected work before validation", result.stdout)
print(f"CLI rejection checks passed ({len(cases)} cases)")
