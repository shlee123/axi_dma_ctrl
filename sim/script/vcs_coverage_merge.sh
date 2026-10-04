#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COV_DIR="$ROOT_DIR/coverage"
VDB_DIR="$COV_DIR/vdb"
MERGED="$COV_DIR/merged.vdb"
REPORT="$COV_DIR/report"

mapfile -t DB_LIST < <(find "$VDB_DIR" -mindepth 1 -maxdepth 1 -type d -name '*.vdb' | sort)

if [ "${#DB_LIST[@]}" -eq 0 ]; then
    echo "ERROR: no VCS coverage databases found under $VDB_DIR"
    exit 2
fi

rm -rf "$MERGED" "$REPORT"
mkdir -p "$REPORT"

echo "Merging ${#DB_LIST[@]} coverage databases"
urg -full64 \
    -dir "${DB_LIST[@]}" \
    -dbname "$MERGED" \
    -report "$REPORT"

echo "Merged coverage database: $MERGED"
echo "Coverage report:          $REPORT"
