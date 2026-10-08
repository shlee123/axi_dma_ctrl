#!/usr/bin/env python3
"""Explicit URG instance mapping into one canonical top-level design."""
import argparse
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

SIM = Path(__file__).resolve().parents[1]
CONFIG = SIM / "coverage" / "instances.json"

def plan(config):
    base = config["base"] + "." + config["dut"]
    stages = []
    for test in config["top_tests"]:
        if test != config["base"]:
            stages.append((test, "axi_dma_ctrl", test + "." + config["dut"], base))
    for unit in config["units"]:
        stages.append((unit["test"], unit["module"], unit["test"] + "." + config["dut"],
                       base + "." + unit["instance"]))
    return stages

def map_text(module, source, destination):
    return f"MODULE: {module}\nINSTANCE:\nSRC: {source}\nDST: {destination}\n"

def run_urg(args, log):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log.write_text(result.stdout)
    # URG may return zero after skipping an incompatible instance. Never accept
    # a report that silently discarded a source. Keep complete logs for review.
    diagnostics = re.search(r"(?im)^\s*(?:Warning|Error|Fatal)(?:\s*[-:]|\s*\[)", result.stdout)
    if result.returncode or diagnostics:
        raise RuntimeError(f"URG failed or reported a diagnostic; see {log}")

def merge(coverage, config, urg):
    vdb = coverage / "vdb"
    tests = config["top_tests"] + [u["test"] for u in config["units"]]
    missing = [t for t in tests if not (vdb / (t + ".vdb")).is_dir()]
    if missing:
        raise RuntimeError("Missing required VDBs: " + ", ".join(missing))
    if not shutil.which(urg):
        raise RuntimeError(f"URG executable not found: {urg}")
    # Preserve old outputs until every mapping and report step succeeds.
    work = Path(tempfile.mkdtemp(prefix="merge-work-", dir=coverage))
    current = vdb / (config["base"] + ".vdb")
    audit = []
    for index, (test, module, source, destination) in enumerate(plan(config), 1):
        mapping = work / f"{index:02d}-{test}.map"
        mapping.write_text(map_text(module, source, destination))
        stem = work / f"stage-{index:02d}"
        log = work / f"{index:02d}-{test}.log"
        run_urg([urg, "-full64", "-dir", str(current), str(vdb / (test + ".vdb")),
                 "-mapfile", str(mapping), "-dbname", str(stem),
                 "-report", str(work / "stage-report")], log)
        current = Path(str(stem) + ".vdb")
        if not current.is_dir():
            raise RuntimeError(f"URG did not create expected database {current}; see {log}")
        audit.append(dict(test=test, module=module, source=source, destination=destination))
    hierarchy = work / "report.hier"
    hierarchy.write_text("+tree " + config["base"] + "." + config["dut"] + "\n")
    report = work / "report"
    run_urg([urg, "-full64", "-dir", str(current), "-hier", str(hierarchy),
             "-show", "fullhier", "-format", "both", "-report", str(report)],
            work / "report.log")
    if not (report / "dashboard.html").is_file():
        raise RuntimeError(f"URG did not generate dashboard.html; inspect {work}")
    hierarchy_files = list(report.glob("hierarchy.*"))
    text = "\n".join(p.read_text(errors="replace") for p in hierarchy_files)
    text = re.sub(r"<[^>]*>", " ", text).lower()
    expected = [config["base"], config["dut"]] + [u["instance"] for u in config["units"]]
    missing_instances = [name for name in expected if not re.search(
        r"(?<![a-z0-9_])" + re.escape(name.lower()) + r"(?![a-z0-9_])", text)]
    if missing_instances:
        raise RuntimeError("Missing canonical instances in URG hierarchy report: " +
                           ", ".join(missing_instances) + f"; inspect {work}")
    # This audit is a record of requested mappings, not a coverage-score proof.
    (work / "mapping-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
    for name in ("merged.vdb", "report", "mapping"):
        destination = coverage / name
        if destination.exists():
            shutil.rmtree(destination)
    shutil.move(str(current), str(coverage / "merged.vdb"))
    shutil.move(str(report), str(coverage / "report"))
    evidence = coverage / "mapping"
    evidence.mkdir()
    for pattern in ("*.map", "*.log", "*.json", "*.hier"):
        for path in work.glob(pattern):
            shutil.copy2(path, evidence / path.name)
    shutil.rmtree(work)
    print("Merged database:", coverage / "merged.vdb")
    print("Coverage report:", coverage / "report" / "dashboard.html")
    print("Mapping audit/logs:", evidence)

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--coverage-dir", type=Path, default=SIM / "coverage")
    parser.add_argument("--config", type=Path, default=CONFIG)
    parser.add_argument("--urg", default="urg")
    args = parser.parse_args()
    try:
        merge(args.coverage_dir.resolve(), json.loads(args.config.read_text()), args.urg)
    except (RuntimeError, OSError, ValueError) as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
