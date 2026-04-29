# Exercise 2 — Harden a Running Container

**Estimated time:** 45–60 minutes

## Objective

Take a deliberately insecure container configuration, identify all security weaknesses using inspection tools, and apply comprehensive runtime hardening. You will work with Linux capabilities, seccomp profiles, AppArmor, and non-root enforcement.

---

## Prerequisites

- Docker Engine installed
- `jq` installed (`apt-get install -y jq` or `brew install jq`)
- `strace` installed on the host (`apt-get install -y strace`) — for syscall capture
- Linux host (or Linux VM) — seccomp and AppArmor are Linux-only

---

## Part 1 — Examine the Insecure Configuration (10 min)

### Step 1 — Run an insecure container

```bash
docker run -d \
  --name insecure-app \
  --privileged \
  -p 8080:80 \
  nginx:1.27-alpine
```

### Step 2 — Inspect the security configuration

```bash
# Check capabilities
docker inspect insecure-app | jq '.[0].HostConfig | {
  Privileged,
  CapAdd,
  CapDrop,
  SecurityOpt,
  ReadonlyRootfs,
  Memory,
  CpuQuota,
  PidsLimit
}'
```

**Questions:**
1. Is the container running as root inside? (`docker exec insecure-app id`)
2. What capabilities does a `--privileged` container have?
3. Can it access the host filesystem? (`docker exec insecure-app ls /proc/1/root/etc`)

---

### Step 3 — Check which user nginx runs as

```bash
docker exec insecure-app ps aux
docker exec insecure-app id
```

---

## Part 2 — Identify the Minimum Capabilities Needed (10 min)

The nginx web server only needs to bind to port 80 (requiring `NET_BIND_SERVICE`) and serve files. Let's verify this with `strace`.

### Step 1 — Capture syscalls made by nginx

```bash
# Get the host PID of the nginx master process
HOST_PID=$(docker inspect insecure-app --format '{{.State.Pid}}')

# Trace syscalls for 10 seconds
timeout 10 strace -p $HOST_PID -e trace=all -c 2>/dev/null || true
# Generates a summary of which syscalls are used
```

### Step 2 — List all current capabilities

```bash
# Inside the container
docker exec insecure-app cat /proc/1/status | grep -E "Cap(Inh|Prm|Eff)"

# Decode capabilities
docker exec insecure-app cat /proc/1/status | grep CapEff | awk '{print $2}' | \
  xargs -I{} sh -c 'python3 -c "
caps = {0: \"CHOWN\", 1: \"DAC_OVERRIDE\", 2: \"DAC_READ_SEARCH\",
        3: \"FOWNER\", 4: \"FSETID\", 5: \"KILL\", 6: \"SETGID\",
        7: \"SETUID\", 8: \"SETPCAP\", 10: \"NET_BIND_SERVICE\",
        12: \"NET_ADMIN\", 13: \"NET_RAW\", 21: \"SYS_ADMIN\"}
val = int(\"0x{}\", 16)
active = [name for bit, name in caps.items() if val & (1 << bit)]
print(active)
"'
```

---

## Part 3 — Apply Hardened Configuration (15 min)

### Step 1 — Stop the insecure container

```bash
docker stop insecure-app && docker rm insecure-app
```

### Step 2 — Run nginx with minimal capabilities

```bash
docker run -d \
  --name hardened-nginx \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --cap-add CHOWN \
  --cap-add SETUID \
  --cap-add SETGID \
  -p 8080:80 \
  --memory=64m \
  --cpus=0.5 \
  --pids-limit=50 \
  --security-opt no-new-privileges:true \
  --read-only \
  --tmpfs /tmp:size=8m \
  --tmpfs /var/cache/nginx:size=32m \
  --tmpfs /var/run:size=4m \
  nginx:1.27-alpine
```

### Step 3 — Verify it still works

```bash
curl -s http://localhost:8080 | head -5
docker logs hardened-nginx
```

---

### Step 4 — Compare configurations

```bash
# Before (insecure)
echo "=== INSECURE would have had: ===" 
echo "Privileged: true, no resource limits, no cap-drop"

# After (hardened)
docker inspect hardened-nginx | jq '.[0].HostConfig | {
  CapAdd,
  CapDrop,
  SecurityOpt,
  ReadonlyRootfs,
  Memory,
  PidsLimit
}'
```

---

## Part 4 — Write a Custom seccomp Profile (15 min)

### Step 1 — Create a minimal seccomp profile for nginx

```bash
cat > nginx-seccomp.json << 'EOF'
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"],
  "syscalls": [
    {
      "names": [
        "accept4", "bind", "brk", "close", "connect",
        "epoll_create1", "epoll_ctl", "epoll_wait",
        "exit", "exit_group", "fstat", "futex",
        "getdents64", "getpid", "gettimeofday",
        "listen", "lseek", "mmap", "mprotect", "munmap",
        "nanosleep", "open", "openat", "pipe2",
        "prctl", "pread64", "read", "recvfrom",
        "recvmsg", "rt_sigaction", "rt_sigprocmask",
        "rt_sigreturn", "sched_getaffinity", "sendfile",
        "sendmsg", "sendto", "setgid", "setgroups",
        "setuid", "setsockopt", "socket", "stat",
        "statx", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
EOF
```

---

### Step 2 — Run with the custom seccomp profile

```bash
docker stop hardened-nginx && docker rm hardened-nginx

docker run -d \
  --name hardened-nginx \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  --cap-add CHOWN \
  --cap-add SETUID \
  --cap-add SETGID \
  --security-opt no-new-privileges:true \
  --security-opt seccomp=nginx-seccomp.json \
  --read-only \
  --tmpfs /tmp:size=8m \
  --tmpfs /var/cache/nginx:size=32m \
  --tmpfs /var/run:size=4m \
  --memory=64m \
  --pids-limit=50 \
  -p 8080:80 \
  nginx:1.27-alpine

# Verify
curl -s http://localhost:8080 | grep -c "<title>"
```

---

### Step 3 — Verify the profile is active

```bash
docker inspect hardened-nginx | jq '.[0].HostConfig.SecurityOpt'
# Should show: ["no-new-privileges:true", "seccomp=<json content>"]
```

---

## Part 5 — Non-Root Application (10 min)

Run an application as a non-root user from the image itself.

```bash
# Pull an image that has a non-root user configured
docker pull nginxinc/nginx-unprivileged:1.27-alpine

# This image runs nginx on port 8080 as UID 101
docker run -d \
  --name nonroot-nginx \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --read-only \
  --tmpfs /tmp:size=8m \
  --memory=64m \
  --pids-limit=50 \
  -p 8081:8080 \
  nginxinc/nginx-unprivileged:1.27-alpine

# Verify non-root
docker exec nonroot-nginx id
# uid=101(nginx) gid=101(nginx)

curl http://localhost:8081
```

---

## Cleanup

```bash
docker stop hardened-nginx nonroot-nginx 2>/dev/null
docker rm hardened-nginx nonroot-nginx 2>/dev/null
rm -f nginx-seccomp.json
```

---

## Summary

You have:
- Identified all security weaknesses in a `--privileged` container
- Determined the minimum Linux capabilities nginx actually requires
- Applied `--cap-drop ALL` with selective re-additions
- Enforced a read-only filesystem with targeted tmpfs mounts
- Written a custom seccomp profile that restricts nginx to ~40 syscalls
- Verified a non-root container image (`nginx-unprivileged`) runs correctly

**Security posture improvement:**
| Control | Before | After |
|---|---|---|
| Capabilities | Full root (38+ caps) | 4 specific caps |
| Root process | Yes | No (UID 101) |
| Filesystem | Read-write | Read-only |
| Syscalls | All (~380) | ~44 allowed |
| Privilege escalation | Allowed | Blocked |
| Resource limits | None | Memory + CPU + PIDs |
