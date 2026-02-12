# Ask Sage OpenAI-Compatible Proxy (PowerShell 5.1)

This is a PowerShell 5.1 implementation of the Ask Sage OpenAI-compatible proxy. It allows you to run the proxy on Windows environments without needing Python or Docker installed.

## Features

- **OpenAI-Compatible Endpoints**:
  - `POST /v1/chat/completions` (supports streaming)
  - `GET /v1/models`
  - `GET /v1/models/{model}`
  - `POST /v1/audio/speech`
  - `GET /healthz`
- **Configuration**: Uses environment variables.
- **TLS/SSL**: Supports disabling TLS verification for development/testing.

**Note**: The `/v1/audio/transcriptions` (speech-to-text file upload) endpoint is not implemented in this version due to limitations in handling multipart form data in standard PowerShell 5.1.

## Prerequisites

- **Windows PowerShell 5.1** (pre-installed on most Windows systems)
- Network access to Ask Sage API (default: `https://api.genai.army.mil/server/`)

## Installation

1. Download or copy the `AskSageProxy.ps1` file to your machine.

## Configuration

Set the required environment variable `ASKSAGE_API_KEY` before running the script. You can set other optional variables as needed.

| Variable | Default | Description |
| :--- | :--- | :--- |
| `ASKSAGE_API_KEY` | (Required) | Your Ask Sage API key or token. |
| `ASKSAGE_SERVER_BASE` | `https://api.genai.army.mil/server/` | Base URL for Ask Sage Server API. |
| `ASKSAGE_DEFAULT_MODEL` | `gpt-4o-mini` | Default model if not specified in request. |
| `ASKSAGE_DEFAULT_PERSONA` | `1` | Default persona ID. |
| `ASKSAGE_VERIFY_TLS` | `true` | Set to `false` to disable SSL certificate verification. |
| `HTTP_TIMEOUT` | `120` | Request timeout in seconds. |

## Usage

Open a PowerShell terminal and run the script:

```powershell
# Set your API Key
$env:ASKSAGE_API_KEY = "your-api-key-here"

# Run the proxy on port 8000 (default)
.\AskSageProxy.ps1 -Port 8000
```

The server will start listening on `http://*:8000/`.

### Administrative Privileges

Binding to `http://*:8000/` might require running PowerShell as Administrator depending on your Windows network configuration. If you encounter an "Access Denied" error, try running as Administrator or change the port.

## Testing

You can test the proxy using `curl` or `Invoke-RestMethod` from another terminal.

**Health Check:**

```powershell
Invoke-RestMethod -Uri "http://localhost:8000/healthz"
```

**Chat Completion:**

```powershell
$body = @{
    model = "gpt-4o-mini"
    messages = @(
        @{ role = "system"; content = "You are a helpful assistant." },
        @{ role = "user"; content = "Hello!" }
    )
} | ConvertTo-Json -Depth 5

Invoke-RestMethod -Uri "http://localhost:8000/v1/chat/completions" `
    -Method Post `
    -ContentType "application/json" `
    -Body $body
```

**List Models:**

```powershell
Invoke-RestMethod -Uri "http://localhost:8000/v1/models"
```
