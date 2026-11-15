IF OBJECT_ID(N'dw.dim_station', N'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_station (
        station_key         int IDENTITY(1,1) NOT NULL,
        station_reference   nvarchar(50)  NOT NULL,
        station_uri         nvarchar(200) NULL,
        label               nvarchar(400) NULL,
        river_name          nvarchar(200) NULL,
        catchment_name      nvarchar(200) NULL,
        town                nvarchar(200) NULL,
        status              nvarchar(200) NULL,
        latitude            float         NULL,
        longitude           float         NULL,
        easting             int           NULL,
        northing            int           NULL,
        location            geography     NULL,
        typical_range_high  float         NULL,
        typical_range_low   float         NULL,
        created_at_utc      datetime2(0)  NOT NULL CONSTRAINT DF_dim_station_created DEFAULT SYSUTCDATETIME(),
        updated_at_utc      datetime2(0)  NOT NULL CONSTRAINT DF_dim_station_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_station PRIMARY KEY CLUSTERED (station_key),
        CONSTRAINT UQ_dim_station_ref UNIQUE (station_reference)
    );
END;
GO

IF OBJECT_ID(N'dw.dim_measure', N'U') IS NULL
BEGIN
    CREATE TABLE dw.dim_measure (
        measure_key         int IDENTITY(1,1) NOT NULL,
        measure_uri         nvarchar(300) NOT NULL,
        station_key         int           NULL,
        station_reference   nvarchar(50)  NULL,   -- kept so unmatched measures are easy to trace
        label               nvarchar(400) NULL,
        parameter           nvarchar(50)  NULL,
        parameter_name      nvarchar(100) NULL,
        qualifier           nvarchar(100) NULL,
        period_seconds      int           NULL,
        unit_name           nvarchar(50)  NULL,
        value_type          nvarchar(50)  NULL,
        created_at_utc      datetime2(0)  NOT NULL CONSTRAINT DF_dim_measure_created DEFAULT SYSUTCDATETIME(),
        updated_at_utc      datetime2(0)  NOT NULL CONSTRAINT DF_dim_measure_updated DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_dim_measure PRIMARY KEY CLUSTERED (measure_key),
        CONSTRAINT UQ_dim_measure_uri UNIQUE (measure_uri),
        CONSTRAINT FK_dim_measure_station FOREIGN KEY (station_key)
            REFERENCES dw.dim_station (station_key)
    );

    CREATE NONCLUSTERED INDEX IX_dim_measure_station ON dw.dim_measure (station_key);
END;
GO