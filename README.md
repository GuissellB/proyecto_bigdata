# Proyecto Big Data — Eventos de ecommerce

Este proyecto procesa eventos de comportamiento de clientes utilizando Databricks
y la arquitectura Medallion. Los datos avanzan desde una capa Bronze, que conserva
los registros originales, hasta una capa Silver limpia y preparada para análisis y
modelado. Posteriormente, la capa Gold contendrá los indicadores analíticos del
negocio.

## Datos utilizados

El conjunto contiene eventos de ecommerce de diciembre de 2019 y enero de 2020.

| Archivo | Cantidad de eventos | Periodo |
|---|---:|---|
| `2019-Dec.csv` | 3,533,286 | Diciembre de 2019 |
| `2020-Jan.csv` | 4,264,752 | Enero de 2020 |
| **Total** | **7,798,038** | **Dos meses** |

Los tipos de evento esperados son:

- `view`: visualización de un producto.
- `cart`: producto agregado al carrito.
- `remove_from_cart`: producto eliminado del carrito.
- `purchase`: compra de un producto.

## Arquitectura

```text
Archivos CSV
    ↓ Auto Loader
events_bronze                 Streaming table
    ↓ limpieza y validaciones
events_silver                 Streaming table
    ↓ agregación por sesión
sessions_silver               Materialized view Silver
    ↓ preparación para ML
session_features              Materialized view Silver
    ↓ analítica descriptiva
tablas Gold                   Materialized views
```

Bronze y Silver representan niveles de calidad dentro de la arquitectura
Medallion. El tipo de objeto de Databricks se selecciona según la transformación:
los eventos se procesan como flujo incremental, mientras que los resultados
agrupados por sesión se mantienen mediante vistas materializadas.

## Capa Bronze

### `events_bronze`

Es una streaming table que ingiere incrementalmente los CSV mediante Auto Loader.
Su propósito es conservar los datos tal como llegan, sin aplicar reglas de negocio
ni eliminar registros. Esto permite auditoría, trazabilidad y reconstrucción de
las capas posteriores.

Los campos de negocio se reciben como texto:

| Columna | Descripción |
|---|---|
| `event_time` | Fecha y hora original del evento |
| `event_type` | Tipo de interacción del usuario |
| `product_id` | Identificador del producto |
| `category_id` | Identificador de la categoría |
| `category_code` | Jerarquía descriptiva de la categoría |
| `brand` | Marca del producto |
| `price` | Precio del producto |
| `user_id` | Identificador del usuario |
| `user_session` | Identificador de la sesión |

También incorpora metadatos de trazabilidad:

| Columna | Descripción |
|---|---|
| `source_file` | Nombre del archivo de origen |
| `source_file_path` | Ruta del archivo en el volumen |
| `source_file_size` | Tamaño del archivo |
| `source_file_modification_time` | Fecha de modificación del archivo |
| `processing_timestamp` | Momento en que Databricks procesó el registro |

## Capa Silver

El código de esta capa se encuentra en
[`persona2_silver_features.sql`](persona2_silver_features.sql).

### `events_silver`

Es una streaming table que lee incrementalmente `events_bronze`. Su grano es una
fila por evento válido.

Realiza las siguientes transformaciones:

- Convierte la fecha a `TIMESTAMP`.
- Convierte producto, categoría y usuario a identificadores numéricos.
- Convierte el precio a un tipo decimal.
- Normaliza los textos a minúscula y elimina espacios laterales.
- Sustituye marcas y códigos de categoría vacíos por `unknown`.
- Separa los primeros niveles de la jerarquía de categoría.
- Genera un identificador estable de sesión mediante SHA-256.
- Agrega año, mes, fecha y hora del evento.
- Clasifica el producto mediante `rango_precio`.

Los rangos de precio definidos son:

| Rango | Clasificación |
|---|---|
| Menor que 10 | `01_bajo_<10` |
| Desde 10 hasta 49.99 | `02_medio_10_49.99` |
| Desde 50 hasta 99.99 | `03_alto_50_99.99` |
| 100 o más | `04_premium_>=100` |

La tabla utiliza expectations de Lakeflow para controlar fechas, tipos de evento,
productos, usuarios, sesiones y precios. Los registros que incumplen estas reglas
se registran en las métricas de calidad del pipeline y se descartan de Silver.

### `sessions_silver`

Es una vista materializada con una fila por usuario y sesión. Agrupa los eventos
de `events_silver` y calcula:

- Inicio, fin y duración de la sesión.
- Total de eventos, vistas, carritos, eliminaciones y compras.
- Cantidad de productos, categorías y marcas distintas.
- Precio promedio y máximo observado.
- Valor de eventos de carrito y valor comprado.
- Categoría y rango de precio iniciales.
- Hora de inicio, fin de semana y mes de la sesión.
- Indicadores de avance por el funnel.
- Indicador de abandono de carrito.

Una sesión se considera abandono de carrito cuando contiene al menos un evento
`cart` y no contiene eventos `purchase`.

### `session_features`

Es la vista materializada que Persona 4 utilizará para entrenar y evaluar el
modelo. Contiene una fila por sesión que llegó al carrito, variables numéricas y
categóricas sobre su comportamiento, y la etiqueta `label_abandonment`:

- `1`: la sesión abandonó el carrito.
- `0`: la sesión terminó en compra.

Las variables `has_purchase`, `purchase_count` y `purchase_value` no se incluyen
como predictores porque revelarían directamente la etiqueta y producirían fuga de
información.

## Ejecución en Databricks

El pipeline debe utilizar:

```text
Catálogo: ecommerce_history
Esquema: events_history
```

El SQL de Silver debe agregarse como código fuente del pipeline después de la
definición de Bronze. Lakeflow resolverá las dependencias entre los objetos y los
ejecutará en el orden correcto.

Para comprobar los resultados:

```sql
SELECT source_file, count(*) AS eventos_validos
FROM ecommerce_history.events_history.events_silver
GROUP BY source_file;

SELECT cohort_month,
       count(*) AS sesiones_con_carrito,
       avg(label_abandonment) AS tasa_abandono
FROM ecommerce_history.events_history.session_features
GROUP BY cohort_month
ORDER BY cohort_month;
```

