# Ask Sage → OpenAI-Compatible Proxy (PowerShell)

A production-ready PowerShell version is included for environments where Python or Docker are not available (e.g., standard Windows endpoints or restricted servers).

## Features
- Functional parity with Python version (Chat, Models, Speech, Transcriptions).
- Zero-dependency deployment (requires only PowerShell 5.1+ or PowerShell 7+).
- Single script: `powershell/AskSageProxy.ps1`.

## Run Proxy

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

## Environment Variables

Required:
- `ASKSAGE_API_KEY`: Your Ask Sage API key.

Optional:
- `ASKSAGE_SERVER_BASE` (default: `https://api.genai.army.mil/server/`)
- `ASKSAGE_DEFAULT_MODEL` (default: `gpt-4o-mini`)
- `ASKSAGE_DEFAULT_PERSONA` (default: `1`)
- `ASKSAGE_DEFAULT_DATASET` (default: `none`)
- `ASKSAGE_DEFAULT_LIVE` (default: `0`)
- `ASKSAGE_DEFAULT_LIMIT_REFERENCES` (default: `0`)
- `ASKSAGE_INCLUDE_USAGE` (default: `false`)

## Development & Checks

To run the full suite of linting (PSScriptAnalyzer) and tests (Pester) with strict local/CI parity:

```powershell
# Installs pinned dependencies to powershell/.modules/ and runs checks
pwsh ./powershell/scripts/check.ps1
```
