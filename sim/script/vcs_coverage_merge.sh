#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COV_DIR="${COV_DIR:-$ROOT_DIR/coverage}"
VDB_DIR="$COV_DIR/vdb"
MERGED="$COV_DIR/merged.vdb"
REPORT="$COV_DIR/report"
MAP_FILE="${COV_MAP_FILE:-$COV_DIR/axi_dma_ctrl.map}"
BASE_TEST="${COV_BASE_TEST:-tb_axi_dma_ctrl_smoke}"
UNIT_TESTS="${COV_UNIT_TESTS:-tb_dma_data_fifo tb_dma_read_engine tb_dma_write_engine tb_dma_ctrl tb_dma_cdc tb_dma_apb_regs}"
TOP_TESTS="${COV_TOP_TESTS:-tb_axi_dma_ctrl_smoke tb_axi_dma_ctrl_matrix tb_axi_dma_ctrl_error_matrix}"
URG_BIN="${URG:-urg}"
URG_OPTS_VALUE="${URG_OPTS:--full64}"
EXPECTED_VERSION="${URG_EXPECTED_VERSION:-V-2023.12-SP2-6}"
ELFILE="${COV_ELFILE:-}"

mode="merge"
case "${1:-}" in
    "") ;;
    --check-only) mode="check" ;;
    --dry-run) mode="dry-run" ;;
    *) echo "ERROR: unsupported option '$1'"; exit 2 ;;
esac

read -r -a unit_tests <<< "$UNIT_TESTS"
read -r -a top_tests <<< "$TOP_TESTS"
all_tests=("${unit_tests[@]}" "${top_tests[@]}")

base_found=0
for test in "${top_tests[@]}"; do
    if [ "$test" = "$BASE_TEST" ]; then
        base_found=1
        break
    fi
done
if [ "$base_found" -ne 1 ]; then
    echo "ERROR: COV_BASE_TEST=$BASE_TEST is not listed in COV_TOP_TESTS"
    exit 2
fi

missing=0
if [ "$mode" != "dry-run" ]; then
    for test in "${all_tests[@]}"; do
        db="$VDB_DIR/$test.vdb"
        if [ ! -d "$db" ]; then
            echo "ERROR: missing coverage database: $db"
            missing=$((missing + 1))
        fi
    done
    if [ "$missing" -ne 0 ]; then
        echo "ERROR: $missing of ${#all_tests[@]} required coverage databases are missing"
        exit 2
    fi
fi

if [ "$mode" = "check" ]; then
    echo "Coverage inputs complete: ${#all_tests[@]} VDBs"
    exit 0
fi

mkdir -p "$(dirname "$MAP_FILE")"
{
    echo "# URG instance map generated for AXI2AXI DMA"
    echo "# source hierarchy: canonical hierarchy"
    for test in "${top_tests[@]}"; do
        if [ "$test" != "$BASE_TEST" ]; then
            echo "$test.dut: $BASE_TEST.dut"
        fi
    done
    echo "tb_dma_data_fifo.dut: $BASE_TEST.dut.u_dma_data_fifo"
    echo "tb_dma_read_engine.dut: $BASE_TEST.dut.u_dma_read_engine"
    echo "tb_dma_write_engine.dut: $BASE_TEST.dut.u_dma_write_engine"
    echo "tb_dma_ctrl.dut: $BASE_TEST.dut.u_dma_ctrl"
    echo "tb_dma_cdc.dut: $BASE_TEST.dut.u_dma_cdc"
    echo "tb_dma_apb_regs.dut: $BASE_TEST.dut.u_dma_apb_regs"
} > "$MAP_FILE"

read -r -a urg_opts <<< "$URG_OPTS_VALUE"
cmd=("$URG_BIN" "${urg_opts[@]}" -dir "$VDB_DIR/$BASE_TEST.vdb")
for test in "${all_tests[@]}"; do
    if [ "$test" != "$BASE_TEST" ]; then
        cmd+=(-dir "$VDB_DIR/$test.vdb")
    fi
done
cmd+=(-mapfile "$MAP_FILE" -dbname "$MERGED" -report "$REPORT")

if [ -n "$ELFILE" ]; then
    if [ ! -f "$ELFILE" ] && [ "$mode" != "dry-run" ]; then
        echo "ERROR: coverage exclusion file not found: $ELFILE"
        exit 2
    fi
    cmd+=(-elfile "$ELFILE")
fi

if [ "$mode" = "dry-run" ]; then
    echo "Generated instance map: $MAP_FILE"
    cat "$MAP_FILE"
    printf 'URG command:'
    printf ' %q' "${cmd[@]}"
    printf '\n'
    exit 0
fi

if ! command -v "$URG_BIN" >/dev/null 2>&1; then
    echo "ERROR: URG executable not found: $URG_BIN"
    exit 2
fi

version_output="$($URG_BIN -version 2>&1 || true)"
if [[ "$version_output" != *"$EXPECTED_VERSION"* ]]; then
    echo "ERROR: expected URG $EXPECTED_VERSION"
    echo "Detected: ${version_output:-<no version output>}"
    exit 2
fi

rm -rf "$MERGED" "$REPORT"
mkdir -p "$REPORT"

echo "URG version: $EXPECTED_VERSION"
echo "Canonical top coverage: $BASE_TEST"
echo "Merging ${#all_tests[@]} coverage databases with instance mapping"
"${cmd[@]}"

if [ ! -d "$MERGED" ]; then
    echo "ERROR: URG completed without creating $MERGED"
    exit 2
fi

echo "Merged coverage database: $MERGED"
echo "Coverage report:          $REPORT"
echo "Instance map:             $MAP_FILE"
