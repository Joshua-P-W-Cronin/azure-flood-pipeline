/* =====================================================================
   05_procs.sql
   Load log + MERGE procedures for the flood monitoring pipeline.
   Safe to re-run: the log table is created only if missing, and every
   procedure uses CREATE OR ALTER.
   ===================================================================== */

-- ---------------------------------------------------------------------
-- Load log
-- ---------------------------------------------------------------------
IF OBJECT_ID(N'dw.load_log', N'U') IS NULL
BEGIN
    CREATE TABLE dw.load_log (
        log_id          int IDENTITY(1,1) NOT NULL,
        run_id          nvarchar(50)   NOT NULL,   -- ADF @pipeline().RunId
        step            nvarchar(100)  NOT NULL,
        rows_inserted   int            NULL,
        rows_updated    int            NULL,
        rows_rejected   int            NULL,
        error_message   nvarchar(4000) NULL,
        logged_at_utc   datetime2(0)   NOT NULL
            CONSTRAINT DF_load_log_logged DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_load_log PRIMARY KEY CLUSTERED (log_id)
    );

    CREATE NONCLUSTERED INDEX IX_load_log_run ON dw.load_log (run_id);
END;
GO


-- ---------------------------------------------------------------------
-- Helper: some API fields arrive as a list (e.g. ["Thames","Lee"] or
-- [51.5, 51.6]). ADF lands those as JSON text; this returns the first
-- element, or the value unchanged when it isn't a list.
-- ---------------------------------------------------------------------
CREATE OR ALTER FUNCTION dw.fn_first_value (@v nvarchar(1000))
RETURNS nvarchar(1000)
WITH SCHEMABINDING
AS
BEGIN
    RETURN CASE
        WHEN LEFT(LTRIM(@v), 1) = N'[' THEN JSON_VALUE(@v, N'$[0]')
        ELSE @v
    END;
END;
GO


-- ---------------------------------------------------------------------
-- 1. dim_station
--    Deduplicates staging, cleans coordinates, builds the geography
--    point, and only updates rows whose values actually changed.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_merge_dim_station
    @run_id nvarchar(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @changes TABLE (change_type nvarchar(10));
    DECLARE @rejected int;

    -- A station with no reference can't be keyed, so it is rejected.
    SELECT @rejected = COUNT(*)
    FROM stg.stations
    WHERE NULLIF(LTRIM(RTRIM(station_reference)), N'') IS NULL;

    WITH src AS (
        SELECT
            LTRIM(RTRIM(s.station_reference))               AS station_reference,
            s.station_uri,
            CAST(dw.fn_first_value(s.label)          AS nvarchar(400)) AS label,
            CAST(dw.fn_first_value(s.river_name)     AS nvarchar(200)) AS river_name,
            CAST(dw.fn_first_value(s.catchment_name) AS nvarchar(200)) AS catchment_name,
            CAST(dw.fn_first_value(s.town)           AS nvarchar(200)) AS town,
            s.status,
            TRY_CAST(dw.fn_first_value(s.latitude)  AS float)                 AS latitude,
            TRY_CAST(dw.fn_first_value(s.longitude) AS float)                 AS longitude,
            TRY_CAST(TRY_CAST(dw.fn_first_value(s.easting)  AS float) AS int) AS easting,
            TRY_CAST(TRY_CAST(dw.fn_first_value(s.northing) AS float) AS int) AS northing,
            s.typical_range_high,
            s.typical_range_low,
            ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(s.station_reference))
                ORDER BY s.loaded_at_utc DESC
            ) AS rn
        FROM stg.stations AS s
        WHERE NULLIF(LTRIM(RTRIM(s.station_reference)), N'') IS NOT NULL
    )
    MERGE dw.dim_station AS tgt
    USING (SELECT * FROM src WHERE rn = 1) AS s
        ON tgt.station_reference = s.station_reference

    -- Null-safe "has anything changed?" check: EXCEPT treats NULLs as equal.
    WHEN MATCHED AND EXISTS (
        SELECT s.station_uri, s.label, s.river_name, s.catchment_name, s.town, s.status,
               s.latitude, s.longitude, s.easting, s.northing,
               s.typical_range_high, s.typical_range_low
        EXCEPT
        SELECT tgt.station_uri, tgt.label, tgt.river_name, tgt.catchment_name, tgt.town, tgt.status,
               tgt.latitude, tgt.longitude, tgt.easting, tgt.northing,
               tgt.typical_range_high, tgt.typical_range_low
    )
    THEN UPDATE SET
        station_uri        = s.station_uri,
        label              = s.label,
        river_name         = s.river_name,
        catchment_name     = s.catchment_name,
        town               = s.town,
        status             = s.status,
        latitude           = s.latitude,
        longitude          = s.longitude,
        easting            = s.easting,
        northing           = s.northing,
        location           = CASE
                                 WHEN s.latitude  BETWEEN -90  AND 90
                                  AND s.longitude BETWEEN -180 AND 180
                                 THEN geography::Point(s.latitude, s.longitude, 4326)
                             END,
        typical_range_high = s.typical_range_high,
        typical_range_low  = s.typical_range_low,
        updated_at_utc     = SYSUTCDATETIME()

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (station_reference, station_uri, label, river_name, catchment_name, town, status,
                latitude, longitude, easting, northing, location,
                typical_range_high, typical_range_low)
        VALUES (s.station_reference, s.station_uri, s.label, s.river_name, s.catchment_name, s.town, s.status,
                s.latitude, s.longitude, s.easting, s.northing,
                CASE
                    WHEN s.latitude  BETWEEN -90  AND 90
                     AND s.longitude BETWEEN -180 AND 180
                    THEN geography::Point(s.latitude, s.longitude, 4326)
                END,
                s.typical_range_high, s.typical_range_low)

    OUTPUT $action INTO @changes;

    INSERT INTO dw.load_log (run_id, step, rows_inserted, rows_updated, rows_rejected)
    SELECT @run_id,
           N'merge_dim_station',
           ISNULL(SUM(CASE WHEN change_type = N'INSERT' THEN 1 ELSE 0 END), 0),
           ISNULL(SUM(CASE WHEN change_type = N'UPDATE' THEN 1 ELSE 0 END), 0),
           @rejected
    FROM @changes;
END;
GO


-- ---------------------------------------------------------------------
-- 2. dim_measure
--    Looks up station_key; measures whose station isn't in dim_station
--    still load, with station_key NULL, so they can be counted later.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_merge_dim_measure
    @run_id nvarchar(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @changes TABLE (change_type nvarchar(10));
    DECLARE @rejected int;

    SELECT @rejected = COUNT(*)
    FROM stg.measures
    WHERE NULLIF(LTRIM(RTRIM(measure_uri)), N'') IS NULL;

    WITH src AS (
        SELECT
            LTRIM(RTRIM(m.measure_uri))                          AS measure_uri,
            d.station_key,
            NULLIF(LTRIM(RTRIM(m.station_reference)), N'')       AS station_reference,
            m.label,
            m.parameter,
            m.parameter_name,
            m.qualifier,
            TRY_CAST(TRY_CAST(m.period_seconds AS float) AS int) AS period_seconds,
            m.unit_name,
            m.value_type,
            ROW_NUMBER() OVER (
                PARTITION BY LTRIM(RTRIM(m.measure_uri))
                ORDER BY m.loaded_at_utc DESC
            ) AS rn
        FROM stg.measures AS m
        LEFT JOIN dw.dim_station AS d
            ON d.station_reference = LTRIM(RTRIM(m.station_reference))
        WHERE NULLIF(LTRIM(RTRIM(m.measure_uri)), N'') IS NOT NULL
    )
    MERGE dw.dim_measure AS tgt
    USING (SELECT * FROM src WHERE rn = 1) AS s
        ON tgt.measure_uri = s.measure_uri

    WHEN MATCHED AND EXISTS (
        SELECT s.station_key, s.station_reference, s.label, s.parameter, s.parameter_name,
               s.qualifier, s.period_seconds, s.unit_name, s.value_type
        EXCEPT
        SELECT tgt.station_key, tgt.station_reference, tgt.label, tgt.parameter, tgt.parameter_name,
               tgt.qualifier, tgt.period_seconds, tgt.unit_name, tgt.value_type
    )
    THEN UPDATE SET
        station_key       = s.station_key,
        station_reference = s.station_reference,
        label             = s.label,
        parameter         = s.parameter,
        parameter_name    = s.parameter_name,
        qualifier         = s.qualifier,
        period_seconds    = s.period_seconds,
        unit_name         = s.unit_name,
        value_type        = s.value_type,
        updated_at_utc    = SYSUTCDATETIME()

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (measure_uri, station_key, station_reference, label, parameter, parameter_name,
                qualifier, period_seconds, unit_name, value_type)
        VALUES (s.measure_uri, s.station_key, s.station_reference, s.label, s.parameter, s.parameter_name,
                s.qualifier, s.period_seconds, s.unit_name, s.value_type)

    OUTPUT $action INTO @changes;

    INSERT INTO dw.load_log (run_id, step, rows_inserted, rows_updated, rows_rejected)
    SELECT @run_id,
           N'merge_dim_measure',
           ISNULL(SUM(CASE WHEN change_type = N'INSERT' THEN 1 ELSE 0 END), 0),
           ISNULL(SUM(CASE WHEN change_type = N'UPDATE' THEN 1 ELSE 0 END), 0),
           @rejected
    FROM @changes;
END;
GO


-- ---------------------------------------------------------------------
-- 3. fact_reading
--    Converts text to proper types, rejects rows that don't match a
--    measure or don't parse, removes duplicates (the hourly files repeat
--    readings), then inserts new rows and updates only changed values.
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_merge_fact_reading
    @run_id nvarchar(50)
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @changes TABLE (change_type nvarchar(10));
    DECLARE @rejected int;

    DROP TABLE IF EXISTS #src;

    SELECT
        m.measure_key,
        m.station_key,
        TRY_CONVERT(datetime2(0), REPLACE(r.date_time, N'Z', N''), 126) AS reading_ts,
        TRY_CAST(r.value AS float)                                     AS value,
        r.loaded_at_utc
    INTO #src
    FROM stg.readings AS r
    LEFT JOIN dw.dim_measure AS m
        ON m.measure_uri = LTRIM(RTRIM(r.measure));

    -- If this number is huge, compare URI formats in stg.readings.measure
    -- and dw.dim_measure.measure_uri (http vs https, full URI vs short ID).
    SELECT @rejected = COUNT(*)
    FROM #src
    WHERE measure_key IS NULL
       OR reading_ts  IS NULL
       OR value       IS NULL;

    WITH dedup AS (
        SELECT
            measure_key,
            station_key,
            reading_ts,
            value,
            ROW_NUMBER() OVER (
                PARTITION BY measure_key, reading_ts
                ORDER BY loaded_at_utc DESC
            ) AS rn
        FROM #src
        WHERE measure_key IS NOT NULL
          AND reading_ts  IS NOT NULL
          AND value       IS NOT NULL
    )
    MERGE dw.fact_reading AS tgt
    USING (SELECT measure_key, station_key, reading_ts, value FROM dedup WHERE rn = 1) AS s
        ON  tgt.measure_key = s.measure_key
        AND tgt.reading_ts  = s.reading_ts

    WHEN MATCHED AND EXISTS (
        SELECT s.value, s.station_key
        EXCEPT
        SELECT tgt.value, tgt.station_key
    )
    THEN UPDATE SET
        value         = s.value,
        station_key   = s.station_key,
        loaded_at_utc = SYSUTCDATETIME()

    WHEN NOT MATCHED BY TARGET THEN
        INSERT (measure_key, station_key, reading_ts, value)
        VALUES (s.measure_key, s.station_key, s.reading_ts, s.value)

    OUTPUT $action INTO @changes;

    INSERT INTO dw.load_log (run_id, step, rows_inserted, rows_updated, rows_rejected)
    SELECT @run_id,
           N'merge_fact_reading',
           ISNULL(SUM(CASE WHEN change_type = N'INSERT' THEN 1 ELSE 0 END), 0),
           ISNULL(SUM(CASE WHEN change_type = N'UPDATE' THEN 1 ELSE 0 END), 0),
           @rejected
    FROM @changes;

    DROP TABLE IF EXISTS #src;
END;
GO


-- ---------------------------------------------------------------------
-- 4. Failure logging, called from the ADF on-failure path
-- ---------------------------------------------------------------------
CREATE OR ALTER PROCEDURE dw.usp_log_failure
    @run_id        nvarchar(50),
    @step          nvarchar(100),
    @error_message nvarchar(4000)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dw.load_log (run_id, step, error_message)
    VALUES (@run_id, @step, LEFT(@error_message, 4000));
END;
GO


/* ---------------------------------------------------------------------
   Manual test (run after loading staging by hand or via ADF):

   EXEC dw.usp_merge_dim_station  @run_id = N'manual-1';
   EXEC dw.usp_merge_dim_measure  @run_id = N'manual-1';
   EXEC dw.usp_merge_fact_reading @run_id = N'manual-1';
   SELECT * FROM dw.load_log WHERE run_id = N'manual-1' ORDER BY log_id;

   Run the three EXECs again with N'manual-2': inserts should be zero
   (or close to it), which proves the load is idempotent.
   --------------------------------------------------------------------- */