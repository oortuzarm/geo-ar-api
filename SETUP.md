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

## Deploy en Railway

```bash
railway login
railway init
railway add postgresql
railway up
```

Configurar variables de entorno en el dashboard de Railway.
