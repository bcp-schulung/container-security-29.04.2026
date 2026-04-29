# Exercise 2 — Prometheus & Grafana Deployment and Velero Backup/Restore

**Estimated time:** 75–90 minutes

## Objective

Deploy the full Prometheus + Grafana monitoring stack via Helm, explore metrics and dashboards, write an alerting rule, then perform a namespace backup and restore using Velero. By the end you will have a working observability platform and a tested disaster recovery procedure.

---

## Prerequisites

- Helm 3 installed
- A Kubernetes cluster with a StorageClass that supports dynamic provisioning
- Velero CLI installed — https://velero.io/docs/latest/basic-install/
- An S3-compatible object storage bucket (MinIO works for local clusters)
- `kubectl` configured with cluster admin access

---

## Part 0 — Start MinIO for Local Object Storage (5 min)

Skip this part if you have an actual cloud storage bucket (S3, GCS, Azure Blob).

```bash
# Deploy MinIO in the cluster for Velero storage
kubectl create namespace minio

cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
  namespace: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args: ["server", "/data", "--console-address", ":9001"]
        env:
        - name: MINIO_ROOT_USER
          value: "minio"
        - name: MINIO_ROOT_PASSWORD
          value: "minio123"
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: data
          mountPath: /data
      volumes:
      - name: data
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: minio
  namespace: minio
spec:
  selector:
    app: minio
  ports:
  - name: api
    port: 9000
    targetPort: 9000
  - name: console
    port: 9001
    targetPort: 9001
EOF

kubectl wait --for=condition=ready pod -l app=minio -n minio --timeout=60s

# Create the bucket using the mc CLI (MinIO Client)
kubectl run mc --image=minio/mc --rm -it --restart=Never -- \
  sh -c "mc alias set local http://minio.minio.svc.cluster.local:9000 minio minio123 && mc mb local/velero-backups && mc ls local"
```

---

## Part 1 — Deploy Prometheus and Grafana (25 min)

### Step 1 — Add the Prometheus Community Helm repository

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
```

### Step 2 — Create a values file

```bash
cat > monitoring-values.yaml << 'EOF'
grafana:
  adminPassword: "Training2026!"
  persistence:
    enabled: false   # disabled for workshop — enable in production
  service:
    type: NodePort
    nodePort: 30300

prometheus:
  prometheusSpec:
    retention: 6h
    resources:
      requests:
        cpu: 200m
        memory: 512Mi
      limits:
        cpu: 1
        memory: 1Gi
    storageSpec: {}   # no PVC for workshop

alertmanager:
  enabled: true
  alertmanagerSpec:
    resources:
      requests:
        cpu: 50m
        memory: 64Mi

nodeExporter:
  enabled: true

kubeStateMetrics:
  enabled: true
EOF
```

### Step 3 — Install the stack

```bash
kubectl create namespace monitoring

helm install monitoring prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --values monitoring-values.yaml \
  --wait \
  --timeout 10m

kubectl get pods -n monitoring
```

---

### Step 4 — Access Grafana

```bash
# Get the Grafana service URL
# minikube:
minikube service monitoring-grafana -n monitoring --url

# Port-forward alternative
kubectl port-forward svc/monitoring-grafana 3000:80 -n monitoring &

# Open browser: http://localhost:3000
# Username: admin
# Password: Training2026!
```

**Explore in the browser:**
1. Navigate to **Dashboards → Browse**
2. Open **Kubernetes / Compute Resources / Cluster**
3. Open **Kubernetes / Compute Resources / Namespace (Pods)**
4. Open **Node Exporter / Nodes**

---

### Step 5 — Explore metrics with PromQL

```bash
# Port-forward to Prometheus UI
kubectl port-forward svc/monitoring-kube-prometheus-prometheus 9090:9090 -n monitoring &

# Open: http://localhost:9090
```

Try these queries in the Prometheus expression browser:

```promql
# All running pods per namespace
count by (namespace) (kube_pod_status_phase{phase="Running"})

# Memory usage of all containers in MB
sort_desc(container_memory_working_set_bytes{container!=""} / 1024 / 1024)

# CPU usage rate over last 5 minutes
sort_desc(rate(container_cpu_usage_seconds_total{container!=""}[5m]))

# Pods not in Running phase
kube_pod_status_phase{phase!="Running"} == 1
```

---

### Step 6 — Write a custom alerting rule

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: workshop-alerts
  namespace: monitoring
  labels:
    release: monitoring    # must match the Prometheus operator selector
spec:
  groups:
  - name: workshop.pods
    interval: 30s
    rules:
    - alert: HighMemoryUsage
      expr: |
        container_memory_working_set_bytes{
          namespace="monitoring",
          container!="",
          container!="POD"
        } / 1024 / 1024 > 400
      for: 1m
      labels:
        severity: warning
        team: platform
      annotations:
        summary: "Container {{ $labels.container }} memory > 400MB"
        description: "Container {{ $labels.namespace }}/{{ $labels.pod }}/{{ $labels.container }} is using {{ $value | humanize }}MB of memory."

    - alert: PodNotRunning
      expr: kube_pod_status_phase{phase!="Running", namespace!~"kube-system"} == 1
      for: 2m
      labels:
        severity: critical
      annotations:
        summary: "Pod {{ $labels.pod }} is not running"
        description: "Pod {{ $labels.namespace }}/{{ $labels.pod }} has been in phase {{ $labels.phase }} for more than 2 minutes."
EOF
```

```bash
# Verify the rule is loaded by Prometheus
kubectl get prometheusrule -n monitoring
curl -s http://localhost:9090/api/v1/rules | jq '.data.groups[] | select(.name == "workshop.pods") | .rules[].name'
```

---

## Part 2 — Velero Backup and Restore (30 min)

### Step 1 — Create a sample application namespace to back up

```bash
kubectl create namespace backup-demo

kubectl create deployment nginx-demo \
  --image=nginx:1.27-alpine \
  --replicas=2 \
  -n backup-demo

kubectl create configmap app-config \
  --from-literal=APP_ENV=production \
  --from-literal=LOG_LEVEL=info \
  -n backup-demo

kubectl create secret generic app-secret \
  --from-literal=API_KEY=supersecretvalue \
  -n backup-demo

kubectl expose deployment nginx-demo --port=80 -n backup-demo

kubectl wait --for=condition=available deployment/nginx-demo \
  -n backup-demo --timeout=60s

kubectl get all,configmap,secret -n backup-demo
```

---

### Step 2 — Install Velero (MinIO backend)

```bash
# Create credentials file for MinIO
cat > /tmp/velero-credentials << 'EOF'
[default]
aws_access_key_id=minio
aws_secret_access_key=minio123
EOF

velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.9.0 \
  --bucket velero-backups \
  --backup-location-config \
    region=minio,s3ForcePathStyle=true,s3Url=http://minio.minio.svc.cluster.local:9000 \
  --snapshot-location-config region=minio \
  --secret-file /tmp/velero-credentials \
  --use-node-agent

# Wait for Velero to be ready
kubectl wait --for=condition=ready pod -l deploy=velero \
  -n velero --timeout=120s

velero backup-location get
```

---

### Step 3 — Create a backup

```bash
# Back up the namespace
velero backup create backup-demo-backup \
  --include-namespaces backup-demo \
  --wait

# Check backup status
velero backup get
velero backup describe backup-demo-backup --details
```

---

### Step 4 — Simulate data loss

```bash
# Delete the entire namespace (simulate accidental deletion)
kubectl delete namespace backup-demo

# Verify it's gone
kubectl get namespace backup-demo 2>&1
# Error from server (NotFound): namespaces "backup-demo" not found
```

---

### Step 5 — Restore from backup

```bash
# Restore the namespace from backup
velero restore create restore-backup-demo \
  --from-backup backup-demo-backup \
  --wait

# Check restore status
velero restore describe restore-backup-demo
velero restore logs restore-backup-demo

# Verify everything is back
kubectl get all,configmap,secret -n backup-demo
```

---

### Step 6 — Verify restored data

```bash
# Check the Deployment is running
kubectl wait --for=condition=available deployment/nginx-demo \
  -n backup-demo --timeout=60s

# Verify the ConfigMap is restored
kubectl get configmap app-config -n backup-demo -o yaml | grep -A5 data:

# Verify the Secret is restored (it's base64 — same content)
kubectl get secret app-secret -n backup-demo -o yaml | grep -A5 data:

# Verify the Service is restored
kubectl get service nginx-demo -n backup-demo
```

---

### Step 7 — Create a scheduled backup

```bash
# Schedule daily backups at 01:00 UTC with a 48h TTL
velero schedule create daily-backup-demo \
  --schedule="0 1 * * *" \
  --include-namespaces backup-demo \
  --ttl 48h

# List schedules
velero schedule get

# Trigger a manual run of the schedule (for testing)
velero backup create --from-schedule daily-backup-demo

# List backups
velero backup get
```

---

## Cleanup

```bash
# Remove Velero
velero uninstall

# Remove MinIO
kubectl delete namespace minio

# Remove monitoring stack
helm uninstall monitoring -n monitoring
kubectl delete namespace monitoring

# Remove demo namespace
kubectl delete namespace backup-demo

# Remove temp files
rm -f /tmp/velero-credentials monitoring-values.yaml
```

---

## Summary

You have:

**Monitoring:**
- Deployed the full `kube-prometheus-stack` via Helm (Prometheus, Grafana, Alertmanager, node-exporter, kube-state-metrics)
- Explored cluster metrics through the Grafana dashboards
- Written PromQL queries to analyse pod memory and CPU usage
- Defined a `PrometheusRule` with two alerting rules (HighMemoryUsage, PodNotRunning)

**Backup/Restore:**
- Deployed Velero with a MinIO (S3-compatible) backend
- Created an on-demand backup of a namespace including Deployments, Services, ConfigMaps, and Secrets
- Simulated data loss by deleting the namespace
- Restored the namespace from backup and verified all resources were recovered
- Created a scheduled backup with a TTL to automate daily snapshots
