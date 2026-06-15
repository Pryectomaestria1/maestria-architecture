# Diseño Técnico de Despliegue en AWS (Udemy Clone)

**ESTADO DEL DOCUMENTO:** PROPUESTA / DISEÑO DE INFRAESTRUCTURA DE NUBE

---

## 1. Resumen Ejecutivo

Este documento define la arquitectura de despliegue en la nube de **Amazon Web Services (AWS)** para la plataforma distribuida Udemy Clone. Evolucionando desde el entorno de desarrollo local basado en Docker Compose, esta arquitectura está diseñada para soportar alta disponibilidad, escalabilidad elástica, tolerancia a fallos y aislamiento de red.

El sistema se ejecuta sobre contenedores gestionados por **Amazon EKS (Elastic Kubernetes Service)** utilizando los manifiestos YAML definidos en el proyecto, delegando la persistencia a servicios manejados de AWS (**Amazon RDS** y **Amazon S3**) y la autenticación a **Auth0** (OIDC).

---

## 2. Diagrama de Arquitectura en la Nube (AWS)

```mermaid
graph TD
    subgraph Internet Pública
        CL[Navegador del Cliente / SPA]
        DNS[Amazon Route 53]
        CF[Amazon CloudFront CDN]
        S3_FE[Amazon S3 - Frontend Hosting]
    end

    subgraph AWS Cloud (VPC)
        subgraph Subnets Públicas
            ALB[Application Load Balancer - ALB]
        end

        subgraph Subnets Privadas (Amazon EKS Cluster)
            GW_POD[API Gateway Pods]
            US_POD[User Service Pods]
            CS_POD[Catalog Service Pods]
            MS_POD[Media Service Pods]
            ES_POD[Enrollment Service Pods]
            SS_POD[Sales Service Pods]
            RMQ_POD[RabbitMQ Broker Pods]
        end

        subgraph Subnets de Datos Aisladas
            RDS[(Amazon RDS PostgreSQL Multi-AZ)]
            S3_MEDIA[Amazon S3 - Bucket Videos/Carátulas]
        end
    end

    subgraph Proveedores Externos
        A0[Auth0 Identity Provider]
    end

    %% Flujos de Red
    CL -->|1. Consulta DNS| DNS
    CL -->|2. Carga HTML/JS| CF
    CF -->|Origen| S3_FE
    CL -->|3. Login / JWT| A0
    CL -->|4. Peticiones REST HTTPS| ALB
    ALB -->|5. Forward HTTP/1.1| GW_POD

    %% gRPC Interno en EKS
    GW_POD -->|gRPC 50051| US_POD
    GW_POD -->|gRPC 50052| CS_POD
    GW_POD -->|gRPC 50053| MS_POD
    GW_POD -->|gRPC 50054| ES_POD
    GW_POD -->|gRPC 50055| SS_POD

    %% Conexiones de Datos
    US_POD -->|RDS Endpoint| RDS
    CS_POD -->|RDS Endpoint| RDS
    ES_POD -->|RDS Endpoint| RDS
    SS_POD -->|RDS Endpoint| RDS

    %% Eventos
    SS_POD -->|Publica evento| RMQ_POD
    RMQ_POD -->|Suscribe| ES_POD

    %% Almacenamiento
    MS_POD -->|IAM Role / AWS SDK| S3_MEDIA
    CL -->|Subida directa vía URL Prefirmada| S3_MEDIA
```

---

## 3. Capas de la Infraestructura en AWS

### 3.1 Capa de Presentación (Frontend SPA)
*   **Servicio:** **Amazon S3** (almacenamiento de objetos) configurado para Static Web Hosting.
*   **CDN / Distribución:** **Amazon CloudFront** con un certificado SSL/TLS administrado por **AWS Certificate Manager (ACM)**.
*   **Propósito:** Ofrecer tiempos de carga en milisegundos a nivel global mediante caching en ubicaciones de borde (Edge Locations) y asegurar que el frontend no consuma cómputo del cluster EKS.

### 3.2 Capa de Enrutamiento y Balanceo (API Gateway)
*   **Servicio:** **AWS Application Load Balancer (ALB)** de nivel 7 de red.
*   **Flujo:** Recibe el tráfico HTTPS público, termina el cifrado SSL/TLS y redirige las peticiones HTTP/1.1 hacia los pods del `api-gateway` dentro del cluster EKS.

### 3.3 Capa de Cómputo y Orquestación (Amazon EKS)
*   **Servicio:** **Amazon EKS (Elastic Kubernetes Service)** corriendo en subnets privadas.
*   **Seguridad:** Los microservicios no tienen asignadas IPs públicas. La comunicación se realiza exclusivamente en la red interna de la VPC.
*   **Auto-scaling:** Uso de **Horizontal Pod Autoscaler (HPA)** para replicar los pods basándose en el uso de CPU y memoria, y **Cluster Autoscaler** para añadir nodos EC2 a la infraestructura de manera dinámica.

### 3.4 Capa de Persistencia y Bases de Datos
*   **Servicio:** **Amazon RDS para PostgreSQL** desplegado con configuración **Multi-AZ** (replicación activa-pasiva en distintas Zonas de Disponibilidad para tolerancia a desastres).
*   **Desacoplamiento:** Se utiliza una única instancia de RDS para control de costos de la maestría, pero con **bases de datos lógicas y esquemas totalmente aislados** (`schema=catalog`, `schema=enrollment`, `schema=sales`), replicando de forma idéntica la lógica de desarrollo local.

### 3.5 Almacenamiento de Archivos Pesados (Multimedia)
*   **Servicio:** **Amazon S3 (Simple Storage Service)**.
*   **Flujo de Carga (Presigned URLs):**
    1.  El cliente solicita subir un video de lección.
    2.  `media-service` (vía gRPC) genera una URL de carga prefirmada de Amazon S3 utilizando los permisos del rol IAM asignado al Pod de EKS.
    3.  El frontend realiza un `PUT` directo de los archivos binarios pesados contra S3, evitando saturar el ancho de banda del cluster EKS.

### 3.6 Cola de Eventos (RabbitMQ)
*   **Servicio:** **Amazon MQ para RabbitMQ** (servicio administrado de broker de mensajería) o Pods persistentes de RabbitMQ corriendo dentro de EKS.
*   **Rol:** Garantiza la persistencia y entrega de eventos de compras/inscripciones de forma asíncrona y duradera.

---

## 4. Seguridad y Roles IAM

-   **IAM Roles for Service Accounts (IRSA):** Los pods de `media-service` no guardan llaves secretas de AWS en su disco. En su lugar, utilizan cuentas de servicio asociadas a roles de AWS IAM con permisos estrictos de lectura y escritura (`s3:PutObject`, `s3:GetObject`) en el bucket `udemy-media-bucket`.
-   **Security Groups:**
    -   El ALB solo permite entrada en los puertos `80` y `443` desde internet.
    -   Los nodos del cluster de EKS solo aceptan tráfico proveniente del Security Group del ALB.
    -   La base de datos RDS PostgreSQL solo acepta conexiones en el puerto `5432` provenientes del Security Group del cluster de EKS.
