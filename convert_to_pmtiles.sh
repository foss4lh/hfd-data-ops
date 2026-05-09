#!/bin/bash
# Description: Converts a source TIFF to PMTiles format using GDAL.
# PMTiles is excellent for serverless hosting (e.g. S3/R2) without a tile server.
# Requires: GDAL 3.8+ for native PMTiles support.

INPUT_FILE=$1
OUTPUT_FILE=$2

if [ -z "$INPUT_FILE" ] || [ -z "$OUTPUT_FILE" ]; then
    echo "Usage: $0 <input.tif> <output.pmtiles>"
    echo "Example: $0 raw_data/source.tif ../hfd-landscape-explorer/public/tiles/dataset.pmtiles"
    exit 1
fi

echo "Converting $INPUT_FILE to PMTiles format at $OUTPUT_FILE..."

# Reproject to Web Mercator if necessary and output as PMTiles
# NOTE: PMTiles requires Web Mercator (EPSG:3857)
# For optimal cloud serving, add overviews (pyramids).
gdal_translate "$INPUT_FILE" "$OUTPUT_FILE" \
    -of PMTiles \
    -co TILING_SCHEME=GoogleMapsCompatible \
    -co COMPRESS=WEBP

echo "Done! The PMTiles archive can now be served statically."
