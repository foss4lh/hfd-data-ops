#!/bin/bash
# =============================================================================
# Whitby tithe map PMTiles conversion — FULLY WORKING PIPELINE
# =============================================================================
# Input:  WhitbTM.ecw (georeferenced, OSGB 1936 / British National Grid)
# Step 1: Generate XYZ tile pyramid via gdal2tiles.py in Docker
# Step 2: Compute bounds from tile indices
# Step 3: Create metadata.json
# Step 4: Convert XYZ → PMTiles
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCHIVE_DIR="/media/robin/foss4lh/david-lovelace-archive/Maps"
ECW_FILE="${ARCHIVE_DIR}/WhitbTM.ecw"
TILE_DIR="/tmp/whitby-tiles"
OUTPUT_DIR="${SCRIPT_DIR}"
PMTILES_FILE="${OUTPUT_DIR}/whitby-tithe.pmtiles"

# Zoom range
ZMIN=10
ZMAX=16

echo "=== Whitby Tithe Map → PMTiles ==="
echo "Input: $ECW_FILE"

# ---------------------------------------------------------------------------
# Step 1: Generate XYZ tiles
# ---------------------------------------------------------------------------
echo ""
echo "[Step 1] Generating XYZ tile pyramid (zoom $ZMIN-$ZMAX)..."

rm -rf "$TILE_DIR"
mkdir -p "$TILE_DIR"

docker run --rm \
    -v "${ARCHIVE_DIR}:/data:ro" \
    -v "${TILE_DIR}:/out" \
    ginetto/gdal:2.4.4_ECW \
    gdal2tiles.py \
        -p mercator \
        -s EPSG:27700 \
        -z "${ZMIN}-${ZMAX}" \
        --processes 4 \
        -v \
        "/data/WhitbTM.ecw" \
        /out 2>&1 | grep -E "Generating|Base Tiles|Overview|Error|error" | head -20

N_TILES=$(find "$TILE_DIR" -name "*.png" | wc -l)
echo "  → $N_TILES tiles generated (zoom $ZMIN-$ZMAX)"

# ---------------------------------------------------------------------------
# Step 2: Compute geographic bounds from tile indices
# ---------------------------------------------------------------------------
echo ""
echo "[Step 2] Computing bounds..."

BOUNDS=$(python3 "${SCRIPT_DIR}/compute_bounds.py" "$TILE_DIR" --min-zoom "$ZMIN" --max-zoom "$ZMAX" 2>&1 | grep "Bounds string" | sed 's/.*: //')
CENTER=$(python3 "${SCRIPT_DIR}/compute_bounds.py" "$TILE_DIR" --min-zoom "$ZMIN" --max-zoom "$ZMAX" 2>&1 | grep "^Center:" | sed 's/Center: //')
echo "  Bounds: $BOUNDS"
echo "  Center: $CENTER"

# ---------------------------------------------------------------------------
# Step 3: Create metadata.json
# ---------------------------------------------------------------------------
echo ""
echo "[Step 3] Writing metadata.json..."

cat > "${TILE_DIR}/metadata.json" << EOF
{
  "name": "Whitby Tithe Map",
  "description": "Georectified tithe map for Whitby, Herefordshire — WhitbTM.ecw",
  "version": "1.0",
  "format": "jpeg",
  "minzoom": ${ZMIN},
  "maxzoom": ${ZMAX},
  "bounds": "${BOUNDS}",
  "center": "${CENTER}"
}
EOF

# ---------------------------------------------------------------------------
# Step 4: Convert XYZ → PMTiles (JPEG tiles stored as PNG from gdal2tiles)
# ---------------------------------------------------------------------------
echo ""
echo "[Step 4] Converting XYZ → PMTiles..."

python3 << 'PYEOF'
import sys
import os
import json
from pathlib import Path
from pmtiles.tile import TileType, zxy_to_tileid, Compression
from pmtiles.writer import write as pmtiles_write

tile_dir = Path("/tmp/whitby-tiles")
output = "/home/robin/github/foss4lh/hfd-data-ops/tithe-pmtiles/whitby-tithe.pmtiles"

with open(tile_dir / "metadata.json") as f:
    metadata = json.load(f)

# gdal2tiles outputs PNG
tile_ext = ".png"
fmt = "png"

print(f"  Reading tiles from {tile_dir}")
print(f"  Format: {fmt}")

# Collect all tiles
tileid_path_pairs = []
for z_dir in sorted(tile_dir.iterdir(), key=lambda p: int(p.name) if p.name.isdigit() else 0):
    if not z_dir.name.isdigit():
        continue
    z = int(z_dir.name)
    for x_dir in sorted(z_dir.iterdir(), key=lambda p: int(p.name) if p.name.isdigit() else 0):
        if not x_dir.name.isdigit():
            continue
        x = int(x_dir.name)
        for tile_file in x_dir.iterdir():
            if tile_file.suffix.lower() == tile_ext:
                y = int(tile_file.stem)
                tileid = zxy_to_tileid(z, x, y)
                tileid_path_pairs.append((tileid, tile_file))

tileid_path_pairs.sort(key=lambda x: x[0])
print(f"  Found {len(tileid_path_pairs)} tiles")

# Determine tile type
tile_type = TileType.PNG if fmt == "png" else TileType.JPEG

# Write PMTiles
with pmtiles_write(output) as writer:
    for tileid, tile_path in tileid_path_pairs:
        with open(tile_path, 'rb') as f:
            data = f.read()
        writer.write_tile(tileid, data)

    # Build header
    bounds_str = metadata['bounds']
    min_lon, min_lat, max_lon, max_lat = [float(x.strip()) for x in bounds_str.split(',')]
    center_str = metadata['center']
    center_lon, center_lat, center_z = [float(x.strip()) for x in center_str.split(',')]

    header = {
        'min_zoom': int(metadata['minzoom']),
        'max_zoom': int(metadata['maxzoom']),
        'min_lon_e7': int(min_lon * 1e7),
        'min_lat_e7': int(min_lat * 1e7),
        'max_lon_e7': int(max_lon * 1e7),
        'max_lat_e7': int(max_lat * 1e7),
        'tile_type': TileType.PNG,
        'tile_compression': Compression.NONE,
        'internal_compression': Compression.NONE,
        'clustered': True,
        'center_zoom': int(metadata['minzoom']) + 2,
        'center_lon_e7': int(center_lon * 1e7),
        'center_lat_e7': int(center_lat * 1e7),
    }

    pmtiles_metadata = dict(metadata)
    writer.finalize(header, pmtiles_metadata)

size_mb = os.path.getsize(output) / 1024 / 1024
print(f"  → Wrote {output}")
print(f"  → Size: {size_mb:.1f} MB")
print(f"  → Tiles: {len(tileid_path_pairs)}")
PYEOF

echo ""
echo "=== Done ==="
ls -lh "${SCRIPT_DIR}/whitby-tithe.pmtiles"