# Ask Sage → OpenAI-Compatible Proxy (Python/FastAPI)

This directory contains the Python implementation of the Ask Sage OpenAI-compatible proxy. It is built using FastAPI and `httpx`.

## Features
- OpenAI endpoints:
  - `POST /v1/chat/completions`
  - `GET /v1/models`
  - `POST /v1/audio/speech`
  - `POST /v1/audio/transcriptions`
- Health check:
  - `GET /healthz`

## Environment variables

Required:

- `ASKSAGE_API_KEY`
  Your Ask Sage API key (or a 24-hour access token).

Optional:

- `ASKSAGE_SERVER_BASE` (default: `https://api.genai.army.mil/server/`)
- `ASKSAGE_DEFAULT_MODEL` (default: `gpt-4o-mini`)
- `ASKSAGE_DEFAULT_PERSONA` (default: `1`)
- `ASKSAGE_DEFAULT_DATASET` (default: `none`)
- `ASKSAGE_DEFAULT_LIVE` (default: `0`)
- `ASKSAGE_DEFAULT_LIMIT_REFERENCES` (default: `0`)
- `ASKSAGE_INCLUDE_USAGE` (default: `false`)
- `ASKSAGE_VERIFY_TLS` (default: `true`)
- `ASKSAGE_CA_BUNDLE_PATH` (optional) path to a PEM CA bundle for DoD environments (mounted into the container)
- `HTTP_TIMEOUT` (default: `120` seconds)

## Run with Podman/Docker

### Build

From the `python/` directory:

```bash
cd python
podman build -f Containerfile -t asksage-openai-proxy:latest .
```

### Run (rootless)

```bash
export ASKSAGE_API_KEY="YOUR_API_KEY"
podman run --rm -p 8000:8000 \
  -e ASKSAGE_API_KEY \
  -e ASKSAGE_SERVER_BASE="https://api.genai.army.mil/server/" \
  asksage-openai-proxy:latest
```

### Smoke test

```bash
./scripts/smoke-test.sh
```

## OpenShift deployment

Manifests are in `manifests/openshift/`.

### 1) Create a Secret with your API key

```bash
oc create secret generic asksage-proxy-secret \
  --from-literal=ASKSAGE_API_KEY="YOUR_API_KEY"
```

### 2) Deploy

```bash
oc apply -f manifests/openshift/deployment.yaml
oc apply -f manifests/openshift/service.yaml
oc apply -f manifests/openshift/route.yaml
```

## Development

Install dependencies:
```bash
pip install -r python/requirements.txt
```

Run tests:
```bash
cd python
pytest
```
