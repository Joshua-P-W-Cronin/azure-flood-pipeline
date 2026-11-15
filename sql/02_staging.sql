DROP TABLE IF EXISTS stg.stations;

CREATE TABLE stg.stations(
    station_uri         nvarchar(200) NULL,   -- @id
    station_reference   nvarchar(50)  NULL,
    label               nvarchar(1000) NULL,
    river_name          nvarchar(1000) NULL,
    catchment_name      nvarchar(1000) NULL,
    town                nvarchar(1000) NULL,
    latitude            nvarchar(1000) NULL,   -- text on purpose, see below
    longitude           nvarchar(1000) NULL,
    easting             nvarchar(1000) NULL,
    northing            nvarchar(1000) NULL,
    status              nvarchar(200) NULL,
    typical_range_high  float         NULL,   -- stageScale.typicalRangeHigh
    typical_range_low   float         NULL,   -- stageScale.typicalRangeLow
    source_file         nvarchar(400) NULL,
    loaded_at_utc       datetime2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
)
;

DROP TABLE IF EXISTS stg.measures;

CREATE TABLE stg.measures(
    measure_uri         nvarchar(300) NULL,   -- @id
    station_reference   nvarchar(50)  NULL,
    label               nvarchar(400) NULL,
    parameter           nvarchar(50) NULL,
    parameter_name      nvarchar(200) NULL,
    qualifier           nvarchar(100) NULL,
    period_seconds      nvarchar(20),
    unit_name           nvarchar(50),
    value_type          nvarchar(50),
    source_file         nvarchar(400),
    loaded_at_utc       datetime2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
)
;

DROP TABLE IF EXISTS stg.readings;

CREATE TABLE stg.readings (
    date_time       nvarchar(30)  NULL,   -- e.g. 2026-11-15T10:15:00Z, converted in the MERGE
    measure         nvarchar(300) NULL,   -- measure URI, joins to dw.dim_measure.measure_uri
    value           nvarchar(50)  NULL,   -- text on purpose; TRY_CAST in the MERGE
    source_file     nvarchar(400) NULL,   -- set from $$FILEPATH in the Copy activity
    loaded_at_utc   datetime2(0)  NOT NULL
        CONSTRAINT DF_stg_readings_loaded DEFAULT SYSUTCDATETIME()
);
