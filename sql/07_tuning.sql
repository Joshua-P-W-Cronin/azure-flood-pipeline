SET STATISTICS IO, TIME ON;

-- Q1: stations within 10 km of a point (spatial index on dim_station)
DECLARE @p geography = geography::Point(51.4543, -0.9781, 4326);
SELECT station_key, label
FROM dw.dim_station
WHERE location.STDistance(@p) <= 10000;

-- Q2: stations inside flood areas (spatial index on dim_flood_area)
SELECT COUNT(*) AS stations_in_flood_areas
FROM dw.v_station_flood_area;

-- Q3: the headline question (latest reading per measure)
SELECT n.label, l.value, l.level_status
FROM dw.fn_stations_near(51.4543, -0.9781, 10) AS n
JOIN dw.v_station_latest_level AS l
  ON l.station_key = n.station_key;

-- Q4: highest reading per station in the last 24 hours of data (fact index)
DECLARE @asof datetime2(0) = (SELECT MAX(reading_ts) FROM dw.fact_reading);
SELECT station_key, MAX(value) AS max_value_24h, COUNT(*) AS readings
FROM dw.fact_reading
WHERE reading_ts >= DATEADD(hour, -24, @asof)
GROUP BY station_key;

-- Index 1 -> Q1 and Q3: spatial index on station points
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'SIX_dim_station_location')
    CREATE SPATIAL INDEX SIX_dim_station_location
        ON dw.dim_station (location)
        USING GEOGRAPHY_AUTO_GRID;
GO

-- -- Index 2 -> Q2: spatial index on flood-area polygons
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'SIX_dim_flood_area_boundary')
    CREATE SPATIAL INDEX SIX_dim_flood_area_boundary
        ON dw.dim_flood_area (boundary)
        USING GEOGRAPHY_AUTO_GRID;
GO

-- Index 3 -> Q4: time-range lookups on the fact table
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_fact_reading_reading_ts')
    CREATE NONCLUSTERED INDEX IX_fact_reading_reading_ts
        ON dw.fact_reading (reading_ts)
        INCLUDE (station_key, value);
GO