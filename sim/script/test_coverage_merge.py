#!/usr/bin/env python3
"""Portable merge-contract tests; these do not emulate Synopsys bin semantics."""
import contextlib
import copy
import io
import json
from pathlib import Path
import tempfile
import unittest
from coverage_merge import CONFIG, merge, plan
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
    pathlib.Path(a[a.index("-dbname") + 1] + ".vdb").mkdir()
if "-report" in a:
    report = pathlib.Path(a[a.index("-report") + 1])
    report.mkdir(exist_ok=True)
    (report / "dashboard.html").write_text("stub report; no coverage scores")
    if not (root / "missing-hierarchy").exists():
        cfg = json.loads((root / "config.json").read_text())
        names = [cfg["base"], cfg["dut"]] + [u["instance"] for u in cfg["units"]]
        (report / "hierarchy.txt").write_text("\n".join(names))
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
            (self.coverage / "vdb" / (t + ".vdb")).mkdir()
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
        self.assertEqual(len(calls), 9)
        stages = plan(self.cfg)
        for call, (test, module, source, destination) in zip(calls[:8], stages):
            dirs = call[call.index("-dir") + 1:call.index("-mapfile")]
            self.assertTrue(dirs[1].endswith(test + ".vdb"))
            self.assertNotIn("-flex_merge", call)
            maps = list((self.coverage / "mapping").glob("*-" + test + ".map"))
            self.assertEqual(len(maps), 1)
            text = maps[0].read_text()
            self.assertIn("MODULE: " + module, text)
            self.assertIn("SRC: " + source, text)
            self.assertIn("DST: " + destination, text)
        self.assertTrue(calls[0][calls[0].index("-dir") + 1].endswith(self.cfg["base"] + ".vdb"))
        self.assertTrue((self.coverage / "merged.vdb").is_dir())
        self.assertTrue((self.coverage / "report" / "dashboard.html").is_file())
        self.assertEqual(len(list(self.coverage.glob("*.vdb"))), 1)
        self.assertEqual(len(json.loads((self.coverage / "mapping" / "mapping-audit.json").read_text())), 8)

    def test_missing_database_preserves_report(self):
        self.old_output()
        (self.coverage / "vdb" / (self.cfg["base"] + ".vdb")).rmdir()
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

if __name__ == "__main__":
    unittest.main(verbosity=2)
