-- ============================================================
-- Archivo: gold_metrics.sql
-- Capa: Gold 
-- Propósito: métricas de funnel, abandono por segmento y
-- tendencia mensual, a partir de events_silver y sessions_silver.
-- ============================================================

-- 1. Funnel general (view -> cart -> purchase)
CREATE OR REFRESH MATERIALIZED VIEW gold_funnel
COMMENT 'Metricas del funnel de conversion: view -> cart -> purchase'
TBLPROPERTIES ('layer' = 'gold', 'quality' = 'gold')
AS
SELECT
  count(*) AS total_sesiones,
  count_if(has_view) AS sesiones_con_vista,
  count_if(has_cart) AS sesiones_con_carrito,
  count_if(has_purchase) AS sesiones_con_compra,
  round(count_if(has_cart) / nullif(count_if(has_view), 0), 4) AS tasa_view_a_cart,
  round(count_if(has_purchase) / nullif(count_if(has_cart), 0), 4) AS tasa_cart_a_purchase,
  round(count_if(has_purchase) / nullif(count_if(has_view), 0), 4) AS tasa_conversion_general
FROM ecommerce_history.events_history.sessions_silver;


-- 2. Abandono y conversion por categoria, marca y rango de precio
-- (a nivel de evento, porque una sesion puede tocar varias categorias/marcas)
CREATE OR REFRESH MATERIALIZED VIEW gold_abandono_segmento
COMMENT 'Tasa de abandono y conversion por categoria, marca y rango de precio'
TBLPROPERTIES ('layer' = 'gold', 'quality' = 'gold')
AS
SELECT
  category_level_1,
  brand,
  rango_precio,
  count_if(event_type = 'cart') AS total_carritos,
  count_if(event_type = 'remove_from_cart') AS total_abandonos,
  count_if(event_type = 'purchase') AS total_compras,
  round(count_if(event_type = 'remove_from_cart') / nullif(count_if(event_type = 'cart'), 0), 4)
    AS tasa_abandono,
  round(count_if(event_type = 'purchase') / nullif(count_if(event_type = 'cart'), 0), 4)
    AS tasa_conversion
FROM ecommerce_history.events_history.events_silver
GROUP BY category_level_1, brand, rango_precio;


-- 3. Tendencia mensual de conversion (usa cohort_month de sessions_silver)
CREATE OR REFRESH MATERIALIZED VIEW gold_tendencia_mensual
COMMENT 'Evolucion mensual de la tasa de conversion'
TBLPROPERTIES ('layer' = 'gold', 'quality' = 'gold')
AS
SELECT
  cohort_month,
  count(*) AS total_sesiones,
  count_if(has_view) AS sesiones_con_vista,
  count_if(has_purchase) AS sesiones_con_compra,
  round(count_if(has_purchase) / nullif(count_if(has_view), 0), 4) AS tasa_conversion_mensual
FROM ecommerce_history.events_history.sessions_silver
GROUP BY cohort_month
ORDER BY cohort_month;


-- 4. Distribucion de precio: productos comprados vs abandonados
CREATE OR REFRESH MATERIALIZED VIEW gold_precio_comprado_vs_abandonado
COMMENT 'Distribucion de precio y categoria: comprados vs abandonados'
TBLPROPERTIES ('layer' = 'gold', 'quality' = 'gold')
AS
SELECT
  event_type,
  category_level_1,
  rango_precio,
  count(*) AS total_eventos,
  round(avg(price), 2) AS precio_promedio
FROM ecommerce_history.events_history.events_silver
WHERE event_type IN ('purchase', 'remove_from_cart')
GROUP BY event_type, category_level_1, rango_precio
ORDER BY event_type, total_eventos DESC;