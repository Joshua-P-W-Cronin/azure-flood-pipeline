DROP TABLE IF EXISTS stg.stations;

CREATE TABLE stg.stations(
    station_uri         nvarchar(200) NULL,   -- @id
    station_reference   nvarchar(50)  NULL,
    label               nvarchar(400) NULL,
    river_name          nvarchar(200) NULL,
    catchment_name      nvarchar(200) NULL,
    town                nvarchar(200) NULL,
    latitude            nvarchar(100) NULL,   -- text on purpose, see below
    longitude           nvarchar(100) NULL,
    easting             nvarchar(100) NULL,
    northing            nvarchar(100) NULL,
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

CREATE TABLE stg.readings(
    reading_datetime datetime2(0)   NULL,
    measure nvarchar(400)               NULL,
    reading_value float                 NULL,
    loaded_at_utc datetime2(0)  NOT NULL DEFAULT SYSUTCDATETIME()
);

