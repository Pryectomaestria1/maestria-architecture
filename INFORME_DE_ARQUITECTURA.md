# Informe de Arquitectura

> **Hub central de la arquitectura de la plataforma Udemy Clone.**  
> Este documento describe la arquitectura implementada del ecosistema de microservicios: topología, servicios, comunicación, persistencia, seguridad, contratos e infraestructura de soporte.

---

## 1. Resumen Ejecutivo

La plataforma Udemy Clone es un sistema distribuido construido como un ecosistema de microservicios desplegables de forma independiente. Los usuarios interactúan con el sistema a través de un **API Gateway** que expone endpoints REST, y la comunicación interna entre servicios se realiza con **gRPC** sobre HTTP/2 para minimizar latencia y aprovechar tipado estricto mediante Protocol Buffers. Para procesos desacoplados (notablemente la inscripción tras una compra) se utiliza **RabbitMQ** como broker de eventos, y el material multimedia (videos, portadas, recursos) se almacena en **MinIO** con acceso S3-compatible.

La separación de dominios adoptada es la siguiente:

- **api-gateway** — única puerta de entrada para el frontend.
- **user-service** — gestión de perfiles y roles.
- **catalog-service** — cursos, módulos, lecciones y recursos.
- **media-service** — generación de URLs de carga y operación de object storage.
- **enrollment-service** — inscripciones y progreso de los estudiantes.
- **sales-service** — flujo de compra y emisión de eventos.

La persistencia de los servicios que requieren almacenamiento se realiza con **PostgreSQL** mediante **Prisma**, con una base de datos lógica por servicio. La autenticación se delega a **Auth0** y la validación de tokens se ejecuta de forma stateless en el API Gateway mediante JWKS cacheado.

---

## 2. Topología General del Sistema

El siguiente diagrama refleja el estado actual del ecosistema. Cada servicio expone su propio puerto gRPC y la base de datos a la que se conecta es propiedad exclusiva del servicio que la declara.

```mermaid
graph TD
    subgraph Cliente
        FE[Frontend - React]
    end

    subgraph API Gateway Layer
        GW[API Gateway - NestJS REST]
    end

    subgraph Microservicios Capa Interna gRPC
        US[User Service - Puerto 50051]
        CS[Catalog Service - Puerto 50052]
        MS[Media Service - Puerto 50053]
        ES[Enrollment Service - Puerto 50054]
        SS[Sales Service - Puerto 50055]
    end

    subgraph Broker e Infraestructura Docker
        RMQ[RabbitMQ - Event Broker]
        MIO[MinIO - S3 Object Storage]
        DB_USER[(PostgreSQL - User DB)]
        DB_CAT[(PostgreSQL - Catalog DB)]
        DB_ENR[(PostgreSQL - Enrollment DB)]
        DB_SAL[(PostgreSQL - Sales DB)]
    end

    FE -->|HTTP/REST| GW
    GW -->|gRPC| US
    GW -->|gRPC| CS
    GW -->|gRPC| MS
    GW -->|gRPC| ES
    GW -->|gRPC| SS

    US -->|Prisma| DB_USER
    CS -->|Prisma| DB_CAT
    ES -->|Prisma| DB_ENR
    SS -->|Prisma| DB_SAL

    SS -->|Publica evento course.purchased| RMQ
    RMQ -->|Consume evento| ES
    MS -->|S3 API| MIO
```

**Notas de la topología:**

- Cada microservicio escucha en su propio puerto gRPC y no comparte su base de datos con otros.
- El API Gateway es el único punto de contacto entre el frontend y el ecosistema interno.
- Los procesos asíncronos (compra → inscripción) se coordinan con eventos en RabbitMQ sobre el evento `course.purchased`.

---

## 3. Servicios y Responsabilidades

### 3.1 `api-gateway`
- **Tipo:** NestJS con transporte HTTP/REST.
- **Responsabilidad:** autenticar cada request contra Auth0 (JWKS en memoria), traducir REST a gRPC, y exponer el endpoint público a la SPA.
- **Puerto:** `3000` (HTTP).
- **Cliente:** la SPA en React.

### 3.2 `user-service`
- **Tipo:** NestJS con transporte gRPC.
- **Responsabilidad:** cache de perfiles y de overrides de rol. Es consultado por el API Gateway para enriquecer respuestas con datos del perfil (`GetUserProfile`, `GetUsersByIds`) y para registrar/leer overrides explícitos de rol (`SetUserRole`, `GetRole`).
- **Resolución de rol: solo en el gateway.** La resolución del rol del usuario autenticado ocurre exclusivamente en el API Gateway, a partir del claim `https://udemyclone.com/roles` del JWT ya validado por RS256+JWKS. El `user-service` no decodifica tokens, no verifica firmas, no inspecciona claims. Su rol respecto a la identidad es únicamente servir como **cache de overrides explícitos**: el gateway llama a `SetUserRole({ userId, role })` después de una promoción confirmada en Auth0, y luego consulta `GetRole` cuando quiere aplicar el override sobre el claim del JWT.
- **Puerto:** `50051` (gRPC).
- **Persistencia:** PostgreSQL con Prisma.

### 3.3 `catalog-service`
- **Tipo:** NestJS con transporte gRPC.
- **Responsabilidad:** administrar cursos, módulos, lecciones y recursos. Es la fuente de verdad de la oferta académica.
- **Puerto:** `50052` (gRPC).
- **Persistencia:** PostgreSQL con Prisma.

### 3.4 `media-service`
- **Tipo:** NestJS con transporte gRPC.
- **Responsabilidad:** mediar la carga directa de archivos del navegador a MinIO mediante URLs prefirmadas (`presigned PUT`) y confirmar la materialización del asset en el catálogo. No actúa como proxy del binario: el navegador PUTea contra MinIO, y `media-service` valida y notifica al catálogo.
- **Puerto:** `50053` (gRPC).
- **Persistencia:** no mantiene base de datos propia; opera de forma stateless sobre el object storage.
- **Almacenamiento:** MinIO (S3 compatible), bucket `udemy-media` con lectura anónima y CORS configurado para los orígenes del SPA (`PUT`, `GET`, `HEAD`, `MaxAge=900`, `AllowedHeaders=*`).
- **Flujo de carga presign-URL (cambio D2):**
  1. `api-gateway` recibe `POST /v1/media/presign` y delega a `media-service.GeneratePresignedUrl(fileType, ownerId, sizeBytes, contentType)`.
  2. `media-service` genera un key determinista `{prefix}/{ownerId}/{uuid}{ext}` (con `uuid` UUIDv4 por llamada) y devuelve un `presign` PUT firmado contra MinIO con expiración de 900 segundos, vinculado a `Content-Type` y `Content-Length`.
  3. El cliente (navegador) ejecuta `PUT {uploadUrl}` directo contra MinIO; la firma caduca al pasar los 900s o si `Content-Type`/`Content-Length` no coinciden.
  4. El cliente llama a `POST /v1/media/confirm` con `{ key, ownerId, fileType, sizeBytes }`; el gateway delega a `media-service.ConfirmUpload`.
  5. `media-service` ejecuta `HeadObject` para verificar la presencia del objeto, valida que el `ownerId` coincida con el prefijo del key, construye la `canonicalUrl` (`https://${MINIO_PUBLIC_HOST}:${MINIO_PUBLIC_PORT}/udemy-media/{key}`) y dispara el fan-out al servicio de catálogo (`UpdateCourse` / `UpdateLessonVideo` / `AddResourceToLesson`) con un timeout de 5 segundos.
  6. La respuesta a `POST /v1/media/confirm` incluye `canonicalUrl`, `etag` y `lastModified`; los errores de catálogo (timeout, NOT_FOUND, red) se registran pero no fallan la confirmación.

### 3.5 `enrollment-service`
- **Tipo:** NestJS con transporte híbrido (gRPC + RabbitMQ).
- **Responsabilidad:** registrar la inscripción de un estudiante en un curso y llevar el progreso lección por lección. Recibe solicitudes vía gRPC desde el API Gateway y, además, consume el evento `course.purchased` publicado por `sales-service` para procesar la inscripción en forma asíncrona.
- **Puerto:** `50054` (gRPC).
- **Persistencia:** PostgreSQL con Prisma.

### 3.6 `sales-service`
- **Tipo:** NestJS con transporte gRPC.
- **Responsabilidad:** procesar el flujo de compra simulado, persistir la transacción y emitir el evento asíncrono `course.purchased` hacia RabbitMQ.
- **Puerto:** `50055` (gRPC).
- **Persistencia:** PostgreSQL con Prisma.

---

## 4. Comunicación

### 4.1 Frontend ↔ API Gateway
- **Transporte:** HTTP/REST con JSON.
- **Seguridad:** JWT en `Authorization: Bearer <token>`, validado en el gateway contra el `jwks_uri` de Auth0.
- **Identidad:** el `userId` y el `role` se adjuntan al `request.user` del gateway tras la verificación y se reenvían a los microservicios como atributos de la request gRPC.

### 4.2 API Gateway ↔ Microservicios
- **Transporte:** gRPC sobre HTTP/2.
- **Contratos:** definidos en `maestria-grpc-contracts` y compartidos por todos los servicios.

### 4.3 Asíncrona (Event-Driven)
- **Broker:** RabbitMQ.
- **Evento:** `course.purchased`, emitido por `sales-service` tras persistir la transacción.
- **Consumidor:** `enrollment-service`, que materializa la inscripción del estudiante cuando recibe el evento.
- **Garantía de entrega:** colas durables, de modo que un mensaje no se pierde ante una caída del broker.
- **Observación:** el flujo de inscripción también se ejecuta en línea como parte del proceso de checkout; la vía asíncrona y la síncrona pueden coexistir, y `enrollment-service` es idempotente para absorber la duplicidad.

---

## 5. Persistencia

La plataforma adopta el patrón **Database-per-service**: cada microservicio que persiste datos es dueño de su propia base de datos lógica y no existen joins ni accesos cruzados entre tablas de servicios distintos. La tecnología de persistencia utilizada es **PostgreSQL**, accedida mediante **Prisma ORM**. `media-service` no mantiene base de datos propia: opera de forma stateless sobre el object storage.

| Servicio | Base de datos | Rol de los datos |
|----------|---------------|------------------|
| `user-service` | `user_db` | Perfiles de usuario y roles |
| `catalog-service` | `catalog_db` | Cursos, módulos, lecciones, recursos |
| `enrollment-service` | `enrollment_db` | Inscripciones y progreso |
| `sales-service` | `sales_db` | Transacciones de compra |

Las migraciones se ejecutan por servicio mediante `prisma migrate` / `prisma db push` con scripts npm declarados en cada repositorio.

---

## 6. Autenticación y Seguridad

- **Proveedor de identidad (IdP):** Auth0 como OIDC externo.
- **Validación de tokens (responsabilidad exclusiva del API Gateway).** La validación de tokens la realiza **únicamente** el API Gateway. La firma `RS256` se verifica contra las claves públicas de Auth0 obtenidas por JWKS y cacheadas en memoria, evitando llamadas a `user-service` por cada request. El `user-service` **no tiene ninguna responsabilidad de validación de tokens**: no decodifica JWT, no verifica firmas, no inspecciona claims. Cualquier handler del `user-service` que necesite la identidad del llamante la recibe exclusivamente vía el metadato gRPC `x-user-id`, que el gateway puebla a partir del `req.user.userId` post-verificación (nunca desde un campo del body, para que el cliente no pueda spoofearlo).
- **Resolución de rol.** El `role` se toma del claim `https://udemyclone.com/roles` del JWT ya validado. El `user-service` solo expone overrides explícitos — escritos por el gateway vía `SetUserRole` tras una promoción confirmada en Auth0 — que el gateway puede consultar opcionalmente vía `GetRole` para aplicar sobre el claim. Esta separación elimina la superficie de spoofing que existía cuando el `user-service` mezclaba el claim del token con un override local.
- **Propagación de identidad.** El `userId` verificado se inyecta en `request.user` del gateway y se reenvía a los microservicios como metadato gRPC `x-user-id`. El `role` viaja con la request REST original y no necesita re-enviarse: cada servicio es responsable únicamente de su dominio.
- **Configuración por variables de entorno:** dominio y audiencia de Auth0 se configuran mediante `AUTH0_ISSUER_URL` y `AUTH0_AUDIENCE` consumidas por `ConfigService`.

> **Pendiente (post-archive).** Refinar la `JwtStrategy` del gateway para que aplique opcionalmente el override del `user-service` (vía `GetRole`) sobre el claim del JWT, completando así la separación de responsabilidades. Este refinamiento queda como follow-up explícito fuera de la presente entrega.

---

## 7. Almacenamiento de Media

- **Object Storage:** MinIO (S3 compatible) en entorno local, aprovisionado y configurado por `maestria-infra`.
- **Cliente S3:** el `media-service` consume MinIO mediante `@aws-sdk/client-s3`, lo que permite migrar en el futuro a AWS S3 u otro proveedor compatible sin cambiar el código del servicio.
- **Generación de URLs prefirmadas:** `media-service` expone operaciones gRPC para producir URLs prefirmadas de carga y descarga, con expiración limitada. El API Gateway puede solicitarlas y devolverlas al frontend cuando el caso de uso lo requiere.
- **API Gateway como punto de entrada para uploads:** los endpoints del API Gateway reciben los archivos de portadas, videos y recursos, y los materializan en el almacenamiento. `media-service` aporta la integración con el object storage, mientras que la superficie pública HTTP para transferir binarios la expone el gateway.
- **Aislamiento de red:** la red interna de microservicios no es accesible directamente desde el frontend. Toda la interacción del cliente con el material multimedia pasa por el API Gateway.

---

## 8. Contratos Compartidos

- **Repositorio:** `maestria-grpc-contracts`.
- **Contenido:** definiciones `.proto` para los servicios implementados del ecosistema — `user.proto`, `catalog.proto`, `media.proto`, `enrollment.proto` y `sales.proto` — fuente única de verdad de los contratos gRPC.
- **Consumo:** los microservicios cargan su `.proto` desde el path relativo estándar, lo que garantiza que gateway y servicios usen exactamente el mismo contrato.
- **Tipado:** los servicios utilizan tipos generados a partir de los `.proto` para tipar las llamadas gRPC, manteniendo consistencia entre emisor y receptor.

---

## 9. Infraestructura de Soporte

- **Repositorio:** `maestria-infra`.
- **Contenido:** un `docker-compose.yml` que levanta los recursos de soporte del entorno local:
  - **PostgreSQL** (motor de persistencia de los servicios que la utilizan).
  - **pgAdmin** (interfaz de administración de PostgreSQL).
  - **RabbitMQ** (broker de eventos, con su UI de management).
  - **MinIO** (object storage S3-compatible, con script de creación automática del bucket).
- **Uso:** es la pieza de bootstrap del entorno de desarrollo. Cada microservicio se conecta a los recursos provistos aquí mediante variables de entorno.

---

## 10. Decisiones Arquitectónicas

- **API Gateway como única entrada pública.** Centraliza autenticación, traducción REST→gRPC y composición de datos para el frontend, evitando que la SPA tenga que conocer la red interna.
- **gRPC para comunicación interna.** Reduce latencia, impone contratos tipados y permite versionar interfaces de manera explícita.
- **Event-Driven para procesos desacoplados.** `sales-service` emite el evento `course.purchased` hacia RabbitMQ al cerrar una compra. `enrollment-service` lo consume y materializa la inscripción del estudiante, desacoplando el dominio de ventas del dominio de inscripciones.
- **Database-per-service.** Cada servicio es dueño de sus datos y de su esquema. Esto facilita la evolución independiente y previene acoplamientos por persistencia.
- **Persistencia con PostgreSQL en los servicios que requieren almacenamiento relacional.** La homogeneidad simplifica la operación, la capacitación y las migraciones. `media-service` queda fuera de este patrón al operar de forma stateless sobre object storage.
- **Prisma como ORM en los servicios con base de datos.** Permite generar el cliente tipado a partir del esquema declarativo y provee migraciones reproducibles. `media-service` no usa Prisma al no tener base de datos propia.
- **Auth0 + JWKS en gateway.** La validación del token ocurre en el gateway sin round-trips a `user-service`, lo que elimina un acoplamiento síncrono innecesario y reduce la latencia por request.
- **URLs prefirmadas para media.** `media-service` produce URLs prefirmadas contra MinIO que permiten transferir archivos sin que la carga pase por el cuerpo de la request HTTP, y que pueden usarse cuando el caso lo requiera.
- **Docker Compose para entorno local.** Es la forma más simple de levantar todos los recursos de soporte en un solo comando, sin requerir Kubernetes ni orquestadores equivalentes para desarrollo.

### 10.1 Decisión D2 — Presigned URLs para uploads directos a MinIO

- **Problema.** Los endpoints originales del `api-gateway` para portada de curso (`POST /v1/courses/:id/cover`), video de lección (`POST /v1/lessons/:lessonId/video`) y recurso de lección (`POST /v1/lessons/:lessonId/resources`) escribían el binario en disco local con `fs.writeFileSync` y devolvían una URL hardcodeada `http://localhost:3000/uploads/...`. Esto rompía fuera del host de desarrollo, no escalaba, y forzaba al gateway a actuar como tier de banda en lugar de capa de autenticación y traducción. Se necesitaba un flujo que: (a) no haga pasar el binario por el gateway, (b) siga siendo compatible con un cliente navegador, (c) permita controlar tamaño y tipo por categoría de archivo, y (d) deje una URL pública estable para que el catálogo la persista.

- **Opciones consideradas.**
  1. **Presigned PUT directo del cliente a MinIO + paso de `ConfirmUpload` separado.** El gateway firma y devuelve la URL; el navegador PUTea; el cliente confirma; el media-service valida con `HeadObject` y notifica al catálogo.
  2. **Proxy del gateway con gRPC client-stream.** El gateway recibe el binario y lo streamea a `media-service`, que a su vez escribe a MinIO. Concentra todo el tráfico binario en el gateway.
  3. **Híbrido: presigned para archivos chicos, proxy para videos grandes.** Dos caminos paralelos según `Content-Length`.

- **Decisión.** Se adopta la opción 1. El gateway deja de actuar como conduit binario; `media-service` ya hablaba S3/MinIO (≈60% de la superficie existía), por lo que el delta es agregar `ConfirmUpload` y reglas de tamaño por tipo (`COVER=5MB`, `RESOURCE=100MB`, `VIDEO=5GB`). El híbrido se descartó porque agrega dos caminos de código por una ganancia marginal: el techo real está en la red del cliente, no en el gateway.

- **Consecuencias.**
  - **CORS deja de ser opcional.** Sin `mc cors set` sobre `udemy-media`, el preflight `OPTIONS` del navegador aborta antes de enviar la firma. El init container de MinIO queda como owner de la política CORS.
  - **Aparece una categoría de huérfanos.** Si el cliente nunca llama a `ConfirmUpload`, el objeto queda en el bucket hasta la expiración de la firma (900s). Un janitor de huérfanos queda como follow-up explícito.
  - **Coordinación de rollout.** La SPA debe actualizar los tres componentes (cover form, lesson video uploader, resource uploader) antes de activar `UPLOADS_V2=true`. Mientras la flag esté apagada, los nuevos endpoints devuelven `404` y los viejos siguen disponibles (legacy).
  - **Coupling media→catalog gana latencia visible.** `ConfirmUpload` espera hasta 5s por la respuesta del catálogo. Se decidió loguear y no surfacear el error para no bloquear al cliente: el objeto en MinIO es la fuente de verdad.
  - **`canonicalUrl` se construye en `media-service` desde `MINIO_PUBLIC_HOST` + `MINIO_PUBLIC_PORT`.** Migrar a un CDN futuro es una línea (cambiar el host/port); no requiere regenerar URLs existentes.

```mermaid
sequenceDiagram
    participant C as Client (Browser)
    participant G as api-gateway
    participant M as media-service
    participant N as MinIO
    participant K as catalog-service

    C->>G: POST /v1/media/presign (fileType, ownerId, sizeBytes, contentType)
    G->>M: GeneratePresignedUrl(...)
    M-->>G: { uploadUrl, key, expiresAt, canonicalUrl }
    G-->>C: 200 { uploadUrl, key, canonicalUrl, expiresAt }

    C->>N: PUT { uploadUrl } (binary, Content-Type, Content-Length)
    N-->>C: 200 OK

    C->>G: POST /v1/media/confirm (key, ownerId, fileType, sizeBytes)
    G->>M: ConfirmUpload(...)
    M->>N: HeadObject(key)
    N-->>M: { ETag, LastModified, ContentLength }
    M->>M: validate ownerId prefix == key owner segment
    M->>K: UpdateCourse | UpdateLessonVideo | AddResourceToLesson (5s timeout)
    K-->>M: ok | timeout | NOT_FOUND (logged, not surfaced)
    M-->>G: { canonicalUrl, etag, lastModified }
    G-->>C: 200 { canonicalUrl, etag, lastModified }
```

---

## 11. Operación Local

### 11.1 Recursos de soporte
Levantar PostgreSQL, RabbitMQ, MinIO y pgAdmin desde `maestria-infra`:
```
docker compose up -d
```

### 11.2 Contratos compartidos
Clonar `maestria-grpc-contracts` como repositorio hermano, en el mismo directorio padre que el resto de los microservicios.

### 11.3 Microservicios
Por cada servicio:
1. `cp .env.example .env`
2. `npm install`
3. `npm run prisma:push` (aplica el esquema a la base asignada)
4. `npm run start:dev` (arranca el servicio en modo desarrollo)

### 11.4 API Gateway
Mismo procedimiento: clonar `maestria-api-gateway` y seguir sus pasos de instalación. La configuración de URLs de los microservicios se realiza mediante variables de entorno (`USER_SERVICE_URL`, `CATALOG_SERVICE_URL`, etc.).

### 11.5 Frontend
La SPA en React se conecta exclusivamente al API Gateway en el puerto `3000`.

---

## 12. Estructura de Repositorios del Ecosistema

| Repositorio | Rol |
|-------------|-----|
| `maestria-architecture` | Este informe de arquitectura (este repositorio) |
| `maestria-grpc-contracts` | Contratos compartidos y definiciones `.proto` |
| `maestria-infra` | Recursos de soporte local (PostgreSQL, RabbitMQ, MinIO, pgAdmin) |
| `maestria-api-gateway` | Puerta de entrada REST hacia la capa de microservicios |
| `maestria-user-service` | Gestión de perfiles y roles |
| `maestria-catalog-service` | Catálogo de cursos, módulos, lecciones y recursos |
| `maestria-media-service` | URLs prefirmadas contra object storage |
| `maestria-enrollment-service` | Inscripciones y progreso de estudiantes |
| `maestria-sales-service` | Flujo de compra y emisión de eventos |

> **Nota:** El repo `maestria-grpc-contracts` incluye adicionalmente un `review.proto` con cinco RPCs (`CreateReview`, `GetReview`, `UpdateReview`, `DeleteReview`, `ListCourseReviews`) para un futuro servicio de reseñas de cursos. Esta entrega no incluye el servicio que lo implementaría; el contrato queda en el repo para garantizar compatibilidad cuando se agregue.
