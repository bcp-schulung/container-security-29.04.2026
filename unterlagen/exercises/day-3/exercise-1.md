# Exercise 1 — RBAC, Pod Security Admission, and OPA/Gatekeeper

**Estimated time:** 75–90 minutes

## Objective

Configure fine-grained RBAC for multiple user roles, enforce the Pod Security Admission `restricted` profile on production namespaces, install Gatekeeper, and write a policy that requires all Deployments to have specific labels. Test that violations are correctly rejected.

---

## Prerequisites

- A Kubernetes cluster with admin access
- `kubectl` configured
- Gatekeeper installed (or internet access to install it in Part 3)
- `openssl` installed

---

## Part 1 — RBAC (30 min)

### Step 1 — Create two namespaces

```bash
kubectl create namespace production
kubectl create namespace staging
```

### Step 2 — Create ServiceAccounts

```bash
# A ServiceAccount for the API application
kubectl create serviceaccount api-sa -n production

# A ServiceAccount for a CI/CD pipeline
kubectl create serviceaccount cicd-sa -n production
```

---

### Step 3 — Create a developer read-only Role

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: developer-readonly
  namespace: production
rules:
- apiGroups: [""]
  resources: ["pods", "pods/log", "services", "configmaps", "endpoints"]
  verbs: ["get", "list", "watch"]
- apiGroups: ["apps"]
  resources: ["deployments", "replicasets", "statefulsets"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/exec"]
  verbs: []    # no exec for developers in production
EOF
```

### Step 4 — Create a CI/CD deployer Role

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: deployer
  namespace: production
rules:
- apiGroups: ["apps"]
  resources: ["deployments"]
  verbs: ["get", "list", "watch", "update", "patch"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["pods/log"]
  verbs: ["get"]
EOF
```

---

### Step 5 — Bind the roles

```bash
# Bind developer group to the readonly role
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: developers-readonly
  namespace: production
subjects:
- kind: Group
  name: developers
  apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: developer-readonly
  apiGroup: rbac.authorization.k8s.io
EOF

# Bind the CI/CD ServiceAccount to the deployer role
cat << 'EOF' | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: cicd-deployer
  namespace: production
subjects:
- kind: ServiceAccount
  name: cicd-sa
  namespace: production
roleRef:
  kind: Role
  name: deployer
  apiGroup: rbac.authorization.k8s.io
EOF
```

---

### Step 6 — Test RBAC decisions with auth can-i

```bash
# Can the developers group list pods in production? (should be YES)
kubectl auth can-i list pods \
  --as-group=developers \
  --as=jane \
  --namespace production

# Can the developers group delete deployments? (should be NO)
kubectl auth can-i delete deployments \
  --as-group=developers \
  --as=jane \
  --namespace production

# Can the CI/CD ServiceAccount update deployments? (should be YES)
kubectl auth can-i update deployments \
  --as=system:serviceaccount:production:cicd-sa \
  --namespace production

# Can the CI/CD ServiceAccount delete pods? (should be NO)
kubectl auth can-i delete pods \
  --as=system:serviceaccount:production:cicd-sa \
  --namespace production

# Can the API ServiceAccount get secrets? (should be NO — no binding)
kubectl auth can-i get secrets \
  --as=system:serviceaccount:production:api-sa \
  --namespace production
```

---

### Step 7 — Grant the API ServiceAccount access to only its own Secret

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: api-db-credentials
  namespace: production
type: Opaque
stringData:
  DB_PASSWORD: supersecret
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: api-secret-reader
  namespace: production
rules:
- apiGroups: [""]
  resources: ["secrets"]
  resourceNames: ["api-db-credentials"]   # named resource — only this Secret!
  verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: api-sa-secret-reader
  namespace: production
subjects:
- kind: ServiceAccount
  name: api-sa
  namespace: production
roleRef:
  kind: Role
  name: api-secret-reader
  apiGroup: rbac.authorization.k8s.io
EOF

# Verify: can read api-db-credentials
kubectl auth can-i get secret/api-db-credentials \
  --as=system:serviceaccount:production:api-sa \
  --namespace production

# Verify: cannot read other secrets
kubectl auth can-i get secret/postgres-credentials \
  --as=system:serviceaccount:production:api-sa \
  --namespace production
```

---

## Part 2 — Pod Security Admission (20 min)

### Step 1 — Apply PSA labels to the production namespace

```bash
kubectl label namespace production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=latest \
  pod-security.kubernetes.io/audit=restricted \
  pod-security.kubernetes.io/warn=restricted

kubectl get namespace production --show-labels
```

### Step 2 — Try to deploy a privileged pod (should fail)

```bash
cat << 'EOF' | kubectl apply -f - 2>&1
apiVersion: v1
kind: Pod
metadata:
  name: bad-pod
  namespace: production
spec:
  containers:
  - name: bad
    image: ubuntu:22.04
    command: ["sleep", "3600"]
    securityContext:
      privileged: true
EOF
# Expected: Error from server (Forbidden): violates PodSecurity "restricted"
```

### Step 3 — Deploy a compliant pod (should succeed)

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
  namespace: production
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: nginx:1.27-alpine
    securityContext:
      allowPrivilegeEscalation: false
      readOnlyRootFilesystem: true
      capabilities:
        drop: ["ALL"]
    resources:
      requests:
        cpu: 50m
        memory: 32Mi
      limits:
        cpu: 100m
        memory: 64Mi
    ports:
    - containerPort: 8080
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: cache
      mountPath: /var/cache/nginx
    - name: run
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: cache
    emptyDir: {}
  - name: run
    emptyDir: {}
EOF

kubectl get pod secure-pod -n production
kubectl delete pod secure-pod -n production
```

---

## Part 3 — OPA / Gatekeeper (25 min)

### Step 1 — Install Gatekeeper

```bash
kubectl apply -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml

# Wait for Gatekeeper to be ready
kubectl wait --for=condition=ready pod \
  -l control-plane=controller-manager \
  -n gatekeeper-system \
  --timeout=120s
```

---

### Step 2 — Create a ConstraintTemplate (require specific labels)

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequiredlabels
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredLabels
      validation:
        openAPIV3Schema:
          type: object
          properties:
            labels:
              type: array
              items:
                type: string
  targets:
  - target: admission.k8s.gatekeeper.sh
    rego: |
      package k8srequiredlabels

      violation[{"msg": msg}] {
        provided := {label | input.review.object.metadata.labels[label]}
        required := {label | label := input.parameters.labels[_]}
        missing := required - provided
        count(missing) > 0
        msg := sprintf("Missing required labels on %v/%v: %v",
          [input.review.object.kind,
           input.review.object.metadata.name,
           missing])
      }
EOF

# Wait for the CRD to be established
kubectl wait --for=condition=established \
  crd/k8srequiredlabels.constraints.gatekeeper.sh \
  --timeout=60s
```

---

### Step 3 — Instantiate the Constraint

```bash
cat << 'EOF' | kubectl apply -f -
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredLabels
metadata:
  name: require-team-and-app-labels
spec:
  match:
    kinds:
    - apiGroups: ["apps"]
      kinds: ["Deployment"]
    namespaces: ["production", "staging"]
  parameters:
    labels: ["team", "app", "version"]
EOF
```

---

### Step 4 — Test the policy

```bash
# This should be REJECTED — missing labels
cat << 'EOF' | kubectl apply -f - 2>&1
apiVersion: apps/v1
kind: Deployment
metadata:
  name: unlabeled-app
  namespace: staging
spec:
  replicas: 1
  selector:
    matchLabels:
      run: test
  template:
    metadata:
      labels:
        run: test
    spec:
      containers:
      - name: test
        image: nginx:alpine
EOF
# Expected: admission webhook denied: Missing required labels on Deployment/unlabeled-app: {"team", "version", "app"}
```

```bash
# This should SUCCEED — all required labels present
cat << 'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: labeled-app
  namespace: staging
  labels:
    app: myservice
    team: platform
    version: "1.0.0"
spec:
  replicas: 1
  selector:
    matchLabels:
      app: myservice
  template:
    metadata:
      labels:
        app: myservice
        team: platform
        version: "1.0.0"
    spec:
      automountServiceAccountToken: false
      containers:
      - name: app
        image: nginx:1.27-alpine
EOF

kubectl get deployment labeled-app -n staging
kubectl delete deployment labeled-app -n staging
```

---

## Cleanup

```bash
kubectl delete namespace production staging
kubectl delete -f https://raw.githubusercontent.com/open-policy-agent/gatekeeper/release-3.15/deploy/gatekeeper.yaml 2>/dev/null || true
```

---

## Summary

You have:
- Created namespace-scoped Roles for developers (read-only) and CI/CD (deploy)
- Used named `resourceNames` to restrict a ServiceAccount to exactly one Secret
- Tested RBAC decisions with `kubectl auth can-i --as`
- Applied PSA `restricted` enforcement to a namespace and verified it blocks privileged pods
- Written a Gatekeeper ConstraintTemplate in Rego
- Instantiated a Constraint and verified it blocks non-compliant Deployments
