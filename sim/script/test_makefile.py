#!/usr/bin/env python3
"""Run real Make recipes against deterministic licensed-tool substitutes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1] / "Makefile"
TEST = "tb_dma_data_fifo"
STUB = r"""#!/usr/bin/env python3
import os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with open(os.environ["CALLS"], "a") as f:
    f.write(name + " " + " ".join(args) + "\n")
if name in ("vcs", "iverilog"):
    rc = int(os.environ.get("COMPILE_RC", "0"))
    if rc: sys.exit(rc)
    out = pathlib.Path(args[args.index("-o") + 1])
    if name == "vcs":
        out.write_text(pathlib.Path(__file__).read_text())
        out.chmod(0o755)
        pathlib.Path(str(out) + ".daidir").mkdir(exist_ok=True)
elif name.startswith("simv_") or name == "vvp":
    text = "PASS tb_dma_data_fifo\n" if os.environ["STUB_PASS"] == "1" else "no marker\n"
    print(text, end="")
    if "-l" in args:
        pathlib.Path(args[args.index("-l") + 1]).write_text(text)
    for arg in args:
        if arg.startswith("+FSDB_FILE="): pathlib.Path(arg.split("=", 1)[1]).touch()
    sys.exit(int(os.environ["STUB_RC"]))
"""

class MakefileSmoke(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copyfile(SOURCE, self.root / "Makefile")
        (self.root / "tb").mkdir()
        (self.root / "tb" / (TEST + ".v")).touch()
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        self.env = dict(os.environ, PATH=str(bin_dir) + os.pathsep + os.environ["PATH"],
                        CALLS=str(self.root / "calls"), STUB_RC="0", STUB_PASS="1")
        for name in ("vcs", "verdi", "iverilog", "vvp"):
            p = bin_dir / name
            p.write_text(STUB)
            p.chmod(0o755)

    def run_make(self, *args, input=""):
        return subprocess.run(["make", "--no-print-directory", *args], cwd=self.root,
                              env=self.env, input=input, text=True,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=20)

    def calls(self):
        p = self.root / "calls"
        return p.read_text().splitlines() if p.exists() else []

    def clear_calls(self):
        (self.root / "calls").unlink(missing_ok=True)

    def assert_ok(self, r):
        self.assertEqual(r.returncode, 0, r.stdout)
        self.assertNotIn("missing tb/.v", r.stdout)

    def test_interactive_and_explicit_vcs(self):
        for args, selection in [(("run",), "1\n"), (("run", "TEST=" + TEST), "")]:
            self.clear_calls()
            r = self.run_make(*args, input=selection)
            self.assert_ok(r)
            self.assertEqual([c.split()[0] for c in self.calls()], ["vcs", "simv_" + TEST])
            if selection:
                self.assertIn("  1) " + TEST + "\n", r.stdout)

    def test_invalid_and_eof_selections(self):
        for target in ("run", "run_verdi"):
            for value in ("", "\n", "0\n", "10\n", "abc\n", "1;echo bad\n",
                          "9999999999999999999999999999\n"):
                with self.subTest(target=target, value=value):
                    r = self.run_make(target, input=value)
                    self.assertNotEqual(r.returncode, 0, r.stdout)
                    self.assertNotIn("missing tb/.v", r.stdout)
                    self.assertEqual(self.calls(), [])

    def test_vcs_runtime_failure_even_with_pass(self):
        self.env["STUB_RC"] = "7"
        for args, selection in [(("run", "TEST=" + TEST), ""), (("run",), "1\n")]:
            r = self.run_make(*args, input=selection)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertIn("VCS runtime exit=7", r.stdout)
            self.assertNotIn("===== PASS", r.stdout)

    def test_vcs_missing_pass(self):
        self.env["STUB_PASS"] = "0"
        r = self.run_make("run", "TEST=" + TEST)
        self.assertNotEqual(r.returncode, 0, r.stdout)
        self.assertIn("PASS marker not found", r.stdout)

    def test_compile_failure_stops_runtime(self):
        self.env["COMPILE_RC"] = "9"
        for sim in ("vcs", "iverilog"):
            self.clear_calls()
            r = self.run_make("run", "TEST=" + TEST, "SIMULATOR=" + sim)
            self.assertNotEqual(r.returncode, 0, r.stdout)
            self.assertEqual([c.split()[0] for c in self.calls()], [sim])

    def test_iverilog_interactive_and_failure(self):
        self.assert_ok(self.run_make("run", "SIMULATOR=iverilog", input="1\n"))
        self.assertEqual([c.split()[0] for c in self.calls()], ["iverilog", "vvp"])
        for rc, marker in [("7", "1"), ("0", "0")]:
            self.env.update(STUB_RC=rc, STUB_PASS=marker)
            r = self.run_make("run", "TEST=" + TEST, "SIMULATOR=iverilog")
            self.assertNotEqual(r.returncode, 0, r.stdout)

    def test_missing_test_and_unsupported_simulator(self):
        r = self.run_make("run", "TEST=absent")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("missing tb/absent.v", r.stdout)
        r = self.run_make("run", "TEST=" + TEST, "SIMULATOR=unsupported")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("unsupported SIMULATOR", r.stdout)
        self.assertEqual(self.calls(), [])

    def test_verdi_prerequisites_and_launch(self):
        r = self.run_make("run_verdi", input="1\n")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("run VCS simulation first", r.stdout)
        (self.root / "fsdb" / (TEST + ".fsdb")).touch()
        r = self.run_make("run_verdi", "TEST=" + TEST)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("rerun VCS with -kdb first", r.stdout)
        (self.root / "build" / ("simv_" + TEST + ".daidir")).mkdir()
        for args, selection in [(("run_verdi",), "1\n"),
                                (("run_verdi", "TEST=" + TEST), "")]:
            self.clear_calls()
            self.assert_ok(self.run_make(*args, input=selection))
            self.assertEqual(len(self.calls()), 1)
            self.assertIn("-dbdir build/simv_" + TEST + ".daidir", self.calls()[0])
            self.assertIn("-ssf fsdb/" + TEST + ".fsdb", self.calls()[0])

    def test_regression_aggregates_failure(self):
        self.assert_ok(self.run_make("regression", "TESTS=" + TEST))
        self.env["STUB_RC"] = "7"
        r = self.run_make("regression", "TESTS=" + TEST + " absent")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("FAIL: " + TEST, r.stdout)
        self.assertIn("FAIL: absent", r.stdout)
        self.assertIn("REGRESSION FAIL: 2 test(s) failed", r.stdout)

    def test_phony_run_targets(self):
        for name in ("run", "run-vcs", "run-iverilog", "run_verdi"):
            (self.root / name).touch()
        self.assert_ok(self.run_make("run", "TEST=" + TEST))
        self.assertEqual(len(self.calls()), 2)

    def test_coverage_nonexecutable_script(self):
        (self.root / "script").mkdir()
        p = self.root / "script" / "vcs_coverage_merge.sh"
        p.write_text('#!/bin/bash\necho coverage >> "$CALLS"\nexit 6\n')
        p.chmod(0o644)
        r = self.run_make("coverage-merge")
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(self.calls(), ["coverage"])

if __name__ == "__main__":
    unittest.main(verbosity=2)
