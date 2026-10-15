#!/usr/bin/env python3
"""Portable merge-contract tests; these do not emulate Synopsys bin semantics."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from coverage_merge import CONFIG, merge, plan, run_urg, hierarchy_metrics
from validate_coverage_mapping import validate

STUB = r"""#!/usr/bin/env python3
import json, os, pathlib, sys
a = sys.argv[1:]
root = pathlib.Path(__file__).parent
if a == ["-version"]:
    print("V-2022.06" if (root / "bad-version").exists() else "URG V-2023.12-SP2-6")
    sys.exit(0)
with (root / "calls.jsonl").open("a") as f: f.write(json.dumps(a) + "\n")
if (root / "fail").exists(): print("Error-[TEST] rejected"); sys.exit(3)
if (root / "warn").exists(): print("Warning-[TEST] instance ignored")
if "-dbname" in a:
    output = pathlib.Path(a[a.index("-dbname") + 1] + ".vdb")
    if not (root / "missing-stage").exists():
        output.mkdir()
        if not (root / "empty-stage").exists() and not ((root / "empty-fifo-stage").exists() and output.name == "stage-03.vdb"):
            (output / "data").write_text("stub data")
    if (root / "fifo-warning").exists() and pathlib.Path(a[a.index("-mapfile") + 1]).stem == "03-tb_dma_data_fifo":
        fifo = root / "coverage" / "vdb" / "tb_dma_data_fifo.vdb"
        print("Warning-[UCAPI-SNF] Shape Not Found")
        print("'Fsm' coverage shape is not there in the vdb '" + str(fifo) + "'")
is_stage_read = "-dbname" not in a and pathlib.Path(a[a.index("-dir") + 1]).name.startswith("stage-")
if "-dbname" not in a and ((root / "reopen-fail").exists() or
                          (is_stage_read and (root / "stage-read-fail").exists())):
    print("Error-[READ] VDB unreadable")
    sys.exit(2)
if "-report" in a:
    report = pathlib.Path(a[a.index("-report") + 1])
    report.mkdir(exist_ok=True)
    (report / "dashboard.html").write_text("stub report; no coverage scores")
    if not (root / "missing-hierarchy").exists():
        cfg = json.loads((root / "config.json").read_text())
        base = cfg["base"] + "." + cfg["dut"]
        names = [base] + [base + "." + u["instance"] for u in cfg["units"]]
        database = pathlib.Path(a[a.index("-dir") + 1]).name
        test = database[:-4]
        if test in cfg["top_tests"]:
            names = [n.replace(cfg["base"], test, 1) for n in names]
        elif test in [u["test"] for u in cfg["units"]]:
            names = [test + "." + cfg["dut"]]
        if (root / "wrong-parent").exists():
            names = [n.replace(base, "wrong.dut") for n in names]
        # Match URG V-2023.12's hierarchical score table, including
        # ancestor rows even when the requested instance is deep.
        expanded = set()
        for name in names:
            parts = name.split(".")
            for level in range(1, len(parts) + 1):
                expanded.add(".".join(parts[:level]))
        rows = []
        for name in sorted(expanded, key=lambda n: (n.count("."), n)):
            depth = name.count(".")
            indent = "  " * depth
            rows.append(indent + "SCORE LINE COND TOGGLE FSM BRANCH")
            fsm = "--" if name in ("tb_dma_data_fifo.dut", "tb_dma_cdc.dut",
                                    "tb_dma_apb_regs.dut") else "0.00"
            line = "--" if ((root / "missing-metric").exists() or
                           (is_stage_read and (root / "stage-missing-metric").exists())) else "0.00"
            rows.append(indent + "0.00 " + line + " 0.00 0.00 " + fsm +
                        " 0.00 " + name.split(".")[-1])
        (report / "hierarchy.txt").write_text("\n".join(rows) + "\n")
"""

class CoverageMergeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.cfg = json.loads(CONFIG.read_text())
        (self.root / "config.json").write_text(json.dumps(self.cfg))
        self.coverage = self.root / "coverage"
        (self.coverage / "vdb").mkdir(parents=True)
        for t in self.cfg["top_tests"] + [u["test"] for u in self.cfg["units"]]:
            database = self.coverage / "vdb" / (t + ".vdb")
            database.mkdir()
            (database / "data").write_text("stub data")
        self.urg = self.root / "urg"
        self.urg.write_text(STUB)
        self.urg.chmod(0o755)

    def run_merge(self):
        with contextlib.redirect_stdout(io.StringIO()):
            merge(self.coverage, self.cfg, str(self.urg))

    def old_output(self):
        (self.coverage / "merged.vdb").mkdir()
        (self.coverage / "merged.vdb" / "old").touch()
        (self.coverage / "report").mkdir()
        (self.coverage / "report" / "old").touch()

    def assert_preserved(self):
        self.assertTrue((self.coverage / "merged.vdb" / "old").exists())
        self.assertTrue((self.coverage / "report" / "old").exists())

    def test_source_mapping(self):
        with contextlib.redirect_stdout(io.StringIO()): validate(self.cfg)
        bad = copy.deepcopy(self.cfg)
        bad["units"][0]["instance"] = "u_typo"
        with self.assertRaises(ValueError): validate(bad)

    def test_all_sources_mapped_into_canonical_dut(self):
        self.old_output()
        self.run_merge()
        calls = [json.loads(line) for line in (self.root / "calls.jsonl").read_text().splitlines()]
        self.assertEqual(len(calls), 26)
        merge_calls = [call for call in calls if "-mapfile" in call]
        reopen_calls = [call for call in calls if "-dbname" not in call and
                        "stage-" in call[call.index("-dir") + 1]]
        self.assertEqual(len(reopen_calls), 9)
        for call in reopen_calls:
            self.assertNotIn("-mapfile", call)
            boundary = call.index("-hier") if "-hier" in call else call.index("-show")
            self.assertEqual(boundary - call.index("-dir"), 2)
        stages = plan(self.cfg)
        for call, (test, module, source, destination) in zip(merge_calls, stages):
            dirs = call[call.index("-dir") + 1:call.index("-mapfile")]
            self.assertTrue(dirs[1].endswith(test + ".vdb"))
            self.assertNotIn("-flex_merge", call)
            maps = list((self.coverage / "mapping").glob("*-" + test + ".map"))
            self.assertEqual(len(maps), 1)
            text = maps[0].read_text()
            self.assertIn("MODULE: " + module, text)
            self.assertIn("SRC: " + source, text)
            self.assertIn("DST: " + destination, text)
        self.assertTrue(merge_calls[0][merge_calls[0].index("-dir") + 1].endswith(self.cfg["base"] + ".vdb"))
        self.assertTrue((self.coverage / "merged.vdb").is_dir())
        self.assertTrue((self.coverage / "report" / "dashboard.html").is_file())
        self.assertEqual(len(list(self.coverage.glob("*.vdb"))), 1)
        self.assertEqual(len(json.loads((self.coverage / "mapping" / "mapping-audit.json").read_text())), 8)

    def test_missing_database_preserves_report(self):
        self.old_output()
        database = self.coverage / "vdb" / (self.cfg["base"] + ".vdb")
        (database / "data").unlink()
        database.rmdir()
        with self.assertRaisesRegex(RuntimeError, "Missing required VDBs"): self.run_merge()
        self.assert_preserved()
        self.assertFalse((self.root / "calls.jsonl").exists())

    def test_missing_tool_preserves_report(self):
        self.old_output()
        self.urg.unlink()
        with self.assertRaisesRegex(RuntimeError, "not found"): self.run_merge()
        self.assert_preserved()

    def test_wrong_urg_version_preserves_report(self):
        self.old_output()
        (self.root / "bad-version").touch()
        with self.assertRaisesRegex(RuntimeError, "Expected URG V-2023.12-SP2-6"):
            self.run_merge()
        self.assert_preserved()
        self.assertFalse((self.root / "calls.jsonl").exists())

    def test_tool_error_preserves_report_and_log(self):
        self.old_output()
        (self.root / "fail").touch()
        with self.assertRaisesRegex(RuntimeError, "URG failed"): self.run_merge()
        self.assert_preserved()
        self.assertTrue(list(self.coverage.glob("merge-work-*/*.log")))

    def test_zero_exit_warning_is_not_silent_success(self):
        self.old_output()
        (self.root / "warn").touch()
        with self.assertRaisesRegex(RuntimeError, "diagnostic"): self.run_merge()
        self.assert_preserved()

    def test_missing_report_hierarchy_is_rejected(self):
        self.old_output()
        (self.root / "missing-hierarchy").touch()
        with self.assertRaisesRegex(RuntimeError, "Missing canonical instances"): self.run_merge()
        self.assert_preserved()


    def test_empty_stage_and_missing_stage_fail(self):
        for marker in ("empty-stage", "missing-stage"):
            with self.subTest(marker=marker):
                self.old_output() if not (self.coverage / "merged.vdb").exists() else None
                (self.root / marker).touch()
                with self.assertRaisesRegex(RuntimeError, "VDB"):
                    self.run_merge()
                self.assert_preserved()
                (self.root / marker).unlink()

    def test_empty_input_fails(self):
        self.old_output()
        (self.coverage / "vdb" / (self.cfg["base"] + ".vdb") / "data").write_text("")
        with self.assertRaisesRegex(RuntimeError, "nonempty"):
            self.run_merge()
        self.assert_preserved()

    def test_unreadable_vdb_fails(self):
        self.old_output()
        (self.root / "reopen-fail").touch()
        with self.assertRaisesRegex(RuntimeError, "URG failed"):
            self.run_merge()
        self.assert_preserved()

    def test_wrong_parent_and_missing_metrics_fail(self):
        for marker in ("wrong-parent", "missing-metric"):
            with self.subTest(marker=marker):
                (self.root / marker).touch()
                with self.assertRaises(RuntimeError):
                    self.run_merge()
                (self.root / marker).unlink()

    def test_fifo_warning_requires_valid_stage(self):
        (self.root / "fifo-warning").touch()
        self.run_merge()
        audit = json.loads((self.coverage / "mapping" / "mapping-audit.json").read_text())
        self.assertEqual(audit[2]["classification"], "validated-no-fsm")
        self.assertTrue(audit[2]["diagnostics"])
        (self.root / "empty-fifo-stage").touch()
        with self.assertRaisesRegex(RuntimeError, "nonempty"):
            self.run_merge()

    def test_stage_reopen_and_metric_loss_fail_before_next_merge(self):
        for marker in ("stage-read-fail", "stage-missing-metric"):
            with self.subTest(marker=marker):
                if not (self.coverage / "merged.vdb").exists():
                    self.old_output()
                calls_path = self.root / "calls.jsonl"
                if calls_path.exists():
                    calls_path.unlink()
                (self.root / marker).touch()
                with self.assertRaises(RuntimeError):
                    self.run_merge()
                self.assert_preserved()
                calls = [json.loads(s) for s in calls_path.read_text().splitlines()]
                self.assertEqual(sum("-mapfile" in c for c in calls), 1)
                (self.root / marker).unlink()

    def test_diagnostic_blocks_do_not_mask_other_errors(self):
        from unittest.mock import patch
        import subprocess
        fifo = self.coverage / "vdb" / "tb_dma_data_fifo.vdb"
        warning = ("Warning-[UCAPI-SNF] Shape Not Found\n"
                   "'Fsm' coverage shape is not there in the vdb '" + str(fifo) + "'\n")
        cases = [
            ("Warning-[SHAPEMISMATCH] incompatible\n", None),
            (warning + "Error-[TEST] invalid\n", fifo),
            (warning.replace("'Fsm'", "'Line'"), fifo),
            (warning.replace("tb_dma_data_fifo.vdb", "other.vdb"), fifo),
            (warning, None),
        ]
        for stdout, allowed in cases:
            with self.subTest(stdout=stdout), patch("coverage_merge.subprocess.run",
                    return_value=subprocess.CompletedProcess([], 0, stdout)):
                with self.assertRaisesRegex(RuntimeError, "diagnostic"):
                    run_urg([], self.root / "diagnostic.log", fsm_free_vdb=allowed)
        with patch("coverage_merge.subprocess.run",
                   return_value=subprocess.CompletedProcess([], 0, warning)):
            self.assertEqual(len(run_urg([], self.root / "candidate.log", fsm_free_vdb=fifo)), 1)

if __name__ == "__main__":
    unittest.main(verbosity=2)
