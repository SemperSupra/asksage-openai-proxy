# Ask Sage → OpenAI-Compatible Proxy (FastAPI)

This is a small **OpenAI-compatible HTTP proxy** that forwards requests to the **Ask Sage Server API** (`/query`, `/get-models`)
so you can use Ask Sage with tools that expect OpenAI endpoints.

- OpenAI endpoint implemented:
  - `POST /v1/chat/completions`
  - `GET /v1/models`
  - `POST /v1/audio/speech`
  - `POST /v1/audio/transcriptions`
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

A production-ready PowerShell version is included for environments where Python or Docker are not available (e.g., standard Windows endpoints or restricted servers).

### Features
- Functional parity with Python version (Chat, Models, Speech, Transcriptions).
- Zero-dependency deployment (requires only PowerShell 5.1+ or PowerShell 7+).
- Single script: `powershell/AskSageProxy.ps1`.

### Run Proxy

**PowerShell 7 (Cross-Platform)**
```powershell
$env:ASKSAGE_API_KEY = "your-key"
pwsh ./powershell/AskSageProxy.ps1
```

**Windows PowerShell 5.1**
```powershell
$env:ASKSAGE_API_KEY = "your-key"
powershell.exe -File ./powershell/AskSageProxy.ps1
```

Note: Binding to `http://*:8000` (all interfaces) on Windows may require Administrator privileges. If running as a standard user, the proxy will attempt to fallback to `http://localhost:8000`.

### Development & Checks

To run the full suite of linting (PSScriptAnalyzer) and tests (Pester) with strict local/CI parity:

```powershell
# Installs pinned dependencies to .modules/ and runs checks
pwsh ./scripts/check-powershell.ps1
```
