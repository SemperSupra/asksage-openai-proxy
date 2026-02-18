# Running Ask Sage OpenAI Proxy with Containers

This guide explains how to build and run the proxy using Docker or Podman. Both containers are based on a minimal Debian Trixie image and run as a non-root user for security.

## Python Version

### Building

**Docker:**
```bash
cd python
docker build -t asksage-python-proxy .
```

**Podman:**
```bash
cd python
podman build -t asksage-python-proxy .
```

### Running

**Docker:**
```bash
docker run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-proxy \
  asksage-python-proxy
```

**Podman:**
```bash
podman run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-proxy \
  asksage-python-proxy
```

## PowerShell Version

### Building

**Docker:**
```bash
cd powershell
docker build -t asksage-powershell-proxy .
```

**Podman:**
```bash
cd powershell
podman build -t asksage-powershell-proxy .
```

### Running

**Docker:**
```bash
docker run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-pwsh-proxy \
  asksage-powershell-proxy
```

**Podman:**
```bash
podman run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-pwsh-proxy \
  asksage-powershell-proxy
```
