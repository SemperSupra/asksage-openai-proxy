# Ask Sage → OpenAI-Compatible Proxy (FastAPI)

This is a small **OpenAI-compatible HTTP proxy** that forwards requests to the **Ask Sage Server API** (`/query`, `/get-models`)
so you can use Ask Sage with tools that expect OpenAI endpoints.

- OpenAI endpoint implemented:
  - `POST /v1/chat/completions`
  - `GET /v1/models`
- Health:
  - `GET /healthz`

Ask Sage Server API authentication uses **`x-access-tokens`** with either a static API key or a 24-hour token. citeturn3view0

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

## Run with Podman on RHEL 9

### Build

```bash
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

## Configure Continue to use the proxy

Continue natively supports Ask Sage directly, but if you want to route through this proxy
(using the `openai` provider), here’s a minimal `~/.continue/config.yaml` model entry:

```yaml
models:
  - name: AskSage via OpenAI Proxy
    provider: openai
    model: gpt-4o-mini
    apiBase: http://YOUR_PROXY_HOST:8000
    apiKey: dummy-not-used
    roles:
      - chat
      - edit
      - apply
```

Then (optionally) add Ask Sage-specific knobs using the `asksage` object in requests, e.g.:

```json
{
  "asksage": { "persona": 1, "dataset": "none", "live": 0 }
}
```

## Notes / limitations

- This proxy maps OpenAI `messages[]` into a single prompt string for maximum compatibility.
- Tool/function calling is **not** implemented yet (Ask Sage has a `tools` parameter, but formats vary).
- Streaming is “minimal”: the proxy emits a single SSE chunk with the full response.

## PowerShell Implementation

A portable PowerShell implementation is available in the `powershell/` directory. It requires no Python or Docker dependencies, only PowerShell Core (pwsh) or Windows PowerShell 5.1+.

### Run

```powershell
./powershell/AskSageProxy.ps1 -Port 8080
```

### Sample Usage

```powershell
./powershell/SampleUsage.ps1
```

Supported endpoints:
- `GET /healthz`
- `GET /v1/models`
- `POST /v1/chat/completions` (streaming supported)
- `POST /v1/audio/speech`
- `POST /v1/audio/transcriptions` (multipart/form-data supported)

Environment variables are the same as the Python version (e.g. `ASKSAGE_API_KEY`).
