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

METRICS = ("LINE", "COND", "TOGGLE", "FSM", "BRANCH")
DIAGNOSTIC = re.compile(r"(?im)^\s*(?:Warning|Error|Fatal)(?:\s*[-:]|\s*\[)")
SNF_HEADER = "Warning-[UCAPI-SNF] Shape Not Found"

def run_urg(args, log, cwd=None, fifo_vdb=None):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            universal_newlines=True, cwd=str(cwd) if cwd else None)
    log.write_text(result.stdout)
    # Classify whole diagnostic blocks, never whitelist by an unrelated phrase
    # elsewhere in the log. A candidate is accepted only after VDB validation.
    starts = list(DIAGNOSTIC.finditer(result.stdout))
    candidates = []
    rejected = []
    for i, match in enumerate(starts):
        block = result.stdout[match.start():starts[i + 1].start()
                              if i + 1 < len(starts) else len(result.stdout)]
        paths = re.findall(r"[^\s'\"<>]+\.vdb\b", block)
        candidate = (
            fifo_vdb is not None
            and block.lstrip().splitlines()[0].strip() == SNF_HEADER
            and "'Fsm' coverage shape is not there in the vdb" in block
            and len(paths) == 1
            and Path(paths[0]).resolve() == fifo_vdb.resolve()
            and "SHAPEMISMATCH" not in block.upper())
        (candidates if candidate else rejected).append(block.strip())
    if result.returncode or rejected or "SHAPEMISMATCH" in result.stdout.upper():
        raise RuntimeError(f"URG failed or reported a diagnostic; see {log}")
    return candidates

def vdb_inventory(vdb):
    if not vdb.is_dir():
        raise RuntimeError(f"Missing required VDBs: {vdb}")
    files = sorted(p for p in vdb.rglob("*") if p.is_file() and not p.is_symlink())
    nonempty = [p for p in files if p.stat().st_size > 0]
    if not nonempty:
        raise RuntimeError(f"VDB has no actual nonempty files: {vdb}")
    return dict(files=len(files), nonempty_files=len(nonempty),
                bytes=sum(p.stat().st_size for p in files))

def hierarchy_metrics(report, expected):
    """Parse the indented URG V-2023.12 hierarchy.txt SCORE table.

    URG emits a repeated header for every tree level and a row formatted as
    SCORE LINE COND TOGGLE FSM BRANCH <local_instance_name>. There is no NAME
    header and the local names must be resolved using header indentation.
    """
    path = report / "hierarchy.txt"
    if not path.is_file() or not path.stat().st_size:
        raise RuntimeError(f"Missing canonical instances: no hierarchy.txt in {report}")
    rows = {}
    stack = []  # (header indentation, fully qualified instance name)
    columns = None
    header_indent = None
    aliases = {"TGL": "TOGGLE", "CONDITION": "COND"}
    for line in path.read_text(errors="replace").splitlines():
        tokens = line.replace("|", " ").split()
        normalized = [aliases.get(t.upper(), t.upper()) for t in tokens]
        if "SCORE" in normalized and all(m in normalized for m in METRICS):
            columns = normalized
            header_indent = len(line) - len(line.lstrip())
            continue
        if columns is None or not tokens:
            continue
        if len(tokens) != len(columns) + 1:
            continue
        # The final field is the LOCAL module/instance name.
        local = tokens[-1]
        if not re.fullmatch(r"[A-Za-z_$][A-Za-z0-9_$]*", local):
            continue
        # Header indentation controls tree ancestry; never infer a match
        # from the mere occurrence of an instance name elsewhere in the file.
        while stack and stack[-1][0] >= header_indent:
            stack.pop()
        name = (stack[-1][1] + "." if stack else "") + local
        stack.append((header_indent, name))
        if name not in expected:
            continue
        values = {}
        for metric in METRICS:
            value = tokens[columns.index(metric)]
            if re.fullmatch(r"\\d+(?:\\.\\d+)?%?", value):
                score = float(value.rstrip("%"))
                if not 0 <= score <= 100:
                    raise RuntimeError(f"Invalid {metric} score for {name}: {value}")
                values[metric] = score
            elif value.upper() in ("--", "N/A", "NA"):
                values[metric] = None
            else:
                raise RuntimeError(f"Unrecognized {metric} value for {name}: {value}")
        if name in rows:
            raise RuntimeError(f"Duplicate hierarchy row for {name} in {path}")
        rows[name] = values
    missing = sorted(set(expected) - set(rows))
    if missing:
        raise RuntimeError("Missing canonical instances/metric rows: " +
                           ", ".join(missing) + f"; inspect {path}")
    for name, values in rows.items():
        if values["LINE"] is None or values["TOGGLE"] is None:
            raise RuntimeError(f"Incomplete line/toggle coverage for {name}; inspect {path}")
    return rows

def verify_vdb(urg, vdb, report, log, expected, required=None, fifo_vdb=None):
    inventory = vdb_inventory(vdb)
    candidates = run_urg(
        [urg, "-full64", "-dir", str(vdb), "-show", "fullhier",
         "-format", "both", "-report", str(report)], log, fifo_vdb=fifo_vdb)
    dashboard = report / "dashboard.html"
    if not dashboard.is_file() or not dashboard.stat().st_size:
        raise RuntimeError(f"URG did not generate nonempty dashboard.html; inspect {report}")
    metrics = hierarchy_metrics(report, expected)
    for name, previous in (required or {}).items():
        for metric, value in previous.items():
            if value is not None and metrics[name][metric] is None:
                raise RuntimeError(f"Incomplete {metric} coverage for {name}; inspect {report}")
    # An FSM-free FIFO must still have every other requested coverage metric.
    if candidates:
        fifo_name = next((n for n in expected if n.startswith("tb_dma_data_fifo.")), None)
        if fifo_name is None or any(metrics[fifo_name][m] is None
                                   for m in METRICS if m != "FSM"):
            raise RuntimeError(f"Incomplete FIFO coverage despite missing-FSM diagnostic; see {log}")
        if metrics[fifo_name]["FSM"] is not None:
            raise RuntimeError(f"Contradictory FIFO FSM diagnostic/report; see {log}")
    return dict(vdb=str(vdb), inventory=inventory, instances=metrics,
                missing_fsm_diagnostics=candidates)


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
    canonical = config["base"] + "." + config["dut"]
    expected = [canonical] + [canonical + "." + u["instance"] for u in config["units"]]
    fifo = vdb / "tb_dma_data_fifo.vdb"
    input_audit = {}
    for test in tests:
        names = expected if test == config["base"] else (
            [test + "." + config["dut"]] +
            ([test + "." + config["dut"] + "." + u["instance"] for u in config["units"]]
             if test in config["top_tests"] else []))
        input_audit[test] = verify_vdb(
            urg, vdb / (test + ".vdb"), work / ("input-" + test),
            work / ("input-" + test + ".log"), names,
            fifo_vdb=fifo if test == "tb_dma_data_fifo" else None)
    for test in config["top_tests"]:
        root_metrics = input_audit[test]["instances"][test + "." + config["dut"]]
        if any(root_metrics[m] is None for m in METRICS):
            raise RuntimeError(f"Incomplete top-level coverage metrics in {test}; inspect {work}")
    fifo_metrics = input_audit["tb_dma_data_fifo"]["instances"]["tb_dma_data_fifo." + config["dut"]]
    if any(fifo_metrics[m] is None for m in METRICS if m != "FSM"):
        raise RuntimeError(f"Incomplete non-FSM FIFO coverage; inspect {work}")
    (work / "input-audit.json").write_text(json.dumps(input_audit, indent=2) + "\n")
    current = vdb / (config["base"] + ".vdb")
    required = input_audit[config["base"]]["instances"]
    audit = []
    for index, (test, module, source, destination) in enumerate(plan(config), 1):
        mapping = work / f"{index:02d}-{test}.map"
        mapping.write_text(map_text(module, source, destination))
        stem = work / f"stage-{index:02d}"
        log = work / f"{index:02d}-{test}.log"
        candidates = run_urg(
            [urg, "-full64", "-dir", str(current), str(vdb / (test + ".vdb")),
             "-mapfile", str(mapping), "-dbname", stem.name,
             "-report", str(work / f"stage-{index:02d}-merge-report")],
            log, cwd=work,
            fifo_vdb=fifo if (index, test, module) ==
            (3, "tb_dma_data_fifo", "dma_data_fifo") else None)
        # -dbname takes a NAME. Reopen ONLY its output, with no source VDB
        # and no mapfile, so a missing/broken stage cannot hide behind inputs.
        current = work / (stem.name + ".vdb")
        required = {name: dict(values) for name, values in required.items()}
        for src, values in input_audit[test]["instances"].items():
            dst = destination + src[len(source):]
            for metric, value in values.items():
                if value is not None:
                    required[dst][metric] = value
        verification = verify_vdb(
            urg, current, work / f"stage-{index:02d}-verify-report",
            work / f"{index:02d}-{test}-verify.log", expected, required)
        if candidates:
            values = input_audit[test]["instances"][source]
            if values["FSM"] is not None or any(values[m] is None for m in METRICS if m != "FSM"):
                raise RuntimeError(f"FIFO missing-FSM diagnostic is not supported by source metrics; see {log}")
        # Candidate acceptance follows successful independent stage read and
        # full canonical metric checks; SHAPEMISMATCH is never an exception.
        audit.append(dict(test=test, module=module, source=source,
                          destination=destination, verification=verification,
                          diagnostics=candidates,
                          classification="validated-fifo-no-fsm" if candidates else "validated"))
        (work / "mapping-audit.json").write_text(json.dumps(audit, indent=2) + "\n")
        required = verification["instances"]
    hierarchy = work / "report.hier"
    hierarchy.write_text("+tree " + canonical + "\n")
    report = work / "report"
    run_urg([urg, "-full64", "-dir", str(current), "-hier", str(hierarchy),
             "-show", "fullhier", "-format", "both", "-report", str(report)],
            work / "report.log")
    if not (report / "dashboard.html").is_file() or not (report / "dashboard.html").stat().st_size:
        raise RuntimeError(f"URG did not generate dashboard.html; inspect {work}")
    final_metrics = hierarchy_metrics(report, expected)
    for name in expected:
        for metric in METRICS:
            if required[name][metric] is not None and final_metrics[name][metric] is None:
                raise RuntimeError(f"Incomplete final {metric} coverage for {name}; inspect {work}")
    for name in ("merged.vdb", "report", "mapping"):
        destination = coverage / name
        if destination.exists():
            shutil.rmtree(destination)
    shutil.move(str(current), str(coverage / "merged.vdb"))
    shutil.move(str(report), str(coverage / "report"))
    evidence = coverage / "mapping"
    evidence.mkdir()
    for path in work.glob("*-report"):
        if path.is_dir():
            shutil.copytree(str(path), str(evidence / path.name))
    for path in work.glob("input-*"):
        if path.is_dir():
            shutil.copytree(str(path), str(evidence / path.name))
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
