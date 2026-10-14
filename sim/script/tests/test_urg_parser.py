#!/usr/bin/env python3
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from coverage_merge import hierarchy_metrics, run_urg

REPORT = """Design Hierarchy
SCORE LINE COND TOGGLE FSM BRANCH
49.62 78.36 60.42 10.40 39.53 59.36 tb_axi_dma_ctrl_smoke
  SCORE LINE COND TOGGLE FSM BRANCH
  50.22 75.42 61.32 14.62 39.53 60.20 dut
    SCORE LINE COND TOGGLE FSM BRANCH
    44.83 64.81 61.19 9.94 36.36 51.85 u_dma_data_fifo
    68.27 84.09 73.68 33.81 -- 81.48 u_dma_read_engine
"""
class ParserTests(unittest.TestCase):
    def parse(self, data=REPORT):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)
            (p / "hierarchy.txt").write_text(data)
            return hierarchy_metrics(p, ["tb_axi_dma_ctrl_smoke.dut",
                "tb_axi_dma_ctrl_smoke.dut.u_dma_data_fifo",
                "tb_axi_dma_ctrl_smoke.dut.u_dma_read_engine"])
    def test_real_urg_table(self):
        rows = self.parse()
        self.assertEqual(rows["tb_axi_dma_ctrl_smoke.dut"]["LINE"], 75.42)
        self.assertIsNone(rows["tb_axi_dma_ctrl_smoke.dut.u_dma_read_engine"]["FSM"])
    def test_missing_instance_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Missing canonical"):
            self.parse(REPORT.replace("u_dma_data_fifo", "other"))
    def test_invalid_metric_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Unrecognized"):
            self.parse(REPORT.replace("75.42", "bogus"))
    def test_duplicate_instance_fails(self):
        with self.assertRaisesRegex(RuntimeError, "Duplicate"):
            self.parse(REPORT + "    SCORE LINE COND TOGGLE FSM BRANCH\n    44.83 64.81 61.19 9.94 36.36 51.85 u_dma_data_fifo\n")
if __name__ == "__main__":
    unittest.main()
