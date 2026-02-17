# Running Ask Sage OpenAI Proxy from CLI

This guide explains how to run both the Python and PowerShell versions directly from your command line.

## Prerequisites

- **Python Version**: Python 3.11+
- **PowerShell Version**: PowerShell Core 7.4+ (pwsh)
- **Ask Sage API Key**: You need an API key from Ask Sage.

## Python (FastAPI)

1.  Navigate to the `python` directory:
    ```bash
    cd python
    ```

2.  Create a virtual environment:
    ```bash
    python3 -m venv venv
    source venv/bin/activate  # On Windows: venv\Scripts\activate
    ```

3.  Install dependencies:
    ```bash
    pip install -r requirements.txt
    ```

4.  Run the server:
    ```bash
    export ASKSAGE_API_KEY="your-key-here"
    uvicorn app.main:app --host 0.0.0.0 --port 8000
    ```

## PowerShell

1.  Navigate to the `powershell` directory:
    ```bash
    cd powershell
    ```

2.  Run the script:
    ```powershell
    $env:ASKSAGE_API_KEY = "your-key-here"
    pwsh ./AskSageProxy.ps1
    ```

    Or on Linux/macOS:
    ```bash
    export ASKSAGE_API_KEY="your-key-here"
    pwsh ./AskSageProxy.ps1
    ```
