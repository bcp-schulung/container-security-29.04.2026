# Exercise 1 — Deploy a Multi-Tier Application on Kubernetes

**Estimated time:** 75–90 minutes

## Objective

Deploy a complete multi-tier application on Kubernetes using Deployments, Services, a StatefulSet for the database, Secrets, ConfigMaps, PersistentVolumeClaims, and an Ingress. By the end you will have a fully running web application managed entirely through Kubernetes manifests.

---

## Prerequisites

- A running Kubernetes cluster (minikube, kind, or a cloud cluster)
- `kubectl` configured and connected (`kubectl cluster-info`)
- Ingress controller installed (minikube: `minikube addons enable ingress`)
- `jq` and `curl` installed

---

## Architecture

```
Internet → Ingress (nginx) → web Service → web Pods (3 replicas)
                           → api Service → api Pods (2 replicas) → postgres Service → PostgreSQL StatefulSet
```

---

## Part 1 — Namespace and Quotas (5 min)

```bash
mkdir -p ~/k8s-exercise-1 && cd ~/k8s-exercise-1
```

### Step 1 — Create the Namespace with resource constraints

```bash
cat > namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: workshop
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: workshop-quota
  namespace: workshop
spec:
  hard:
    pods: "20"
    requests.cpu: "2"
    requests.memory: 4Gi
    limits.cpu: "4"
    limits.memory: 8Gi
---
apiVersion: v1
kind: LimitRange
metadata:
  name: workshop-limits
  namespace: workshop
spec:
  limits:
  - type: Container
    default:
      cpu: "200m"
      memory: "128Mi"
    defaultRequest:
      cpu: "50m"
      memory: "64Mi"
    max:
      cpu: "1"
      memory: "1Gi"
EOF

kubectl apply -f namespace.yaml
kubectl describe namespace workshop
kubectl describe resourcequota -n workshop
```

---

## Part 2 — Secrets and ConfigMaps (10 min)

### Step 1 — Create the database secret

```bash
# Generate a random password
DB_PASS=$(openssl rand -base64 16)

kubectl create secret generic postgres-credentials \
  --namespace workshop \
  --from-literal=POSTGRES_USER=appuser \
  --from-literal=POSTGRES_PASSWORD="${DB_PASS}" \
  --from-literal=POSTGRES_DB=appdb

# Verify (base64 encoded, not encrypted by default)
kubectl get secret postgres-credentials -n workshop -o yaml
```

### Step 2 — Create the application ConfigMap

```bash
cat > configmap.yaml << 'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
  namespace: workshop
data:
  LOG_LEVEL: info
  APP_ENV: training
  DB_HOST: postgres-svc
  DB_PORT: "5432"
  DB_NAME: appdb
EOF

kubectl apply -f configmap.yaml
```

---

## Part 3 — PostgreSQL StatefulSet (20 min)

### Step 1 — Create the StatefulSet and headless Service

```bash
cat > postgres.yaml << 'EOF'
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  namespace: workshop
spec:
  clusterIP: None     # headless — StatefulSet pods get stable DNS
  selector:
    app: postgres
  ports:
  - port: 5432
    targetPort: 5432
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: workshop
spec:
  serviceName: postgres-svc
  replicas: 1
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
      - name: postgres
        image: postgres:16-alpine
        ports:
        - containerPort: 5432
        env:
        - name: POSTGRES_USER
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: POSTGRES_USER
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: POSTGRES_PASSWORD
        - name: POSTGRES_DB
          valueFrom:
            secretKeyRef:
              name: postgres-credentials
              key: POSTGRES_DB
        - name: PGDATA
          value: /var/lib/postgresql/data/pgdata
        volumeMounts:
        - name: postgres-data
          mountPath: /var/lib/postgresql/data
        resources:
          requests:
            cpu: "100m"
            memory: "256Mi"
          limits:
            cpu: "500m"
            memory: "512Mi"
        readinessProbe:
          exec:
            command: ["pg_isready", "-U", "appuser", "-d", "appdb"]
          initialDelaySeconds: 10
          periodSeconds: 5
  volumeClaimTemplates:
  - metadata:
      name: postgres-data
    spec:
      accessModes: ["ReadWriteOnce"]
      resources:
        requests:
          storage: 1Gi
EOF

kubectl apply -f postgres.yaml

# Wait for postgres to be ready
kubectl wait --for=condition=ready pod/postgres-0 -n workshop --timeout=120s
kubectl get pvc -n workshop
```

---

## Part 4 — API Backend Deployment (15 min)

We'll use `kennethreitz/httpbin` as a stand-in for an API service.

```bash
cat > api.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: workshop
  labels:
    app: api
    version: "1.0.0"
    team: backend
spec:
  replicas: 2
  selector:
    matchLabels:
      app: api
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: api
        version: "1.0.0"
    spec:
      serviceAccountName: default
      automountServiceAccountToken: false
      containers:
      - name: api
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
        envFrom:
        - configMapRef:
            name: app-config
        resources:
          requests:
            cpu: "50m"
            memory: "64Mi"
          limits:
            cpu: "200m"
            memory: "256Mi"
        readinessProbe:
          httpGet:
            path: /get
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /get
            port: 80
          initialDelaySeconds: 20
          periodSeconds: 10
          failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: workshop
spec:
  selector:
    app: api
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

kubectl apply -f api.yaml
kubectl rollout status deployment/api -n workshop
```

---

## Part 5 — Frontend Deployment (10 min)

```bash
cat > frontend.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: workshop
  labels:
    app: web
    team: frontend
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 1
      maxUnavailable: 1
  template:
    metadata:
      labels:
        app: web
    spec:
      automountServiceAccountToken: false
      containers:
      - name: web
        image: nginx:1.27-alpine
        ports:
        - containerPort: 80
        resources:
          requests:
            cpu: "50m"
            memory: "32Mi"
          limits:
            cpu: "100m"
            memory: "64Mi"
        readinessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 5
        livenessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 10
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: workshop
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
  type: ClusterIP
EOF

kubectl apply -f frontend.yaml
kubectl get pods -n workshop
```

---

## Part 6 — Ingress (10 min)

```bash
cat > ingress.yaml << 'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: workshop-ingress
  namespace: workshop
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /
spec:
  ingressClassName: nginx
  rules:
  - host: workshop.local
    http:
      paths:
      - path: /api
        pathType: Prefix
        backend:
          service:
            name: api-svc
            port:
              number: 80
      - path: /
        pathType: Prefix
        backend:
          service:
            name: web-svc
            port:
              number: 80
EOF

kubectl apply -f ingress.yaml
kubectl get ingress -n workshop
```

```bash
# minikube: get ingress IP
minikube ip

# Add to /etc/hosts
echo "$(minikube ip)  workshop.local" | sudo tee -a /etc/hosts

# Test
curl http://workshop.local/
curl http://workshop.local/api/get | jq .headers
```

---

## Part 7 — Simulate a Rolling Deployment (5 min)

```bash
# Update the API image to trigger a rolling update
kubectl set image deployment/api api=kennethreitz/httpbin:latest -n workshop

# Watch the rollout
kubectl rollout status deployment/api -n workshop

# Check rollout history
kubectl rollout history deployment/api -n workshop

# Roll back
kubectl rollout undo deployment/api -n workshop
kubectl rollout status deployment/api -n workshop
```

---

## Cleanup

```bash
kubectl delete namespace workshop
rm -rf ~/k8s-exercise-1
```

---

## Summary

You have deployed:
- A **Namespace** with ResourceQuota and LimitRange
- **Secrets** for database credentials, consumed via environment variables
- A **ConfigMap** for non-sensitive configuration
- A **StatefulSet** for PostgreSQL with a **PersistentVolumeClaim** for durable storage
- A multi-replica **Deployment** with rolling update strategy and health probes
- **Services** for internal routing (ClusterIP)
- An **Ingress** for HTTP routing from outside the cluster
- Performed a **rolling update** and **rollback**
