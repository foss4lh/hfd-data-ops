#!/bin/bash
# =============================================================================
# convert_to_pmtiles.sh — Generate PMTiles from georeferenced raster ECW/TIFF
# =============================================================================
# Usage:
#   ./convert_to_pmtiles.sh <input_file> <dataset_name> <output_dir>
#   Example: ./convert_to_pmtiles.sh WhitbTM.ecw "Whitby Tithe Map" ./output
#
# Requirements (Docker):
#   docker pull ginetto/gdal:2.4.4_ECW
#
# Requirements (host):
#   pip install pmtiles
#
# Steps:
#   1. Generate XYZ tile pyramid with gdal2tiles.py (via Docker)
#   2. Create metadata.json for the tile directory
#   3. Convert XYZ tiles → PMTiles using pmtiles Python API
#   4. Output .pmtiles file ready for web serving
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
if [ "$#" -lt 3 ]; then
    echo "Usage: $0 <input_file> <dataset_name> <output_dir> [zoom_min] [zoom_max]"
    echo "  input_file   : Path to georeferenced raster (ECW, GeoTIFF, etc.)"
    echo "  dataset_name : Human-readable name for metadata"
    echo "  output_dir   : Directory to write PMTiles output"
    echo "  zoom_min     : Minimum zoom level (default: 10)"
    echo "  zoom_max     : Maximum zoom level (default: 16)"
    exit 1
fi

INPUT_FILE="$1"
DATASET_NAME="$2"
OUTPUT_DIR="$3"
ZOOM_MIN="${4:-10}"
ZOOM_MAX="${5:-16}"

# ---------------------------------------------------------------------------
# Validate
# ---------------------------------------------------------------------------
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: input file not found: $INPUT_FILE"
    exit 1
fi

INPUT_EXT="${INPUT_FILE##*.}"
if [[ ! "$INPUT_EXT" =~ ^(ecw|tif|tiff|gtif)$ ]]; then
    echo "Error: input must be .ecw, .tif/.tiff, or .gtif (georeferenced raster)"
    exit 1
fi

# ---------------------------------------------------------------------------
# Detect SRS from input (via Docker)
# ---------------------------------------------------------------------------
echo "[1/4] Detecting spatial reference system..."
SRS=$(docker run --rm \
    -v "$(dirname "$INPUT_FILE"):/data:ro" \
    ginetto/gdal:2.4.4_ECW \
    gdalinfo "/data/$(basename "$INPUT_FILE")" 2>/dev/null \
    | grep "PROJCS\[" \
    | head -1 \
    | grep -oP '"\K[^"]+' \
    | head -1)

if [ -z "$SRS" ]; then
    echo "Warning: Could not detect SRS, assuming EPSG:27700 (British National Grid)"
    SRS="EPSG:27700"
fi
echo "  SRS: $SRS"

# Map SRS to EPSG for gdal2tiles
if [[ "$SRS" == *"British National Grid"* ]] || [[ "$SRS" == *"OSGB 1936"* ]]; then
    SOURCE_EPSG="EPSG:27700"
elif [[ "$SRS" == *"WGS 84"* ]] || [[ "$SRS" == *"EPSG:4326"* ]]; then
    SOURCE_EPSG="EPSG:4326"
else
    SOURCE_EPSG="EPSG:27700"  # safe default for UK historic maps
fi
echo "  Source EPSG: $SOURCE_EPSG"

# ---------------------------------------------------------------------------
# Generate XYZ tiles with gdal2tiles.py
# ---------------------------------------------------------------------------
TILE_DIR="${OUTPUT_DIR}/tiles"
METADATA_FILE="${TILE_DIR}/metadata.json"

mkdir -p "$TILE_DIR"

echo "[2/4] Generating XYZ tiles (zoom $ZOOM_MIN-$ZOOM_MAX)..."
echo "  Source: $INPUT_FILE"

docker run --rm \
    -v "$(dirname "$INPUT_FILE"):/data:ro" \
    -v "$(realpath "$TILE_DIR"):/out" \
    ginetto/gdal:2.4.4_ECW \
    gdal2tiles.py \
        -p mercator \
        -s "$SOURCE_EPSG" \
        -z "${ZOOM_MIN}-${ZOOM_MAX}" \
        --processes 4 \
        -v \
        "/data/$(basename "$INPUT_FILE")" \
        /out 2>&1 | tail -10

# Count tiles
N_TILES=$(find "$TILE_DIR" -name "*.png" | wc -l)
echo "  Generated $N_TILES tiles"

# ---------------------------------------------------------------------------
# Create metadata.json for pmtiles Python API
# ---------------------------------------------------------------------------
echo "[3/4] Creating metadata.json..."

# Get bounds from gdal2tiles output or compute from tile indices
# Use tile_to_bounds logic from Python (see compute_bounds.py)
TILE_SIZE_MB=$(du -sm "$TILE_DIR" | cut -f1)

# For Whitby example: bounds from gdal2tiles were approx
# -2.505, 52.174, -2.371, 52.236
# You'll want to replace this with actual computed bounds or extract from
# gdalinfo output. The Python helper script handles this properly.

# For now, write a placeholder — replace with actual bounds
BOUNDS="${BOUNDS:--2.505,52.174,-2.371,52.236}"
CENTER_LON=$(echo "$BOUNDS" | cut -d',' -f1)
CENTER_LAT=$(echo "$BOUNDS" | cut -d',' -f2)

cat > "$METADATA_FILE" << EOF
{
  "name": "${DATASET_NAME}",
  "description": "${DATASET_NAME} — generated from $(basename "$INPUT_FILE")",
  "version": "1.0",
  "format": "jpeg",
  "minzoom": ${ZOOM_MIN},
  "maxzoom": ${ZOOM_MAX},
  "bounds": "${BOUNDS}",
  "center": "${CENTER_LON},${CENTER_LAT},$(( (ZOOM_MIN + ZOOM_MAX) / 2 + 1 ))"
}
EOF

echo "  Written: $METADATA_FILE"

# ---------------------------------------------------------------------------
# Convert XYZ → PMTiles using Python pmtiles API
# ---------------------------------------------------------------------------
PMTILES_FILE="${OUTPUT_DIR}/${DATASET_NAME// /-}.pmtiles"
PMTILES_FILE="${PMTILES_FILE,,}"  # lowercase

echo "[4/4] Converting XYZ tiles → PMTiles..."
python3 << EOF
import sys
import os
import json
from pathlib import Path
from pmtiles.tile import TileType, zxy_to_tileid
from pmtiles.writer import write as pmtiles_write

tile_dir = Path("$TILE_DIR")
output = "$PMTILES_FILE"

# Load metadata
with open("$METADATA_FILE") as f:
    metadata = json.load(f)

# Detect tile format
exts = ['.png', '.jpg', '.jpeg']
tile_ext = None
for e in exts:
    if next(tile_dir.rglob(f'*{e}'), None):
        tile_ext = e
        break

if not tile_ext:
    print(f"No tiles found in {tile_dir}")
    sys.exit(1)

print(f"Tile format: {tile_ext}")

# Collect all tiles sorted by tileid
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
            if tile_file.suffix.lower() not in exts:
                continue
            y = int(tile_file.stem)
            tileid = zxy_to_tileid(z, x, y)
            tileid_path_pairs.append((tileid, tile_file))

tileid_path_pairs.sort(key=lambda x: x[0])
print(f"Found {len(tileid_path_pairs)} tiles")

# Map format to TileType
fmt = metadata.get('format', 'jpeg').lower()
if fmt == 'png':
    tile_type = TileType.PNG
elif fmt in ('jpeg', 'jpg'):
    tile_type = TileType.JPEG
elif fmt == 'webp':
    tile_type = TileType.WEBP
else:
    tile_type = TileType.PNG

# Write PMTiles
with pmtiles_write(output) as writer:
    for tileid, tile_path in tileid_path_pairs:
        with open(tile_path, 'rb') as f:
            data = f.read()
        writer.write_tile(tileid, data)
    
    # Build header
    bounds_str = metadata.get('bounds', '-180,-85.05,180,85.05')
    min_lon, min_lat, max_lon, max_lat = [float(x.strip()) for x in bounds_str.split(',')]
    
    header = {
        'min_zoom': int(metadata.get('minzoom', $ZOOM_MIN)),
        'max_zoom': int(metadata.get('maxzoom', $ZOOM_MAX)),
        'min_lon_e7': int(min_lon * 1e7),
        'min_lat_e7': int(min_lat * 1e7),
        'max_lon_e7': int(max_lon * 1e7),
        'max_lat_e7': int(max_lat * 1e7),
        'tile_type': tile_type,
        'tile_compression': 0,  # NONE for JPEG/PNG
        'internal_compression': 0,
        'clustered': True,
        'center_zoom': int(metadata.get('minzoom', $ZOOM_MIN)),
    }
    
    pmtiles_header, pmtiles_metadata = metadata.copy(), metadata.copy()
    for k, v in header.items():
        pmtiles_header[k] = v
    
    writer.finalize(pmtiles_header, pmtiles_metadata)

size_mb = os.path.getsize(output) / 1024 / 1024
print(f"Wrote {output} ({size_mb:.1f} MB, {len(tileid_path_pairs)} tiles)")
EOF

echo "Done: $PMTILES_FILE"
echo ""
echo "To serve on Netlify:"
echo "  1. Upload $PMTILES_FILE to a GitHub Release asset"
echo "  2. Add to build.sh: curl -L -o dataset.pmtiles <release_url>"
echo "  3. Add PMTiles source to App.svelte via OpenLayers PMTiles source"