#!/usr/bin/env python3
"""One-pass diagnostics of all source VDBs, with a portable evidence archive."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
from datetime import datetime

SIM = Path(__file__).resolve().parents[1]
def command(argv, log):
    try:
        p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                           universal_newlines=True, timeout=180)
        log.write_text(p.stdout)
        return p.returncode, p.stdout
    except (OSError, subprocess.TimeoutExpired) as exc:
        log.write_text(str(exc))
        return 127, str(exc)

def diagnostic(output, directory, preflight):
    config = json.loads((SIM / "coverage" / "instances.json").read_text())
    directory.mkdir(parents=True, exist_ok=True)
    status = {"patterns": {}, "tools": {}, "errors": [], "warnings": []}
    for name, cmd in (("python", [sys.executable, "--version"]),
                      ("vcs", ["vcs", "-ID"]), ("urg", ["urg", "-version"])):
        rc, data = command(cmd, directory / (name + ".log"))
        status["tools"][name] = {"exit_code": rc, "output": data[:600]}
        if rc and name == "urg":
            status["errors"].append("URG unavailable")
    expected = "V-2023.12-SP2-6"
    for name in ("vcs", "urg"):
        if expected not in status["tools"][name]["output"]:
            status["errors"].append(name + " version mismatch: expected " + expected)
    tests = config["top_tests"] + [u["test"] for u in config["units"]]
    for test in tests:
        db = SIM / "coverage" / "vdb" / (test + ".vdb")
        item = {"vdb_exists": db.is_dir(), "files": 0, "metrics": {}, "warnings": []}
        status["patterns"][test] = item
        if not db.is_dir():
            status["errors"].append(test + ": missing VDB")
            continue
        item["files"] = sum(1 for p in db.rglob("*") if p.is_file() and p.stat().st_size)
        if not item["files"]:
            status["errors"].append(test + ": empty VDB")
            continue
        report = directory / ("report-" + test)
        rc, raw = command(["urg", "-full64", "-dir", str(db), "-show", "fullhier",
                           "-format", "both", "-report", str(report)],
                          directory / (test + ".log"))
        item["urg_exit_code"] = rc
        h = report / "hierarchy.txt"
        if h.is_file():
            txt = h.read_text(errors="replace")
            (directory / (test + "-hierarchy.txt")).write_text(txt)
            item["metrics"]["fsm_shape_present"] = bool(re.search(
                r"(?m)^\s*FSM\s*$", txt)) or bool(re.search(
                r"(?m)^\s*SCORE\s+LINE\s+COND\s+TOGGLE\s+FSM\s+BRANCH", txt))
            item["metrics"]["fsm_not_applicable_rows"] = len(re.findall(
                r"(?m)^\s*\S+\s+\S+\s+\S+\s+\S+\s+--\s+\S+\s+\S+", txt))
        else:
            status["errors"].append(test + ": no hierarchy.txt")
        warnings = re.findall(r"(?m)^(?:Warning|Error|Fatal)[^\n]*", raw)
        item["warnings"] = warnings
        if rc:
            status["errors"].append(test + ": URG exit " + str(rc))
        for w in warnings:
            if "UCAPI-SNF" in w:
                status["warnings"].append(test + ": missing instrumented metric (inspect log)")
            else:
                status["errors"].append(test + ": " + w)
    (directory / "summary.json").write_text(json.dumps(status, indent=2) + "\n")
    (directory / "README.txt").write_text(
        "Coverage diagnostics. Inspect summary.json and per-pattern URG logs. "
        "Review logs for workstation paths before sharing outside the organization.\n")
    if preflight:
        for issue in status["errors"]:
            print("FAIL:", issue)
        for issue in status["warnings"]:
            print("REVIEW:", issue)
        print("Diagnostics:", directory)
    return 1 if status["errors"] else 0

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--preflight", action="store_true")
    parser.add_argument("--output", type=Path, default=SIM / "coverage" / "diagnostic")
    args = parser.parse_args()
    rc = diagnostic(args.output.resolve(), args.output, args.preflight)
    if not args.preflight:
        archive = args.output.parent / "coverage_diagnostic.tar.gz"
        with tarfile.open(str(archive), "w:gz") as tar:
            tar.add(str(args.output), arcname="coverage_diagnostic")
        print("Diagnostic archive:", archive)
    return rc
if __name__ == "__main__":
    sys.exit(main())
