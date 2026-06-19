# geo-ar-api — Setup

## Requisitos
- Ruby 3.3+
- PostgreSQL 14+
- Bundler

## Instalación

```bash
# 1. Crear el proyecto Rails (solo la primera vez)
rails new geo-ar-api --api --database=postgresql --skip-test
cd geo-ar-api

# Copiar los archivos de este directorio sobre el proyecto Rails recién creado

# 2. Instalar dependencias
bundle install

# 3. Crear y migrar la base de datos
rails db:create db:migrate

# 4. Iniciar el servidor
rails server -p 3001
```

## Variables de entorno

| Variable           | Descripción                              | Ejemplo                        |
|--------------------|------------------------------------------|--------------------------------|
| `DATABASE_URL`     | URL de conexión a PostgreSQL             | `postgres://user:pass@host/db` |
| `ALLOWED_ORIGINS`  | Orígenes permitidos para CORS (CSV)      | `https://geo-ar.vercel.app`    |
| `RAILS_ENV`        | Entorno de Rails                         | `production`                   |
| `SECRET_KEY_BASE`  | Clave secreta (requerida en producción)  | (generada con rails secret)    |

## Conectar el frontend

En el proyecto `geo-AR`, definir la variable de entorno:

```bash
# .env.local (desarrollo)
VITE_API_URL=http://localhost:3001

# Vercel (producción)
VITE_API_URL=https://geo-ar-api.railway.app
```

## Endpoints

### Privados (sin auth por ahora)

| Método | Ruta                                      | Descripción             |
|--------|-------------------------------------------|-------------------------|
| GET    | /api/geo-projects                         | Listar proyectos        |
| POST   | /api/geo-projects                         | Crear proyecto          |
| GET    | /api/geo-projects/:id                     | Obtener proyecto        |
| PUT    | /api/geo-projects/:id                     | Actualizar proyecto     |
| DELETE | /api/geo-projects/:id                     | Eliminar proyecto       |
| GET    | /api/geo-projects/:id/geo-points          | Listar puntos           |
| POST   | /api/geo-projects/:id/geo-points          | Crear punto             |
| PUT    | /api/geo-points/:id                       | Actualizar punto        |
| DELETE | /api/geo-points/:id                       | Eliminar punto          |

### Público (sin auth, solo proyectos activos)

| Método | Ruta                                  | Descripción              |
|--------|---------------------------------------|--------------------------|
| GET    | /api/public/geo-projects/:id          | Ver proyecto publicado   |

Respuestas: `403` si no está activo, `404` si no existe.

## API v1

Prefijo base: `/api/v1`

Auth: HTTP Basic con las credenciales de API.
```
Authorization: Basic base64(key_public:key_secret)
```

| Método | Ruta                        | Scope requerido    | Descripción                                      |
|--------|-----------------------------|--------------------|--------------------------------------------------|
| GET    | /api/v1/health              | —                  | Health check (sin auth)                          |
| GET    | /api/v1/projects            | `projects:read`    | Listar proyectos de la organización              |
| GET    | /api/v1/projects/:id        | `projects:read`    | Obtener proyecto                                 |
| GET    | /api/v1/locations/:id       | `projects:read`    | Obtener ubicación (GeoPoint)                     |
| POST   | /api/v1/presence/validate   | `presence:validate`| Validar presencia (con efectos: consume quota, registra evento) |
| POST   | /api/v1/presence/check      | `presence:check`   | Validar presencia en modo dry-run (sin efectos)  |

---

### POST /api/v1/presence/validate

Valida si un usuario está dentro del área de una ubicación. Consume quota, registra evento de analytics y actualiza live_visits.

**Auth:** `presence:validate` scope.

**Header opcional:** `Idempotency-Key: <string>` (TTL 24 hs, máx 255 caracteres).

**Request body:**

```json
{
  "location_id": "42",
  "session_id": "session-abc-123",
  "coordinates": {
    "latitude": -33.45,
    "longitude": -70.66,
    "accuracy_meters": 8.0
  },
  "dwell_elapsed_seconds": 120,
  "timestamp": "2026-06-19T15:30:00Z",
  "context": {
    "user_ref": "user-xyz",
    "metadata": { "channel": "mobile" }
  }
}
```

| Campo                         | Tipo    | Requerido | Descripción                                          |
|-------------------------------|---------|-----------|------------------------------------------------------|
| `location_id`                 | string  | ✓         | ID del GeoPoint (entero, pertenece a la organización) |
| `session_id`                  | string  | ✓         | Identificador de sesión del usuario. Cualquier string no vacío (no requiere UUID). |
| `coordinates.latitude`        | float   | ✓         | Latitud (-90 a 90)                                   |
| `coordinates.longitude`       | float   | ✓         | Longitud (-180 a 180)                                |
| `coordinates.accuracy_meters` | float   | —         | Precisión del GPS en metros (positivo)               |
| `dwell_elapsed_seconds`       | integer | —         | Segundos que el usuario lleva en el área. Requerido si la ubicación tiene `requires_dwell_time`. |
| `timestamp`                   | string  | —         | ISO 8601. Si se omite, se usa la hora del servidor.  |
| `context`                     | object  | —         | Contexto adicional del usuario                       |
| `context.user_ref`            | string  | —         | Referencia al usuario en el sistema del cliente      |
| `context.metadata`            | object  | —         | Metadata arbitraria (objeto plano)                   |

**Response exitosa (200):**

```json
{
  "valid": true,
  "locationId": "42",
  "sessionId": "session-abc-123",
  "checks": {
    "locationActive": true,
    "insideBoundary": true,
    "boundaryType": "radius",
    "distanceMeters": 34.7,
    "scheduleActive": true,
    "quotaAvailable": true,
    "quotaRemaining": 9,
    "liveVisitsEnabled": false,
    "liveVisitsMet": true,
    "dwellRequired": false,
    "dwellTimeMet": true
  },
  "destination": {
    "type": "url",
    "url": "https://example.com/contenido"
  },
  "failureReason": null,
  "eventId": "789"
}
```

**Response fallo de validación (200):**

```json
{
  "valid": false,
  "locationId": "42",
  "sessionId": "session-abc-123",
  "checks": {
    "locationActive": true,
    "insideBoundary": false,
    "boundaryType": "radius",
    "distanceMeters": 312.4
  },
  "destination": null,
  "failureReason": "outside_boundary",
  "eventId": "790"
}
```

| Campo           | Tipo          | Descripción                                                 |
|-----------------|---------------|-------------------------------------------------------------|
| `valid`         | boolean       | `true` si pasa todos los checks                             |
| `locationId`    | string        | ID del GeoPoint                                             |
| `sessionId`     | string        | Session ID recibido                                         |
| `checks`        | object        | Estado de cada check en camelCase                           |
| `destination`   | object / null | URL de destino si valid=true y hay contenido configurado    |
| `failureReason` | string / null | Código de falla (ver tabla abajo)                           |
| `eventId`       | string / null | ID del evento de analytics registrado (null en dry-run)     |

**Códigos de `failureReason`:**

| Código                             | Condición                                                     |
|------------------------------------|---------------------------------------------------------------|
| `location_inactive`                | El GeoPoint no está activo                                    |
| `outside_boundary`                 | Las coordenadas están fuera del área definida                 |
| `outside_schedule`                 | Fuera del horario configurado en la ubicación                 |
| `quota_exhausted`                  | El cupo de validaciones se agotó                              |
| `minimum_live_visits_not_reached`  | No hay suficientes usuarios simultáneos en el área            |
| `dwell_required`                   | La ubicación requiere dwell pero no se envió `dwell_elapsed_seconds` |
| `dwell_time_not_met`               | El tiempo en área es menor al mínimo requerido                |

**Errores HTTP:**

| Status | Body                                                                             | Condición                              |
|--------|----------------------------------------------------------------------------------|----------------------------------------|
| 401    | `{"error":"Invalid or missing API credentials"}`                                 | Auth inválida o ausente                |
| 403    | `{"error":"insufficient_scope","required":"presence:validate"}`                  | Scope faltante                         |
| 404    | `{"error":"Location not found"}`                                                 | `location_id` no existe en la org      |
| 409    | `{"error":"Request in progress","retryAfter":30}`                                | Idempotency key en vuelo               |
| 422    | `{"error":"Invalid request parameters","details":{"latitude":"is required",...}}`| Payload inválido                       |

---

## Deploy en Railway

```bash
railway login
railway init
railway add postgresql
railway up
```

Configurar variables de entorno en el dashboard de Railway.
