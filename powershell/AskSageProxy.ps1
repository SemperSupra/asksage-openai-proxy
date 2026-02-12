<#
.SYNOPSIS
    Ask Sage OpenAI-Compatible Proxy (PowerShell 5.1)

.DESCRIPTION
    A simple HTTP proxy that forwards OpenAI-compatible requests to the Ask Sage Server API.
    Endpoints implemented:
      - GET /healthz
      - GET /v1/models
      - GET /v1/models/{model}
      - POST /v1/chat/completions (streaming supported)
      - POST /v1/audio/speech

    Configuration is done via environment variables.

.EXAMPLE
    $env:ASKSAGE_API_KEY = "your-api-key"
    .\AskSageProxy.ps1 -Port 8000
#>

param(
    [int]$Port = 8000
)

# -----------------------------------------------------------------------------
# 1. Configuration & Setup
# -----------------------------------------------------------------------------

# Helper to get env var with default
function Get-EnvVar {
    param($Name, $Default)
    if (Test-Path "env:$Name") {
        return (Get-Item "env:$Name").Value
    }
    return $Default
}

function Get-EnvBool {
    param($Name, $Default)
    $val = Get-EnvVar -Name $Name -Default ""
    if ([string]::IsNullOrWhiteSpace($val)) { return $Default }
    return $val -in @("1", "true", "yes", "y", "on")
}

$ASKSAGE_SERVER_BASE = (Get-EnvVar "ASKSAGE_SERVER_BASE" "https://api.genai.army.mil/server/").TrimEnd("/") + "/"
$ASKSAGE_API_KEY = Get-EnvVar "ASKSAGE_API_KEY" ""
$ASKSAGE_DEFAULT_MODEL = Get-EnvVar "ASKSAGE_DEFAULT_MODEL" "gpt-4o-mini"
$ASKSAGE_DEFAULT_PERSONA = [int](Get-EnvVar "ASKSAGE_DEFAULT_PERSONA" "1")
$ASKSAGE_DEFAULT_DATASET = Get-EnvVar "ASKSAGE_DEFAULT_DATASET" "none"
$ASKSAGE_DEFAULT_LIVE = [int](Get-EnvVar "ASKSAGE_DEFAULT_LIVE" "0")
$ASKSAGE_DEFAULT_LIMIT_REFERENCES = [int](Get-EnvVar "ASKSAGE_DEFAULT_LIMIT_REFERENCES" "0")
$ASKSAGE_INCLUDE_USAGE = Get-EnvBool "ASKSAGE_INCLUDE_USAGE" $false
$ASKSAGE_VERIFY_TLS = Get-EnvBool "ASKSAGE_VERIFY_TLS" $true
$HTTP_TIMEOUT = [double](Get-EnvVar "HTTP_TIMEOUT" "120")

# Load required assemblies
Add-Type -AssemblyName System.Net.Http

# Configure TLS validation
if (-not $ASKSAGE_VERIFY_TLS) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
}

# Create shared HttpClient
$HttpClientHandler = New-Object System.Net.Http.HttpClientHandler
$HttpClient = New-Object System.Net.Http.HttpClient($HttpClientHandler)
$HttpClient.Timeout = [TimeSpan]::FromSeconds($HTTP_TIMEOUT)


# -----------------------------------------------------------------------------
# 2. Helper Functions
# -----------------------------------------------------------------------------

function Get-EpochTime {
    return [int][double]::Parse((Get-Date -UFormat %s))
}

function Convert-OpenAIMessagesToPrompt {
    param([array]$Messages)

    $SystemParts = @()
    $ConvoParts = @()

    foreach ($m in $Messages) {
        $role = if ($m.role) { $m.role.ToLower() } else { "" }
        $content = $m.content

        # Handle list content (text/image parts) - keep text only
        $contentStr = ""
        if ($content -is [array] -or $content -is [System.Collections.ArrayList]) {
            $textChunks = @()
            foreach ($part in $content) {
                if ($part -is [System.Management.Automation.PSCustomObject] -or $part -is [System.Collections.Hashtable]) {
                    if ($part.type -eq "text" -and $part.text) {
                        $textChunks += $part.text
                    }
                }
            }
            $contentStr = ($textChunks -join "`n").Trim()
        } else {
            if ($content) { $contentStr = [string]$content }
        }

        if ($role -eq "system") {
            if ($contentStr) { $SystemParts += $contentStr }
        } elseif ($role -eq "user") {
            $ConvoParts += "User: $contentStr".Trim()
        } elseif ($role -eq "assistant") {
            $ConvoParts += "Assistant: $contentStr".Trim()
        } else {
            # fallback
            $ConvoParts += "User: $contentStr".Trim()
        }
    }

    $prompt = ""
    if ($SystemParts.Count -gt 0) {
        $prompt += "System:`n" + ($SystemParts -join "`n`n").Trim() + "`n`n"
    }
    $prompt += ($ConvoParts -join "`n").Trim()

    if ($prompt.Length -gt 0 -and -not $prompt.EndsWith("`n")) {
        $prompt += "`n"
    }
    $prompt += "Assistant:"

    return $prompt
}

function Invoke-AskSageRequest {
    param(
        [string]$Path,
        [string]$Method = "POST",
        [hashtable]$Payload,
        [switch]$ReturnBytes
    )

    if (-not $ASKSAGE_API_KEY) {
        throw "ASKSAGE_API_KEY is not set"
    }

    $url = $ASKSAGE_SERVER_BASE + $Path.TrimStart("/")

    $req = New-Object System.Net.Http.HttpRequestMessage
    $req.Method = [System.Net.Http.HttpMethod]::$Method
    $req.RequestUri = [Uri]$url
    $req.Headers.Add("x-access-tokens", $ASKSAGE_API_KEY)

    if ($Payload) {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress
        $req.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, "application/json")
    }

    try {
        $task = $HttpClient.SendAsync($req)
        $task.Wait()
        $resp = $task.Result

        if (-not $resp.IsSuccessStatusCode) {
            $errContent = $resp.Content.ReadAsStringAsync().Result
            throw "AskSage request failed: $($resp.StatusCode) $errContent"
        }

        if ($ReturnBytes) {
            return $resp.Content.ReadAsByteArrayAsync().Result
        } else {
            $jsonResp = $resp.Content.ReadAsStringAsync().Result
            return ($jsonResp | ConvertFrom-Json)
        }
    } catch {
        throw $_
    }
}

function Send-JsonResponse {
    param($Context, $Data, [int]$StatusCode = 200)
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Context.Response.StatusCode = $StatusCode
    $Context.Response.ContentType = "application/json"
    $Context.Response.ContentLength64 = $buffer.Length
    $Context.Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Context.Response.Close()
}

function Send-ErrorResponse {
    param($Context, $Message, [int]$StatusCode = 500)
    $err = @{ error = @{ message = $Message; type = "server_error" } }
    Send-JsonResponse -Context $Context -Data $err -StatusCode $StatusCode
}

# -----------------------------------------------------------------------------
# 3. Request Handlers
# -----------------------------------------------------------------------------

function Handle-Healthz {
    param($Context)
    $data = @{
        status = "ok"
        service = "asksage-openai-proxy-pwsh"
        time = Get-EpochTime
        asksage_server_base = $ASKSAGE_SERVER_BASE
        tls_verify = $ASKSAGE_VERIFY_TLS
    }
    Send-JsonResponse -Context $Context -Data $data
}

function Handle-Models {
    param($Context, $ModelId)
    try {
        $data = Invoke-AskSageRequest -Path "get-models" -Payload @{}
        $models = @()

        $sourceData = if ($data.data) { $data.data } else { @() }

        foreach ($m in $sourceData) {
            $mid = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { "unknown" }
            $models += @{
                id = $mid
                object = "model"
                owned_by = if ($m.owned_by) { $m.owned_by } else { "asksage" }
            }
        }

        if ($ModelId) {
            $found = $models | Where-Object { $_.id -eq $ModelId }
            if ($found) {
                Send-JsonResponse -Context $Context -Data $found
            } else {
                Send-ErrorResponse -Context $Context -Message "Model not found" -StatusCode 404
            }
        } else {
            Send-JsonResponse -Context $Context -Data @{ object = "list"; data = $models }
        }
    } catch {
        Send-ErrorResponse -Context $Context -Message "$_"
    }
}

function Handle-ChatCompletions {
    param($Context)
    try {
        $reqBody = $Context.Request.InputStream
        $reader = New-Object System.IO.StreamReader($reqBody, $Context.Request.ContentEncoding)
        $json = $reader.ReadToEnd()
        $body = $json | ConvertFrom-Json

        if (-not $body.messages) {
            Send-ErrorResponse -Context $Context -Message "Missing required field: messages[]" -StatusCode 400
            return
        }

        $model = if ($body.model) { $body.model } else { $ASKSAGE_DEFAULT_MODEL }
        $temperature = if ($body.temperature) { $body.temperature } else { $null }
        $stream = if ($body.stream) { [bool]$body.stream } else { $false }

        # Ask Sage Config
        $asksage = if ($body.asksage) { $body.asksage } else { @{} }
        $persona = if ($asksage.persona) { [int]$asksage.persona } else { $ASKSAGE_DEFAULT_PERSONA }
        $dataset = if ($asksage.dataset) { $asksage.dataset } else { $ASKSAGE_DEFAULT_DATASET }
        $live = if ($asksage.live) { [int]$asksage.live } else { $ASKSAGE_DEFAULT_LIVE }
        $limit_references = if ($asksage.limit_references) { [int]$asksage.limit_references } else { $ASKSAGE_DEFAULT_LIMIT_REFERENCES }
        $system_prompt = if ($asksage.system_prompt) { $asksage.system_prompt } else { $null }
        $usage_flag = if ($asksage.usage) { [bool]$asksage.usage } else { $ASKSAGE_INCLUDE_USAGE }

        $prompt = Convert-OpenAIMessagesToPrompt -Messages $body.messages

        $payload = @{
            message = $prompt
            model = $model
            persona = $persona
            dataset = $dataset
            limit_references = $limit_references
            live = $live
            usage = $usage_flag
        }

        if ($temperature -ne $null) { $payload["temperature"] = [float]$temperature }
        if ($system_prompt) { $payload["system_prompt"] = $system_prompt }

        # Call Ask Sage
        $respData = Invoke-AskSageRequest -Path "query" -Payload $payload

        # Extract content
        $content = if ($respData.message) { $respData.message } else {
            if ($respData.response) { $respData.response } else { $respData | ConvertTo-Json -Depth 2 -Compress }
        }

        $usage = if ($respData.usage) { $respData.usage } else { $null }
        $created = Get-EpochTime

        if ($stream) {
            # SSE Streaming
            $Context.Response.StatusCode = 200
            $Context.Response.ContentType = "text/event-stream"
            $Context.Response.AddHeader("Cache-Control", "no-cache")
            $Context.Response.AddHeader("Connection", "keep-alive")

            $writer = New-Object System.IO.StreamWriter($Context.Response.OutputStream, [System.Text.Encoding]::UTF8)
            $writer.AutoFlush = $true

            # Chunk 1: Content
            $chunk = @{
                id = "chatcmpl-$created"
                object = "chat.completion.chunk"
                created = $created
                model = $model
                choices = @(
                    @{ index = 0; delta = @{ role = "assistant"; content = $content }; finish_reason = $null }
                )
            }
            $writer.Write("data: " + ($chunk | ConvertTo-Json -Depth 10 -Compress) + "`n`n")

            # Chunk 2: Done/Stop
            $doneChunk = @{
                id = "chatcmpl-$created"
                object = "chat.completion.chunk"
                created = $created
                model = $model
                choices = @(
                    @{ index = 0; delta = @{}; finish_reason = "stop" }
                )
            }
            $writer.Write("data: " + ($doneChunk | ConvertTo-Json -Depth 10 -Compress) + "`n`n")
            $writer.Write("data: [DONE]`n`n")

            $writer.Close()
            $Context.Response.Close()

        } else {
            # Regular Response
            $out = @{
                id = "chatcmpl-$created"
                object = "chat.completion"
                created = $created
                model = $model
                choices = @(
                    @{
                        index = 0
                        message = @{ role = "assistant"; content = $content }
                        finish_reason = "stop"
                    }
                )
            }
            if ($usage) { $out["usage"] = $usage }
            Send-JsonResponse -Context $Context -Data $out
        }

    } catch {
        Send-ErrorResponse -Context $Context -Message "$_"
    }
}

function Handle-AudioSpeech {
    param($Context)
    try {
        $reqBody = $Context.Request.InputStream
        $reader = New-Object System.IO.StreamReader($reqBody, $Context.Request.ContentEncoding)
        $json = $reader.ReadToEnd()
        $body = $json | ConvertFrom-Json

        $input_text = $body.input
        if (-not $input_text) {
            Send-ErrorResponse -Context $Context -Message "Missing required field: input" -StatusCode 400
            return
        }

        $voice = if ($body.voice) { $body.voice } else { "alloy" }
        $model = if ($body.model) { $body.model } else { "tts-1" }

        $asksage_model = "tts"
        if ($model -eq "tts-1-hd") { $asksage_model = "tts-hd" }

        $payload = @{
            text = $input_text
            voice = $voice
            model = $asksage_model
        }

        $audioBytes = Invoke-AskSageRequest -Path "get-text-to-speech" -Payload $payload -ReturnBytes

        $Context.Response.StatusCode = 200
        $Context.Response.ContentType = "audio/mpeg"
        $Context.Response.ContentLength64 = $audioBytes.Length
        $Context.Response.OutputStream.Write($audioBytes, 0, $audioBytes.Length)
        $Context.Response.Close()

    } catch {
        Send-ErrorResponse -Context $Context -Message "$_"
    }
}

# -----------------------------------------------------------------------------
# 4. Main Server Loop
# -----------------------------------------------------------------------------

$Listener = New-Object System.Net.HttpListener
$Listener.Prefixes.Add("http://*:$Port/")

try {
    $Listener.Start()
    Write-Host "Ask Sage Proxy listening on http://*:$Port/"
    Write-Host "Press Ctrl+C to stop."

    while ($Listener.IsListening) {
        $Context = $Listener.GetContext() # Blocks until request received

        $path = $Context.Request.Url.AbsolutePath
        $method = $Context.Request.HttpMethod

        Write-Host "Request: $method $path"

        # Routing
        if ($method -eq "GET" -and $path -eq "/healthz") {
            Handle-Healthz -Context $Context
        } elseif ($method -eq "GET" -and $path -eq "/v1/models") {
            Handle-Models -Context $Context
        } elseif ($method -eq "GET" -and $path -match "^/v1/models/(.+)$") {
             $modelId = $matches[1]
             Handle-Models -Context $Context -ModelId $modelId
        } elseif ($method -eq "POST" -and $path -eq "/v1/chat/completions") {
            Handle-ChatCompletions -Context $Context
        } elseif ($method -eq "POST" -and $path -eq "/v1/audio/speech") {
            Handle-AudioSpeech -Context $Context
        } else {
            Send-ErrorResponse -Context $Context -Message "Not Found" -StatusCode 404
        }
    }
} catch {
    Write-Error $_
} finally {
    $Listener.Stop()
    $HttpClient.Dispose()
}
