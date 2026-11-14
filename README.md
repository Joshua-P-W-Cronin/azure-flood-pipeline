# azure-flood-pipeline
Project to learn Azure Data Factory, with sql server and python. Using flood data for Geospatial angle



# Notes from API Ingestion build:
**Double check your parameters:**

* I added test parameters for the initial copy pipelines and when I removed them, forgot to add back the dynamic parameters. 

**Backfill** 

* The API publishes the archive CSV from the previous day at 22:00. The Archive pipeline needs to be adjusted accordingly. 

**General Notes** 

