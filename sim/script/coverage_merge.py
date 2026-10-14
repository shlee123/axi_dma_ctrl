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

def run_urg(args, log, cwd=None):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True, cwd=str(cwd) if cwd else None)
    log.write_text(result.stdout)
    # URG may return zero after skipping an incompatible instance. Never accept
    # a report that silently discarded a source. Keep complete logs for review.
    # An FSM metric can be requested at compile time yet contain zero
    # instrumentable FSM objects in a small unit (e.g. dma_data_fifo).
    # URG reports UCAPI-SNF for that absent shape. It does not indicate a
    # mismatched mapped object. Keep the warning in the log, and narrowly
    # allow this sole diagnostic for the explicitly known FSM-free unit.
    lines = result.stdout.splitlines()
    missing_fsm = any("Warning-[UCAPI-SNF] Shape Not Found" in line for line in lines)
    if missing_fsm:
        missing_fsm = ("'Fsm' coverage shape is not there in the vdb" in result.stdout
                       and "tb_dma_data_fifo.vdb" in result.stdout
                       and log.name == "03-tb_dma_data_fifo.log")
    stripped = re.sub(r"(?ms)^Warning-\\[UCAPI-SNF\\] Shape Not Found\\s*\\n"
                      r".*?(?=^Warning-|^Error|^Fatal|^Note-|\\Z)", "",
                      result.stdout) if missing_fsm else result.stdout
    diagnostics = re.search(r"(?im)^\\s*(?:Warning|Error|Fatal)(?:\\s*[-:]|\\s*\\[)", stripped)
    if result.returncode or diagnostics or ("Warning-[UCAPI-SNF]" in result.stdout and not missing_fsm):
        raise RuntimeError(f"URG failed or reported a diagnostic; see {log}")

def check_urg_version(urg, expected_version):
    result = subprocess.run([urg, "-version"], stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, universal_newlines=True)
    if result.returncode or expected_version not in result.stdout:
        detected = result.stdout.strip() or "<no version output>"
        raise RuntimeError(f"Expected URG {expected_version}; detected: {detected}")

def merge(coverage, config, urg, expected_version="V-2023.12-SP2-6"):
    vdb = coverage / "vdb"
    tests = config["top_tests"] + [u["test"] for u in config["units"]]
    missing = [t for t in tests if not (vdb / (t + ".vdb")).is_dir()]
    if missing:
        raise RuntimeError("Missing required VDBs: " + ", ".join(missing))
    if not shutil.which(urg):
        raise RuntimeError(f"URG executable not found: {urg}")
    check_urg_version(urg, expected_version)
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
                 "-mapfile", str(mapping), "-dbname", stem.name,
                 "-report", str(work / "stage-report")], log, cwd=work)
        # URG -dbname is a database NAME, not a path. A path argument can be
        # flattened into an unexpected database name next to the work directory.
        current = work / (stem.name + ".vdb")
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
    parser.add_argument("--expected-version", default="V-2023.12-SP2-6")
    args = parser.parse_args()
    try:
        merge(args.coverage_dir.resolve(), json.loads(args.config.read_text()), args.urg,
              args.expected_version)
    except (RuntimeError, OSError, ValueError) as exc:
        print("ERROR:", exc, file=sys.stderr)
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
