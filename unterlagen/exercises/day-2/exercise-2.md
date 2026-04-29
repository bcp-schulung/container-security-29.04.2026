# Exercise 2 — Package and Deploy an Application with Helm

**Estimated time:** 60–75 minutes

## Objective

Package the multi-tier application from Exercise 1 as a Helm chart. Customise it for different environments using values files. Deploy it via `helm install`, upgrade it, and practise rollback. By the end you will understand how to manage the full lifecycle of a Kubernetes application using Helm.

---

## Prerequisites

- Helm 3 installed (`helm version`)
- A running Kubernetes cluster with the `workshop` namespace cleaned up (or a fresh namespace)
- Completion of or familiarity with Exercise 1

---

## Part 1 — Scaffold the Chart (10 min)

```bash
mkdir ~/helm-exercise-2 && cd ~/helm-exercise-2

# Create a new chart skeleton
helm create workshop-app

# Inspect the generated structure
find workshop-app -type f | sort
```

The scaffold generates default templates. We will replace them with our own.

```bash
# Remove default templates
rm -rf workshop-app/templates/*
rm workshop-app/charts/.gitkeep 2>/dev/null || true

# Remove test directory
rm -rf workshop-app/templates/tests
```

---

## Part 2 — Write the Chart Metadata (5 min)

```bash
cat > workshop-app/Chart.yaml << 'EOF'
apiVersion: v2
name: workshop-app
description: Multi-tier workshop application (web + API + PostgreSQL)
type: application
version: 0.1.0
appVersion: "1.0.0"
EOF
```

---

## Part 3 — Write values.yaml (10 min)

```bash
cat > workshop-app/values.yaml << 'EOF'
# Global namespace (override per environment)
namespace: workshop-helm

# Replica counts
web:
  replicaCount: 2
  image:
    repository: nginx
    tag: "1.27-alpine"
  resources:
    requests:
      cpu: 50m
      memory: 32Mi
    limits:
      cpu: 100m
      memory: 64Mi

api:
  replicaCount: 2
  image:
    repository: kennethreitz/httpbin
    tag: latest
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi

postgres:
  image:
    repository: postgres
    tag: "16-alpine"
  storage: 1Gi
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      cpu: 500m
      memory: 512Mi

ingress:
  enabled: true
  host: workshop-helm.local
  className: nginx

# Quota
quota:
  enabled: true
  maxPods: "20"
  requestsCpu: "2"
  requestsMemory: 4Gi
  limitsCpu: "4"
  limitsMemory: 8Gi
EOF
```

---

## Part 4 — Write the Templates (20 min)

### _helpers.tpl

```bash
cat > workshop-app/templates/_helpers.tpl << 'EOF'
{{/*
Expand the name of the chart.
*/}}
{{- define "workshop-app.name" -}}
{{- .Chart.Name }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "workshop-app.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
EOF
```

### namespace.yaml

```bash
cat > workshop-app/templates/namespace.yaml << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: {{ .Values.namespace }}
{{- if .Values.quota.enabled }}
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: {{ .Release.Name }}-quota
  namespace: {{ .Values.namespace }}
spec:
  hard:
    pods: {{ .Values.quota.maxPods | quote }}
    requests.cpu: {{ .Values.quota.requestsCpu | quote }}
    requests.memory: {{ .Values.quota.requestsMemory }}
    limits.cpu: {{ .Values.quota.limitsCpu | quote }}
    limits.memory: {{ .Values.quota.limitsMemory }}
{{- end }}
EOF
```

---

### postgres.yaml

```bash
cat > workshop-app/templates/postgres.yaml << 'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "workshop-app.labels" . | nindent 4 }}
type: Opaque
data:
  POSTGRES_USER: {{ "appuser" | b64enc }}
  POSTGRES_PASSWORD: {{ randAlphaNum 16 | b64enc }}
  POSTGRES_DB: {{ "appdb" | b64enc }}
---
apiVersion: v1
kind: Service
metadata:
  name: postgres-svc
  namespace: {{ .Values.namespace }}
spec:
  clusterIP: None
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
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "workshop-app.labels" . | nindent 4 }}
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
      automountServiceAccountToken: false
      containers:
      - name: postgres
        image: "{{ .Values.postgres.image.repository }}:{{ .Values.postgres.image.tag }}"
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
          {{- toYaml .Values.postgres.resources | nindent 10 }}
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
          storage: {{ .Values.postgres.storage }}
EOF
```

---

### api.yaml

```bash
cat > workshop-app/templates/api.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: api
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "workshop-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.api.replicaCount }}
  selector:
    matchLabels:
      app: api
  template:
    metadata:
      labels:
        app: api
    spec:
      automountServiceAccountToken: false
      containers:
      - name: api
        image: "{{ .Values.api.image.repository }}:{{ .Values.api.image.tag }}"
        ports:
        - containerPort: 80
        resources:
          {{- toYaml .Values.api.resources | nindent 10 }}
        readinessProbe:
          httpGet:
            path: /get
            port: 80
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: api-svc
  namespace: {{ .Values.namespace }}
spec:
  selector:
    app: api
  ports:
  - port: 80
    targetPort: 80
EOF
```

---

### web.yaml and ingress.yaml

```bash
cat > workshop-app/templates/web.yaml << 'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "workshop-app.labels" . | nindent 4 }}
spec:
  replicas: {{ .Values.web.replicaCount }}
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      automountServiceAccountToken: false
      containers:
      - name: web
        image: "{{ .Values.web.image.repository }}:{{ .Values.web.image.tag }}"
        ports:
        - containerPort: 80
        resources:
          {{- toYaml .Values.web.resources | nindent 10 }}
        readinessProbe:
          httpGet:
            path: /
            port: 80
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: web-svc
  namespace: {{ .Values.namespace }}
spec:
  selector:
    app: web
  ports:
  - port: 80
    targetPort: 80
EOF

cat > workshop-app/templates/ingress.yaml << 'EOF'
{{- if .Values.ingress.enabled }}
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: workshop-ingress
  namespace: {{ .Values.namespace }}
  labels:
    {{- include "workshop-app.labels" . | nindent 4 }}
spec:
  ingressClassName: {{ .Values.ingress.className }}
  rules:
  - host: {{ .Values.ingress.host }}
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
{{- end }}
EOF
```

---

## Part 5 — Lint and Dry-Run (5 min)

```bash
# Lint the chart
helm lint ./workshop-app

# Render templates locally without deploying
helm template my-workshop ./workshop-app | head -80

# Render with custom values
helm template my-workshop ./workshop-app \
  --set web.replicaCount=1 \
  --set ingress.host=myapp.local
```

---

## Part 6 — Install and Verify (10 min)

```bash
# Install
helm install my-workshop ./workshop-app \
  --namespace default \
  --wait \
  --timeout 3m

# Check release
helm list
helm status my-workshop

# Verify resources
kubectl get all -n workshop-helm
kubectl get pvc -n workshop-helm
```

---

## Part 7 — Upgrade and Rollback (5 min)

```bash
# Create a production values override
cat > prod-values.yaml << 'EOF'
web:
  replicaCount: 3
api:
  replicaCount: 3
ingress:
  host: prod.example.com
EOF

# Upgrade
helm upgrade my-workshop ./workshop-app --values prod-values.yaml

# Check revision history
helm history my-workshop

# Roll back to revision 1
helm rollback my-workshop 1

# Verify
helm status my-workshop
kubectl get deployments -n workshop-helm
```

---

## Cleanup

```bash
helm uninstall my-workshop
kubectl delete namespace workshop-helm
rm -rf ~/helm-exercise-2
```

---

## Summary

You have:
- Created a Helm chart from scratch with Chart.yaml, values.yaml, and templated manifests
- Used `_helpers.tpl` for shared template snippets
- Used `toYaml`, `b64enc`, `randAlphaNum`, and conditional `{{- if }}` blocks
- Linted and dry-run rendered the chart before deploying
- Installed, upgraded with a values override, and rolled back a release
- Understood how Helm stores release history as Secrets in the cluster
