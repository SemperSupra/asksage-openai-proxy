# Running Ask Sage OpenAI Proxy with Containers

This guide explains how to build and run the proxy using Docker or Podman. Both containers are based on a minimal Debian Trixie image and run as a non-root user for security.

## Python Version

### Building

**Docker:**
```bash
cd python
docker build -t asksage-openai-proxy-python .
```

**Podman:**
```bash
cd python
podman build -t asksage-openai-proxy-python .
```

### Running

**Docker:**
```bash
docker run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-openai-proxy-python \
  asksage-openai-proxy-python
```

**Podman:**
```bash
podman run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-openai-proxy-python \
  asksage-openai-proxy-python
```

## PowerShell Version

### Building

**Docker:**
```bash
cd powershell
docker build -t asksage-openai-proxy-powershell .
```

**Podman:**
```bash
cd powershell
podman build -t asksage-openai-proxy-powershell .
```

### Running

**Docker:**
```bash
docker run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-openai-proxy-powershell \
  asksage-openai-proxy-powershell
```

**Podman:**
```bash
podman run -d \
  -p 8000:8000 \
  -e ASKSAGE_API_KEY="your-key-here" \
  --name asksage-openai-proxy-powershell \
  asksage-openai-proxy-powershell
```
