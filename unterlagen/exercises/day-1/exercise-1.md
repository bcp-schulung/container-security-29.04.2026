# Exercise 1 — Build, Tag, Scan, and Push a Container Image

**Estimated time:** 60–75 minutes

## Objective

Build a production-quality container image from a Dockerfile, apply multi-stage build techniques, scan it for vulnerabilities with Trivy, tag it correctly, and push it to a container registry. By the end of this exercise you will have a hardened, scanned, and published image ready for deployment.

---

## Prerequisites

- Docker Engine installed and running (`docker version`)
- Trivy installed (`trivy version`) — see https://trivy.dev/latest/getting-started/installation/
- A container registry account (Docker Hub, GHCR, or a local registry started in Step 0)
- Git and a text editor

---

## Part 0 — Start a Local Registry (Optional)

If you do not have a cloud registry account, start a local registry container.

```bash
docker run -d \
  --name local-registry \
  -p 5000:5000 \
  --restart always \
  registry:2

# Verify
curl http://localhost:5000/v2/_catalog
# {"repositories":[]}
```

> Use `localhost:5000` as your registry prefix throughout this exercise.

---

## Part 1 — Write a Multi-Stage Dockerfile (15 min)

### Step 1 — Create a project directory

```bash
mkdir ~/docker-exercise-1 && cd ~/docker-exercise-1
```

### Step 2 — Create a simple Go web server

```bash
cat > main.go << 'EOF'
package main

import (
    "fmt"
    "log"
    "net/http"
    "os"
)

func main() {
    http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
        fmt.Fprintf(w, "Hello from %s!\n", os.Getenv("APP_VERSION"))
    })
    http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
        w.WriteHeader(http.StatusOK)
        fmt.Fprint(w, "ok")
    })
    log.Println("Listening on :8080")
    log.Fatal(http.ListenAndServe(":8080", nil))
}
EOF
```

```bash
cat > go.mod << 'EOF'
module exercise1

go 1.22
EOF
```

---

### Step 3 — Write a multi-stage Dockerfile

```bash
cat > Dockerfile << 'EOF'
# Stage 1 — builder
FROM golang:1.22-bookworm AS builder
WORKDIR /src
COPY go.mod ./
RUN go mod download
COPY main.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /app .

# Stage 2 — final (minimal attack surface)
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app /app
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF
```

### Step 4 — Write a .dockerignore

```bash
cat > .dockerignore << 'EOF'
.git
*.md
Dockerfile
dist/
EOF
```

---

## Part 2 — Build and Inspect the Image (10 min)

### Step 1 — Build the image

```bash
APP_VERSION=1.0.0
docker build \
  --build-arg APP_VERSION=${APP_VERSION} \
  --tag exercise1:${APP_VERSION} \
  --tag exercise1:latest \
  .
```

### Step 2 — Inspect image layers

```bash
docker history exercise1:1.0.0 --no-trunc
docker inspect exercise1:1.0.0 | jq '.[0].Config'
```

**Questions to answer:**
1. How many layers does the final image have?
2. What is the image size? Compare it to the `golang:1.22-bookworm` base image (`docker images golang:1.22-bookworm`).
3. What user does the image run as?

---

### Step 3 — Run and test the image

```bash
docker run -d \
  --name test-app \
  -p 8080:8080 \
  -e APP_VERSION=1.0.0 \
  --read-only \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --memory=64m \
  --cpus=0.5 \
  exercise1:1.0.0

# Test
curl http://localhost:8080/
curl http://localhost:8080/healthz

docker stop test-app && docker rm test-app
```

---

## Part 3 — Vulnerability Scanning with Trivy (15 min)

### Step 1 — Scan the final image

```bash
trivy image exercise1:1.0.0
```

Observe the output:
- How many vulnerabilities are found?
- What are their severities?
- Which packages are affected?

### Step 2 — Compare against a heavier base image

```bash
# Rebuild with a standard base (for comparison)
cat > Dockerfile.ubuntu << 'EOF'
FROM golang:1.22-bookworm AS builder
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go build -o /app .

FROM ubuntu:22.04
COPY --from=builder /app /app
EXPOSE 8080
ENTRYPOINT ["/app"]
EOF

docker build -f Dockerfile.ubuntu -t exercise1-ubuntu:1.0.0 .
trivy image exercise1-ubuntu:1.0.0
```

**Compare:** How many more CVEs does the Ubuntu-based image have? What does this tell you about base image choice?

---

### Step 3 — Fail the build on HIGH or CRITICAL

```bash
trivy image --exit-code 1 --severity CRITICAL,HIGH exercise1:1.0.0
echo "Exit code: $?"
```

> In CI pipelines, `--exit-code 1` causes the pipeline step to fail if any HIGH or CRITICAL vulnerabilities are found. This prevents vulnerable images from being pushed to production registries.

### Step 4 — Scan the Dockerfile for misconfigurations

```bash
trivy config ./Dockerfile
trivy config ./Dockerfile.ubuntu
```

Which Dockerfile has more findings? Why?

---

## Part 4 — Tag and Push the Image (10 min)

### Step 1 — Tag with registry prefix

```bash
REGISTRY=localhost:5000    # or ghcr.io/yourusername

docker tag exercise1:1.0.0 ${REGISTRY}/exercise1:1.0.0
docker tag exercise1:1.0.0 ${REGISTRY}/exercise1:1
```

### Step 2 — Push to the registry

```bash
docker push ${REGISTRY}/exercise1:1.0.0
docker push ${REGISTRY}/exercise1:1
```

### Step 3 — Pull by digest (immutable reference)

```bash
# Get the digest
docker inspect --format '{{index .RepoDigests 0}}' ${REGISTRY}/exercise1:1.0.0

# Pull by digest
docker pull ${REGISTRY}/exercise1@sha256:<digest-from-above>
```

---

## Part 5 — Inspect the Registry (5 min)

```bash
# List all repositories
curl http://localhost:5000/v2/_catalog

# List tags for our image
curl http://localhost:5000/v2/exercise1/tags/list

# Fetch the manifest
curl http://localhost:5000/v2/exercise1/manifests/1.0.0 \
  -H "Accept: application/vnd.docker.distribution.manifest.v2+json"
```

---

## Cleanup

```bash
docker rm -f local-registry
docker rmi exercise1:1.0.0 exercise1:latest exercise1-ubuntu:1.0.0
docker image prune -f
rm -rf ~/docker-exercise-1
```

---

## Summary

You have:
- Written a multi-stage Dockerfile that produces a minimal distroless image
- Inspected image layers and measured the size difference vs. a full OS base
- Scanned both images with Trivy and compared their vulnerability counts
- Set up Trivy as a CI gate that fails on HIGH/CRITICAL CVEs
- Tagged and pushed an image to a container registry using semantic versioning
- Retrieved an immutable image reference by digest
