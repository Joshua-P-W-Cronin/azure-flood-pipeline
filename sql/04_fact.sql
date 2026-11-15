IF OBJECT_ID(N'dw.fact_reading', N'U') IS NULL
BEGIN
    CREATE TABLE dw.fact_reading (
        measure_key     int          NOT NULL,
        station_key     int          NULL,
        reading_ts      datetime2(0) NOT NULL,   -- UTC
        value           float        NULL,
        loaded_at_utc   datetime2(0) NOT NULL CONSTRAINT DF_fact_reading_loaded DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_fact_reading PRIMARY KEY CLUSTERED (measure_key, reading_ts),
        CONSTRAINT FK_fact_reading_measure FOREIGN KEY (measure_key)
            REFERENCES dw.dim_measure (measure_key),
        CONSTRAINT FK_fact_reading_station FOREIGN KEY (station_key)
            REFERENCES dw.dim_station (station_key)
    );
END;
GO