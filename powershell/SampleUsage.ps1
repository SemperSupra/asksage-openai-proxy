<#
.SYNOPSIS
    Sample usage script for Ask Sage OpenAI Proxy (PowerShell).
    Demonstrates how to start the proxy and make requests.

.DESCRIPTION
    This script sets up the environment, starts the proxy in a background job,
    and performs sample requests to verify functionality.

    Ensure you have set ASKSAGE_API_KEY environment variable or edit this script.
#>

# 1. Configuration
# $env:ASKSAGE_API_KEY = "YOUR_API_KEY_HERE"
# $env:ASKSAGE_SERVER_BASE = "https://api.genai.army.mil/server/"

param([int]$Port = 8000)

$ProxyScript = Join-Path $PSScriptRoot "AskSageProxy.ps1"

if (-not (Test-Path $ProxyScript)) {
    Write-Error "Proxy script not found at $ProxyScript"
    exit 1
}

Write-Host "Starting Proxy on port $Port..." -ForegroundColor Green
# Start with Debug enabled ($true)
$job = Start-Job -FilePath $ProxyScript -ArgumentList $Port, $true

# Wait for startup
$maxRetries = 10
Write-Host "Waiting for proxy to start..."
for ($i = 0; $i -lt $maxRetries; $i++) {
    Start-Sleep -Seconds 1
    if ($job.State -ne 'Running') {
        Write-Error "Proxy job stopped unexpectedly."
        Receive-Job -Job $job
        exit 1
    }

    try {
        $health = Invoke-RestMethod -Uri "http://localhost:$Port/healthz" -ErrorAction Stop
        Write-Host "Proxy is up!" -ForegroundColor Green
        break
    } catch {
        # Ignore connection failures while waiting
    }

    if ($i -eq $maxRetries - 1) {
        Write-Error "Proxy failed to respond after $($maxRetries)s."
        Receive-Job -Job $job
        exit 1
    }
}

try {
    # 2. Health Check
    Write-Host "`n[1] Health Status:" -ForegroundColor Yellow
    $health | Format-List

    # 3. List Models
    Write-Host "`n[2] Listing Models..." -ForegroundColor Yellow
    try {
        $models = Invoke-RestMethod -Uri "http://localhost:$Port/v1/models"
        if ($models.data) {
            $models.data | Select-Object id, owned_by | Format-Table -AutoSize
        } else {
            Write-Host "No models returned (check API Key)."
        }
    } catch {
        Write-Warning "Failed to list models (Auth error expected if no key): $_"
    }

    # 4. Chat Completion
    Write-Host "`n[3] Chat Completion..." -ForegroundColor Yellow
    $chatBody = @{
        model = "gpt-4o-mini"
        messages = @(
            @{ role = "system"; content = "You are a helpful assistant." }
            @{ role = "user"; content = "Hello from PowerShell!" }
        )
    } | ConvertTo-Json -Depth 5

    try {
        $chatResp = Invoke-RestMethod -Uri "http://localhost:$Port/v1/chat/completions" -Method Post -Body $chatBody -ContentType "application/json"
        if ($chatResp.choices) {
            Write-Host "Response: $($chatResp.choices[0].message.content)" -ForegroundColor Cyan
        } else {
             Write-Host "Response (Raw): $($chatResp | ConvertTo-Json -Depth 2)"
        }
    } catch {
        Write-Warning "Chat failed: $_"
    }

}
finally {
    # 5. Cleanup
    Write-Host "`nStopping Proxy..." -ForegroundColor Green
    # Capture any debug logs from the job before stopping
    $logs = Receive-Job -Job $job
    if ($logs) {
        Write-Host "--- Proxy Logs ---" -ForegroundColor Gray
        $logs | Select-Object -Last 10 # Show last 10 logs
    }

    Stop-Job -Job $job
    Remove-Job -Job $job
}
