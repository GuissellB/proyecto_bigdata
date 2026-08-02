# Tablas Bronze y Silver

## `events_bronze`

**Tipo:** streaming table  
**Granularidad:** una fila por evento recibido desde los archivos CSV.

Conserva los datos originales sin aplicar limpieza ni reglas de negocio. Todos los
campos de negocio se cargan como texto para preservar el contenido de la fuente.

### Datos

| Columna | Tipo | Descripción |
|---|---|---|
| `event_time` | STRING | Fecha y hora original del evento |
| `event_type` | STRING | Tipo de evento: `view`, `cart`, `remove_from_cart` o `purchase` |
| `product_id` | STRING | Identificador del producto |
| `category_id` | STRING | Identificador de la categoría |
| `category_code` | STRING | Jerarquía descriptiva de la categoría |
| `brand` | STRING | Marca del producto |
| `price` | STRING | Precio original del producto |
| `user_id` | STRING | Identificador del usuario |
| `user_session` | STRING | Identificador original de la sesión |
| `source_file` | STRING | Nombre del archivo de origen |
| `source_file_path` | STRING | Ruta del archivo de origen |
| `source_file_size` | BIGINT | Tamaño del archivo en bytes |
| `source_file_modification_time` | TIMESTAMP | Fecha de modificación del archivo |
| `processing_timestamp` | TIMESTAMP | Momento en que se procesó el registro |

### Transformaciones

- Lectura incremental de archivos CSV mediante Auto Loader.
- Incorporación de metadatos del archivo de origen.
- Incorporación de la fecha y hora de procesamiento.
- No se corrigen tipos, nulos ni valores inválidos en esta capa.

## `events_silver`

**Tipo:** streaming table  
**Granularidad:** una fila por evento válido.

Contiene los eventos de Bronze limpios, tipados y enriquecidos con variables
derivadas.

### Datos

| Columna | Descripción |
|---|---|
| `event_ts` | Fecha y hora del evento convertida a `TIMESTAMP` |
| `event_type` | Tipo de evento normalizado |
| `product_id` | Identificador numérico del producto |
| `category_id` | Identificador numérico de la categoría |
| `category_code` | Código normalizado de categoría o `unknown` |
| `category_level_1` | Primer nivel de la jerarquía de categoría |
| `category_level_2` | Segundo nivel de la jerarquía de categoría |
| `brand` | Marca normalizada o `unknown` |
| `price` | Precio convertido a decimal |
| `rango_precio` | Segmento de precio del producto |
| `user_id` | Identificador numérico del usuario |
| `user_session` | Identificador original de la sesión |
| `session_id` | Identificador SHA-256 generado para la sesión |
| `event_date` | Fecha del evento |
| `event_year` | Año del evento |
| `event_month` | Mes del evento |
| `event_hour` | Hora del evento |
| `source_file` | Archivo del que provino el evento |
| `source_file_path` | Ruta del archivo de origen |
| `processing_timestamp` | Momento de procesamiento en Bronze |

### Transformaciones

- Conversión de fechas, precios e identificadores a tipos adecuados.
- Eliminación de espacios laterales y normalización de texto a minúscula.
- Sustitución de marcas y códigos de categoría vacíos por `unknown`.
- Separación de los primeros niveles del código de categoría.
- Generación de `session_id` a partir de `user_id` y `user_session`.
- Creación de variables de fecha y hora.
- Clasificación de precios en los siguientes rangos:
  - Menor que 10: `01_bajo_<10`.
  - Desde 10 hasta 49.99: `02_medio_10_49.99`.
  - Desde 50 hasta 99.99: `03_alto_50_99.99`.
  - 100 o más: `04_premium_>=100`.
- Descarte mediante expectations de registros con fecha, evento, producto,
  usuario, sesión o precio inválidos.

## `sessions_silver`

**Tipo:** materialized view  
**Granularidad:** una fila por usuario y sesión.

Resume el comportamiento completo de cada sesión a partir de los eventos limpios.

### Datos

| Grupo | Variables |
|---|---|
| Identificación | `session_id`, `user_id` |
| Tiempo | `session_start`, `session_end`, `duration_seconds`, `start_hour`, `is_weekend`, `cohort_month` |
| Eventos | `event_count`, `view_count`, `cart_count`, `remove_count`, `purchase_count` |
| Diversidad | `distinct_products`, `distinct_categories`, `distinct_brands` |
| Precios | `avg_event_price`, `max_event_price`, `cart_value_events`, `purchase_value` |
| Segmentación | `first_category`, `first_price_range` |
| Funnel | `has_view`, `has_cart`, `has_purchase`, `is_abandoned_cart` |

### Transformaciones

- Agrupación de eventos por `session_id` y `user_id`.
- Cálculo del inicio, fin y duración de cada sesión.
- Conteo de cada tipo de evento.
- Conteo de productos, categorías y marcas diferentes.
- Cálculo de precios y valores monetarios agregados.
- Obtención de la primera categoría y el primer rango de precio de la sesión.
- Identificación de sesiones iniciadas durante el fin de semana.
- Identificación de las etapas alcanzadas en el funnel.
- Definición de abandono como una sesión con al menos un evento `cart` y ningún
  evento `purchase`.

## `session_features`

**Tipo:** materialized view  
**Granularidad:** una fila por sesión que contiene al menos un evento `cart`.

Contiene las variables y la etiqueta que se utilizarán para entrenar el modelo de
predicción de abandono.

### Datos

| Grupo | Variables |
|---|---|
| Identificación | `session_id`, `user_id`, `session_start`, `cohort_month` |
| Etiqueta | `label_abandonment` |
| Actividad | `duration_seconds`, `event_count`, `view_count`, `cart_count`, `remove_count` |
| Diversidad | `distinct_products`, `distinct_categories`, `distinct_brands` |
| Precios | `avg_event_price`, `max_event_price`, `cart_value_events` |
| Contexto | `start_hour`, `is_weekend`, `first_category`, `first_price_range` |

### Transformaciones

- Selección exclusiva de sesiones que alcanzaron el carrito.
- Conversión de `is_abandoned_cart` a la etiqueta numérica
  `label_abandonment`:
  - `1`: la sesión abandonó el carrito.
  - `0`: la sesión registró una compra.
- Conversión de variables numéricas y booleanas a tipos adecuados para ML.
- Exclusión de `has_purchase`, `purchase_count` y `purchase_value` de las
  variables predictoras para evitar fuga de información.
