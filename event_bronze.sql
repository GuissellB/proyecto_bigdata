-- ============================================================
-- Archivo: 01_events_bronze.sql
-- Capa: Bronze
-- Propósito:
-- Cargar incrementalmente archivos CSV desde el volumen.
-- ============================================================

CREATE OR REFRESH STREAMING TABLE events_bronze
COMMENT 'Datos originales de eventos cargados desde archivos CSV'
TBLPROPERTIES (
    'quality' = 'bronze',
    'layer' = 'bronze',
    'source_format' = 'csv'
)
AS
SELECT
    event_time,
    event_type,
    product_id,
    category_id,
    category_code,
    brand,
    price,
    user_id,
    user_session,

    _metadata.file_name AS source_file,
    _metadata.file_path AS source_file_path,
    _metadata.file_size AS source_file_size,
    _metadata.file_modification_time
        AS source_file_modification_time,

    current_timestamp() AS processing_timestamp

FROM STREAM read_files(
    '/Volumes/ecommerce_history/events_history/db_ecommerce_history/',
    format => 'csv',
    header => 'true',
    delimiter => ',',

    schema => '
        event_time STRING,
        event_type STRING,
        product_id STRING,
        category_id STRING,
        category_code STRING,
        brand STRING,
        price STRING,
        user_id STRING,
        user_session STRING
    '
);