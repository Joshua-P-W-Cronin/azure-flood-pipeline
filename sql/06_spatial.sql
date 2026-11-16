/*
* Stations within distance of a point: 
*/

CREATE OR ALTER FUNCTION dw.fn_stations_near (@lat float, @long float, @radius_km float)
RETURNS TABLE
AS
RETURN
    SELECT s.station_key, s.station_reference, s.label, s.river_name, s.town,
           CAST(s.location.STDistance(geography::Point(@lat, @long, 4326)) / 1000.0
                AS decimal(8, 2)) AS distance_km
    FROM dw.dim_station AS s
    WHERE s.location.STDistance(geography::Point(@lat, @long, 4326)) <= @radius_km * 1000;
GO

/*
* Run to test
*/
-- SELECT * FROM dw.fn_stations_near(51.4543, -0.9781, 10) ORDER BY distance_km;

/*
* Stations inside flood areas:
*/

CREATE OR ALTER VIEW dw.v_station_flood_area AS
SELECT area.area_code
, area.label AS flood_area
, area.river_or_sea
, station.station_key
, station.station_reference
, station.label AS station
, station.river_name
FROM dw.dim_flood_area AS area
JOIN dw.dim_station    AS station
  ON a.boundary.STIntersects(s.location) = 1;
GO

/*
* Run to test stations inside flood areas.
*/
-- SELECT * FROM dw.v_station_flood_area ORDER BY flood_area, station;

/*
* Latest river level against typical range:
*/
CREATE OR ALTER VIEW dw.v_station_latest_level AS 
SELECT dim_station.station_key
, dim_station.station_reference
, dim_station.label as station
, dim_station.river_name
, dim_station.town
, dim_measure.measure_key
, dim_measure.unit_name
, reading.reading_ts
, reading.value
, dim_station.typical_range_low
, dim_station.typical_range_high
, CASE WHEN dim_station.typical_range_high IS NULL THEN 'No typical range'
    WHEN reading.value >dim_station.typical_range_high THEN 'Above typical range'
    WHEN reading.value < dim_station.typical_range_low THEN 'Below typical range'
    ELSE 'Normal'
    END AS level_status

FROM dw.dim_station 
    JOIN dw.dim_measure on dim_measure.station_key = dim_station.station_key
        AND dim_measure.parameter = 'level'
        AND dim_measure.qualifier = 'Stage'
CROSS APPLY (
    SELECT TOP(1) fact_reading.reading_ts
    , fact_reading.VALUE
    FROM dw.fact_reading
    WHERE fact_reading.measure_key = dim_measure.measure_key
    ORDER BY fact_reading.reading_ts DESC
) as reading
;
GO

/*
* Which stations within 10km of READING are running above typical range? 
*/

SELECT nearStations.label AS station
, nearStations.river_name
, nearStations.distance_km
, latest.level_status
, latest.value
, latest.typical_range_low
, latest.typical_range_high
, latest.reading_ts
FROM dw.fn_stations_near(51.4543, -0.9781, 10) AS nearStations
JOIN dw.v_station_latest_level latest on latest.station_key = nearStations.station_key
ORDER BY CASE latest.level_status 
    WHEN 'Above typical range' THEN 0 ELSE 1 END, 
    nearStations.distance_km

