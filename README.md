# Ask Sage → OpenAI-Compatible Proxy

A lightweight proxy that allows you to use Ask Sage with tools that expect OpenAI API endpoints (like VS Code Continue, Cursor, various agents).

This repository contains two equivalent implementations:
- **Python (FastAPI)**: Recommended for containerized environments (Podman, Docker, Kubernetes/OpenShift).
- **PowerShell**: Recommended for Windows endpoints or restricted environments without Python/Docker access.

## Quick Links

- [Python Proxy Documentation](docs/python-proxy.md)
- [PowerShell Proxy Documentation](docs/powershell-proxy.md)
- [API Compatibility Guide](docs/api-compatibility.md)

## Features

- **Chat Completions:** Maps `POST /v1/chat/completions` to Ask Sage `/server/query`.
- **Models:** Maps `GET /v1/models` to Ask Sage `/server/get-models`.
- **Audio:** Supports text-to-speech (`/v1/audio/speech`) and transcription (`/v1/audio/transcriptions`).
- **Configuration:** Use environment variables or custom payload fields to configure Ask Sage behavior (Persona, Dataset, Live Search).

## Getting Started

### Python (Docker/Podman)

```bash
cd python
podman build -t asksage-openai-proxy-python .
podman run -p 8000:8000 -e ASKSAGE_API_KEY="your-key" asksage-openai-proxy-python
```

See [docs/python-proxy.md](docs/python-proxy.md) for full details.

### PowerShell

```powershell
$env:ASKSAGE_API_KEY = "your-key"
pwsh ./powershell/AskSageProxy.ps1
```

See [docs/powershell-proxy.md](docs/powershell-proxy.md) for full details.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

### Repository Structure

- `python/`: FastAPI implementation, tests, and Dockerfile.
- `powershell/`: PowerShell script and Pester tests.
- `manifests/`: Deployment manifests (OpenShift, etc.).
- `docs/`: Detailed documentation.
