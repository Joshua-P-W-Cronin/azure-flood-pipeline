"""Load Environment Agency flood-area polygons into Azure SQL as geography.

Usage (from the python/ folder):  uv run load_flood_areas.py
Settings come from a .env file in the same folder.
"""
from __future__ import annotations

import os
import sys
import time
from datetime import datetime, timezone

import pyodbc
import requests
from dotenv import load_dotenv
from shapely.geometry import MultiPolygon, Polygon, shape
from shapely.geometry.polygon import orient
from shapely.ops import unary_union
from shapely.validation import make_valid

BASE_URL = "https://environment.data.gov.uk/flood-monitoring"

# One upsert per area. The geography is built server-side from WKT, repaired
# with MakeValid(), and flipped with ReorientObject() if it still covers more
# than a hemisphere (the sign of a ring drawn the wrong way round).
MERGE_SQL = """
SET NOCOUNT ON;
MERGE dw.dim_flood_area AS t
USING (
    SELECT x.area_code, x.label, x.description, x.county, x.river_or_sea,
           x.ea_area_name, x.polygon_url,
           CASE WHEN x.g.EnvelopeAngle() > 90 THEN x.g.ReorientObject() ELSE x.g END AS boundary
    FROM (
        SELECT CAST(? AS nvarchar(50))   AS area_code,
               CAST(? AS nvarchar(400))  AS label,
               CAST(? AS nvarchar(2000)) AS description,
               CAST(? AS nvarchar(400))  AS county,
               CAST(? AS nvarchar(400))  AS river_or_sea,
               CAST(? AS nvarchar(200))  AS ea_area_name,
               CAST(? AS nvarchar(400))  AS polygon_url,
               geography::STGeomFromText(CAST(? AS nvarchar(max)), 4326).MakeValid() AS g
    ) AS x
) AS s
    ON t.area_code = s.area_code
WHEN MATCHED THEN UPDATE SET
    label          = s.label,
    description    = s.description,
    county         = s.county,
    river_or_sea   = s.river_or_sea,
    ea_area_name   = s.ea_area_name,
    polygon_url    = s.polygon_url,
    boundary       = s.boundary,
    updated_at_utc = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET THEN
    INSERT (area_code, label, description, county, river_or_sea, ea_area_name, polygon_url, boundary)
    VALUES (s.area_code, s.label, s.description, s.county, s.river_or_sea, s.ea_area_name, s.polygon_url, s.boundary)
OUTPUT $action;
"""

LOG_SQL = """
INSERT INTO dw.load_log (run_id, step, rows_inserted, rows_updated, rows_rejected)
VALUES (?, ?, ?, ?, ?);
"""


def as_text(value):
    """API fields are sometimes lists; join them so they fit one column."""
    if value is None:
        return None
    if isinstance(value, list):
        return ", ".join(str(v) for v in value)
    return str(value)


def get_json(session: requests.Session, url: str, params: dict | None = None, retries: int = 3):
    """GET with simple exponential backoff, because the API has no uptime guarantee."""
    for attempt in range(1, retries + 1):
        try:
            resp = session.get(url, params=params, timeout=60)
            resp.raise_for_status()
            return resp.json()
        except requests.RequestException as exc:
            if attempt == retries:
                raise
            wait = 2 ** attempt
            print(f"    retry {attempt} after error: {exc} (waiting {wait}s)")
            time.sleep(wait)


def to_polygonal(geojson: dict):
    """Turn GeoJSON (FeatureCollection, Feature or bare geometry) into one Polygon or MultiPolygon."""
    gtype = geojson.get("type")
    if gtype == "FeatureCollection":
        geoms = [shape(f["geometry"]) for f in geojson.get("features", []) if f.get("geometry")]
    elif gtype == "Feature":
        geoms = [shape(geojson["geometry"])] if geojson.get("geometry") else []
    else:
        geoms = [shape(geojson)]

    if not geoms:
        return None

    geom = unary_union(geoms) if len(geoms) > 1 else geoms[0]

    if not geom.is_valid:
        geom = make_valid(geom)

    # make_valid can return a mix of shapes; keep only the polygon parts.
    if geom.geom_type == "GeometryCollection":
        polys = [g for g in geom.geoms if g.geom_type in ("Polygon", "MultiPolygon")]
        geom = unary_union(polys) if polys else None

    if geom is None or geom.is_empty or geom.geom_type not in ("Polygon", "MultiPolygon"):
        return None
    return geom


def orient_for_sql(geom):
    """SQL Server geography wants outer rings anticlockwise (left-hand rule)."""
    if isinstance(geom, Polygon):
        return orient(geom, sign=1.0)
    return MultiPolygon([orient(p, sign=1.0) for p in geom.geoms])


def main() -> int:
    load_dotenv()

    lat = float(os.environ["CENTRE_LAT"])
    long_ = float(os.environ["CENTRE_LONG"])
    radius_km = float(os.environ.get("RADIUS_KM", "10"))
    tolerance = float(os.environ.get("SIMPLIFY_TOLERANCE", "0"))
    run_id = "python-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    conn_str = (
        "Driver={ODBC Driver 18 for SQL Server};"
        f"Server=tcp:{os.environ['SQL_SERVER']},1433;"
        f"Database={os.environ['SQL_DATABASE']};"
        f"Uid={os.environ['SQL_USER']};"
        f"Pwd={os.environ['SQL_PASSWORD']};"
        "Encrypt=yes;TrustServerCertificate=no;Connection Timeout=60;"
    )

    session = requests.Session()
    areas = get_json(
        session,
        f"{BASE_URL}/id/floodAreas",
        params={"lat": lat, "long": long_, "dist": radius_km, "_limit": 500},
    )
    items = areas.get("items", [])
    print(f"Found {len(items)} flood areas within {radius_km} km of ({lat}, {long_})")
    if not items:
        print("Nothing to load. Check the point and radius in a browser first.")
        return 1

    inserted = updated = rejected = 0
    problems: list[tuple[str, str]] = []

    # Connect after the API call: if the database is paused, it can resume while we wait.
    conn = pyodbc.connect(conn_str, autocommit=False)
    try:
        cur = conn.cursor()
        for i, item in enumerate(items, start=1):
            code = as_text(item.get("notation")) or f"<item {i}>"
            polygon_url = item.get("polygon")
            try:
                if not polygon_url:
                    raise ValueError("no polygon link")

                geom = to_polygonal(get_json(session, polygon_url))
                if geom is None:
                    raise ValueError("empty or non-polygon geometry")

                if tolerance > 0:
                    geom = geom.simplify(tolerance, preserve_topology=True)

                wkt = orient_for_sql(geom).wkt  # WKT order is (long lat)

                cur.execute(
                    MERGE_SQL,
                    code,
                    as_text(item.get("label")),
                    as_text(item.get("description")),
                    as_text(item.get("county")),
                    as_text(item.get("riverOrSea")),
                    as_text(item.get("eaAreaName")),
                    polygon_url,
                    wkt,
                )
                action = cur.fetchone()[0]
                conn.commit()

                if action == "INSERT":
                    inserted += 1
                else:
                    updated += 1
                print(f"[{i}/{len(items)}] {code}: {action.lower()} ({len(wkt):,} chars of WKT)")

            except Exception as exc:  # one bad polygon shouldn't stop the rest
                conn.rollback()
                rejected += 1
                problems.append((code, str(exc)[:300]))
                print(f"[{i}/{len(items)}] {code}: REJECTED - {exc}")

        cur.execute(LOG_SQL, run_id, "load_flood_areas", inserted, updated, rejected)
        conn.commit()
    finally:
        conn.close()  # an open connection stops the free database auto-pausing

    print(f"\nRun {run_id}: {inserted} inserted, {updated} updated, {rejected} rejected")
    for code, message in problems:
        print(f"  {code}: {message}")

    return 0 if rejected == 0 else 2


if __name__ == "__main__":
    sys.exit(main())