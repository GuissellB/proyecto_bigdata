-- Lakeflow Declarative Pipeline SQL | Persona 2
-- Bronze (streaming) -> Silver eventos (streaming) -> Silver sesiones/features (MV)

-- 1. Limpieza incremental, tipado y reglas de calidad por evento.
CREATE OR REFRESH STREAMING TABLE events_silver (
  CONSTRAINT fecha_valida
    EXPECT (event_ts IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT tipo_evento_valido
    EXPECT (event_type IN ('view', 'cart', 'remove_from_cart', 'purchase'))
    ON VIOLATION DROP ROW,
  CONSTRAINT producto_valido
    EXPECT (product_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT usuario_valido
    EXPECT (user_id IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT sesion_presente
    EXPECT (user_session IS NOT NULL) ON VIOLATION DROP ROW,
  CONSTRAINT precio_valido
    EXPECT (price IS NOT NULL AND price > 0) ON VIOLATION DROP ROW
)
COMMENT 'Eventos ecommerce limpios y tipados; una fila por evento recibido'
TBLPROPERTIES (
  'layer' = 'silver',
  'quality' = 'silver',
  'pipelines.autoOptimize.managed' = 'true'
)
AS
SELECT
  try_to_timestamp(trim(event_time), 'yyyy-MM-dd HH:mm:ss z') AS event_ts,
  lower(trim(event_type)) AS event_type,
  try_cast(trim(product_id) AS BIGINT) AS product_id,
  try_cast(trim(category_id) AS BIGINT) AS category_id,
  coalesce(nullif(lower(trim(category_code)), ''), 'unknown') AS category_code,
  coalesce(nullif(lower(trim(brand)), ''), 'unknown') AS brand,
  try_cast(trim(price) AS DECIMAL(18,2)) AS price,
  try_cast(trim(user_id) AS BIGINT) AS user_id,
  nullif(trim(user_session), '') AS user_session,
  sha2(concat_ws('|', trim(user_id), trim(user_session)), 256) AS session_id,
  element_at(
    split(coalesce(nullif(lower(trim(category_code)), ''), 'unknown'), '\\.'), 1
  ) AS category_level_1,
  element_at(
    split(coalesce(nullif(lower(trim(category_code)), ''), 'unknown'), '\\.'), 2
  ) AS category_level_2,
  CASE
    WHEN try_cast(price AS DECIMAL(18,2)) < 10 THEN '01_bajo_<10'
    WHEN try_cast(price AS DECIMAL(18,2)) < 50 THEN '02_medio_10_49.99'
    WHEN try_cast(price AS DECIMAL(18,2)) < 100 THEN '03_alto_50_99.99'
    ELSE '04_premium_>=100'
  END AS rango_precio,
  to_date(try_to_timestamp(trim(event_time), 'yyyy-MM-dd HH:mm:ss z')) AS event_date,
  year(try_to_timestamp(trim(event_time), 'yyyy-MM-dd HH:mm:ss z')) AS event_year,
  month(try_to_timestamp(trim(event_time), 'yyyy-MM-dd HH:mm:ss z')) AS event_month,
  hour(try_to_timestamp(trim(event_time), 'yyyy-MM-dd HH:mm:ss z')) AS event_hour,
  source_file,
  source_file_path,
  processing_timestamp
FROM STREAM(ecommerce_history.events_history.events_bronze);

-- 2. Agregacion por sesion. Es Silver por su funcion y materialized view por ser
-- una agregacion que debe reflejar nuevos eventos de una sesion ya existente.
CREATE OR REFRESH MATERIALIZED VIEW sessions_silver
COMMENT 'Resumen de comportamiento; una fila por usuario y sesion'
TBLPROPERTIES ('layer' = 'silver', 'grain' = 'one_row_per_session')
AS
SELECT
  session_id,
  user_id,
  min(event_ts) AS session_start,
  max(event_ts) AS session_end,
  greatest(
    0,
    unix_timestamp(max(event_ts)) - unix_timestamp(min(event_ts))
  ) AS duration_seconds,
  count(*) AS event_count,
  count_if(event_type = 'view') AS view_count,
  count_if(event_type = 'cart') AS cart_count,
  count_if(event_type = 'remove_from_cart') AS remove_count,
  count_if(event_type = 'purchase') AS purchase_count,
  count(DISTINCT product_id) AS distinct_products,
  count(DISTINCT category_id) AS distinct_categories,
  count(DISTINCT brand) AS distinct_brands,
  avg(price) AS avg_event_price,
  max(price) AS max_event_price,
  sum(CASE WHEN event_type = 'cart' THEN price ELSE 0 END) AS cart_value_events,
  sum(CASE WHEN event_type = 'purchase' THEN price ELSE 0 END) AS purchase_value,
  count_if(event_type = 'view') > 0 AS has_view,
  count_if(event_type = 'cart') > 0 AS has_cart,
  count_if(event_type = 'purchase') > 0 AS has_purchase,
  count_if(event_type = 'cart') > 0
    AND count_if(event_type = 'purchase') = 0 AS is_abandoned_cart,
  min_by(category_level_1, event_ts) AS first_category,
  min_by(rango_precio, event_ts) AS first_price_range,
  hour(min(event_ts)) AS start_hour,
  dayofweek(min(event_ts)) IN (1, 7) AS is_weekend,
  date_format(min(event_ts), 'yyyy-MM') AS cohort_month
FROM events_silver
GROUP BY session_id, user_id;

-- 3. Dataset listo para ML. Solo sesiones con carrito.
-- Las columnas de compra se usan para crear la etiqueta, pero no son features.
CREATE OR REFRESH MATERIALIZED VIEW session_features
COMMENT 'Variables predictoras y etiqueta; una fila por sesion con carrito'
TBLPROPERTIES (
  'layer' = 'silver',
  'grain' = 'one_row_per_cart_session',
  'target' = 'label_abandonment'
)
AS
SELECT
  session_id,
  user_id,
  session_start,
  cohort_month,
  cast(is_abandoned_cart AS INT) AS label_abandonment,
  duration_seconds,
  event_count,
  view_count,
  cart_count,
  remove_count,
  distinct_products,
  distinct_categories,
  distinct_brands,
  cast(avg_event_price AS DOUBLE) AS avg_event_price,
  cast(max_event_price AS DOUBLE) AS max_event_price,
  cast(cart_value_events AS DOUBLE) AS cart_value_events,
  start_hour,
  cast(is_weekend AS INT) AS is_weekend,
  first_category,
  first_price_range
FROM sessions_silver
WHERE has_cart;

-- 4. Validaciones para ejecutar luego de actualizar el pipeline.
-- SELECT source_file, count(*) FROM events_silver GROUP BY source_file;
-- SELECT cohort_month, count(*), avg(label_abandonment)
-- FROM session_features GROUP BY cohort_month ORDER BY cohort_month;
