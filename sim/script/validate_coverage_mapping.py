#!/usr/bin/env python3
"""Validate configured mapping paths against RTL and optionally elaborate them."""
import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile
from coverage_merge import CONFIG, SIM, plan

def instance(text, module, name):
    text = re.sub(r"//[^\n]*|/\*.*?\*/", "", text, flags=re.S)
    # Locate a declaration, then skip its balanced parameter expression.
    for match in re.finditer(r"\b" + re.escape(module) + r"\b", text):
        rest = text[match.end():].lstrip()
        if rest.startswith("#"):
            rest = rest[1:].lstrip()
            if not rest.startswith("("):
                continue
            depth, end = 0, None
            for index, char in enumerate(rest):
                if char == "(": depth += 1
                if char == ")": depth -= 1
                if depth == 0:
                    end = index + 1
                    break
            if end is None: continue
            rest = rest[end:].lstrip()
        if re.match(re.escape(name) + r"\s*\(", rest):
            return True
    return False

def validate(config, sim=SIM, elaborate=False):
    rtl = sim.parent / "rtl"
    top = (rtl / "axi_dma_ctrl.v").read_text()
    for unit in config["units"]:
        if not instance(top, unit["module"], unit["instance"]):
            raise ValueError("Invalid destination instance: " + unit["instance"])
    tests = [(t, "axi_dma_ctrl") for t in config["top_tests"]]
    tests += [(u["test"], u["module"]) for u in config["units"]]
    for test, module in tests:
        tb = sim / "tb" / (test + ".v")
        if not instance(tb.read_text(), module, config["dut"]):
            raise ValueError("Invalid source DUT: " + test)
        if elaborate:
            paths = [(test + "." + config["dut"], "pclk" if module in
                      ("axi_dma_ctrl", "dma_cdc", "dma_apb_regs") else "clk")]
            if module == "axi_dma_ctrl":
                paths += [(test + "." + config["dut"] + "." + u["instance"], u["port"])
                          for u in config["units"]]
            with tempfile.TemporaryDirectory() as directory:
                probe = Path(directory) / "probe.v"
                probe.write_text("module coverage_mapping_probe;\n" + "\n".join(
                    f"wire p{i} = {path}.{port};" for i, (path, port) in enumerate(paths)
                ) + "\nendmodule\n")
                sources = sorted(rtl.glob("*.v")) if module == "axi_dma_ctrl" else [rtl / (module + ".v")]
                subprocess.run(["iverilog", "-g2012", "-I", str(rtl), "-s", test,
                                "-s", "coverage_mapping_probe", "-o", str(Path(directory) / "probe.vvp"),
                                *map(str, sources), str(tb), str(probe)], check=True)
    for test, module, source, destination in plan(config):
        print(f"{module}: {source} -> {destination}")
    print("Mapping paths verified" + (" with Icarus elaboration" if elaborate else " against source"))
    print("URG VDB shape compatibility must also pass in the Synopsys environment.")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--elaborate", action="store_true")
    args = parser.parse_args()
    validate(json.loads(CONFIG.read_text()), elaborate=args.elaborate)
