#!/usr/bin/env python3
"""
compute_bounds.py — Compute geographic bounds from a Web Mercator XYZ tile pyramid.

Takes a directory of z/x/y.* tiles (as produced by gdal2tiles.py) and computes
the bounding box in WGS84 coordinates. Uses the max-zoom tile indices to get
the tightest bounds.

Usage:
    python3 compute_bounds.py /path/to/tiles
    python3 compute_bounds.py /path/to/tiles --min-zoom 10 --max-zoom 16
"""
import sys
import math
from pathlib import Path


def tile_to_lat(z: int, tms_y: int) -> float:
    """Convert TMS Y tile index to latitude (Web Mercator)."""
    n = math.pi - (2.0 * math.pi * tms_y) / (1 << z)
    return (180.0 / math.pi) * math.atan(0.5 * (math.exp(n) - math.exp(-n)))


def tile_to_lon(z: int, x: int) -> float:
    """Convert tile X index to longitude."""
    return (x / (1 << z)) * 360.0 - 180.0


def tms_y_from_raw(raw_y: int, z: int) -> int:
    """Flip raw y to TMS y."""
    return (1 << z) - 1 - raw_y


def bounds_from_tiles(tile_dir: Path, min_zoom: int = None, max_zoom: int = None):
    """
    Compute geographic bounds from all tiles in an XYZ directory.

    Returns:
        (min_lon, min_lat, max_lon, max_lat), (min_z, max_z), tile_count
    """
    exts = ['.png', '.jpg', '.jpeg', '.webp']

    # Collect tiles per zoom level
    tiles_by_zoom = {}
    all_tile_count = 0

    for z_dir in sorted(tile_dir.iterdir(), key=lambda p: int(p.name) if p.name.isdigit() else 0):
        if not z_dir.is_dir() or not z_dir.name.isdigit():
            continue
        z = int(z_dir.name)
        if min_zoom is not None and z < min_zoom:
            continue
        if max_zoom is not None and z > max_zoom:
            continue

        tiles_by_zoom[z] = {'x': [], 'y_raw': []}

        for x_dir in sorted(z_dir.iterdir(), key=lambda p: int(p.name) if p.name.isdigit() else 0):
            if not x_dir.is_dir() or not x_dir.name.isdigit():
                continue
            x = int(x_dir.name)
            for tile_file in x_dir.iterdir():
                if tile_file.suffix.lower() not in exts:
                    continue
                try:
                    raw_y = int(tile_file.stem)
                    tiles_by_zoom[z]['x'].append(x)
                    tiles_by_zoom[z]['y_raw'].append(raw_y)
                    all_tile_count += 1
                except ValueError:
                    continue

    if not tiles_by_zoom:
        raise ValueError(f"No tiles found in {tile_dir}")

    min_z = min(tiles_by_zoom.keys())
    max_z = max(tiles_by_zoom.keys())

    # Use max zoom tiles for precise bounds
    max_zoom_data = tiles_by_zoom[max_z]
    raw_x_values = max_zoom_data['x']
    raw_y_values = max_zoom_data['y_raw']

    min_x = min(raw_x_values)
    max_x = max(raw_x_values)
    min_raw_y = min(raw_y_values)  # smallest raw = topmost tile
    max_raw_y = max(raw_y_values)  # largest raw = bottommost tile

    # Convert to TMS Y
    min_tms_y = tms_y_from_raw(min_raw_y, max_z)  # top edge of bbox
    max_tms_y = tms_y_from_raw(max_raw_y, max_z)  # bottom edge of bbox

    # Geographic bounds
    min_lon = tile_to_lon(max_z, min_x)
    max_lon = tile_to_lon(max_z, max_x + 1)  # right edge = next tile
    max_lat = tile_to_lat(max_z, min_tms_y)   # top edge of bbox
    min_lat = tile_to_lat(max_z, max_tms_y)   # bottom edge of bbox

    return (min_lon, min_lat, max_lon, max_lat), (min_z, max_z), all_tile_count


def main():
    import argparse
    parser = argparse.ArgumentParser(description='Compute bounds from XYZ tile directory')
    parser.add_argument('tile_dir', help='Path to tiles directory (z/x/y.png)')
    parser.add_argument('--min-zoom', type=int, default=None)
    parser.add_argument('--max-zoom', type=int, default=None)
    args = parser.parse_args()

    tile_dir = Path(args.tile_dir)
    if not tile_dir.exists():
        print(f"Error: {tile_dir} not found")
        sys.exit(1)

    bounds, zoom_range, count = bounds_from_tiles(
        tile_dir, args.min_zoom, args.max_zoom
    )
    min_lon, min_lat, max_lon, max_lat = bounds
    min_z, max_z = zoom_range

    print(f"Tile count: {count}")
    print(f"Zoom range: {min_z} - {max_z}")
    print(f"Bounds (lon/lat): {min_lon:.6f}, {min_lat:.6f}, {max_lon:.6f}, {max_lat:.6f}")
    print(f"Bounds string: {min_lon:.3f},{min_lat:.3f},{max_lon:.3f},{max_lat:.3f}")
    center_z = (min_z + max_z) // 2 + 1
    center_lon = (min_lon + max_lon) / 2
    center_lat = (min_lat + max_lat) / 2
    print(f"Center: {center_lon:.6f},{center_lat:.6f},{center_z}")
    print()
    print("For metadata.json:")
    print(f'  "minzoom": {min_z},')
    print(f'  "maxzoom": {max_z},')
    print(f'  "bounds": "{min_lon:.3f},{min_lat:.3f},{max_lon:.3f},{max_lat:.3f}",')
    print(f'  "center": "{center_lon:.3f},{center_lat:.3f},{center_z}"')


if __name__ == '__main__':
    main()