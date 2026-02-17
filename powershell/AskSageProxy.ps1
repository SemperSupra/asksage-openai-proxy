#!/usr/bin/env pwsh
param (
    [int]$Port = 8080,
    [bool]$Debug = $false
)

# Add assemblies for PS 5.1 compatibility
try { Add-Type -AssemblyName System.Net.Http } catch {}

# Load environment variables
$env:ASKSAGE_SERVER_BASE = if ($env:ASKSAGE_SERVER_BASE) { $env:ASKSAGE_SERVER_BASE } else { "https://api.genai.army.mil/server/" }
$env:ASKSAGE_API_KEY = if ($env:ASKSAGE_API_KEY) { $env:ASKSAGE_API_KEY } else { "" }
$env:ASKSAGE_DEFAULT_MODEL = if ($env:ASKSAGE_DEFAULT_MODEL) { $env:ASKSAGE_DEFAULT_MODEL } else { "gpt-4o-mini" }
$env:ASKSAGE_DEFAULT_PERSONA = if ($env:ASKSAGE_DEFAULT_PERSONA) { $env:ASKSAGE_DEFAULT_PERSONA } else { "1" }
$env:ASKSAGE_DEFAULT_DATASET = if ($env:ASKSAGE_DEFAULT_DATASET) { $env:ASKSAGE_DEFAULT_DATASET } else { "none" }
$env:ASKSAGE_DEFAULT_LIVE = if ($env:ASKSAGE_DEFAULT_LIVE) { $env:ASKSAGE_DEFAULT_LIVE } else { "0" }
$env:ASKSAGE_DEFAULT_LIMIT_REFERENCES = if ($env:ASKSAGE_DEFAULT_LIMIT_REFERENCES) { $env:ASKSAGE_DEFAULT_LIMIT_REFERENCES } else { "0" }
$env:ASKSAGE_INCLUDE_USAGE = if ($env:ASKSAGE_INCLUDE_USAGE) { $env:ASKSAGE_INCLUDE_USAGE } else { "false" }
$env:ASKSAGE_VERIFY_TLS = if ($env:ASKSAGE_VERIFY_TLS) { $env:ASKSAGE_VERIFY_TLS } else { "true" }
$env:HTTP_TIMEOUT = if ($env:HTTP_TIMEOUT) { $env:HTTP_TIMEOUT } else { "120" }

# Initialize HttpClient
$handler = New-Object System.Net.Http.HttpClientHandler
if ($env:ASKSAGE_VERIFY_TLS -eq "false") {
    $handler.ServerCertificateCustomValidationCallback = { $true }
}
# Note: CA Bundle path support is harder in pure .NET without X509Certificate2 loading manually.
# For now, we respect verify_tls bool.

$httpClient = New-Object System.Net.Http.HttpClient($handler)
$httpClient.Timeout = [TimeSpan]::FromSeconds([double]$env:HTTP_TIMEOUT)

function Log-Debug {
    param([string]$Message)
    if ($script:Debug) {
        Write-Host "[DEBUG] $(Get-Date -Format 'HH:mm:ss') $Message" -ForegroundColor Cyan
    }
}

function Send-JsonResponse {
    param (
        [System.Net.HttpListenerResponse]$Response,
        [object]$Data,
        [int]$StatusCode = 200
    )
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json"
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
    $Response.OutputStream.Close()
}

function Send-ErrorResponse {
    param (
        [System.Net.HttpListenerResponse]$Response,
        [string]$Message,
        [int]$StatusCode = 500
    )
    $data = @{ error = $Message }
    Send-JsonResponse -Response $Response -Data $data -StatusCode $StatusCode
}

function Invoke-AskSageRequest {
    param(
        [string]$Path,
        [string]$Method = "POST",
        [object]$Payload = $null,
        [System.Net.Http.MultipartFormDataContent]$MultipartContent = $null,
        [switch]$ReturnBytes = $false
    )

    $url = "$($env:ASKSAGE_SERVER_BASE.TrimEnd('/'))/$($Path.TrimStart('/'))"
    Log-Debug "Upstream Request: $Method $url"

    $request = New-Object System.Net.Http.HttpRequestMessage
    $request.Method = [System.Net.Http.HttpMethod]::$Method
    $request.RequestUri = [Uri]$url

    if ($env:ASKSAGE_API_KEY) {
        $request.Headers.Add("x-access-tokens", $env:ASKSAGE_API_KEY)
    }

    if ($MultipartContent) {
        $request.Content = $MultipartContent
    }
    elseif ($Payload) {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress
        $request.Content = New-Object System.Net.Http.StringContent($json, [System.Text.Encoding]::UTF8, "application/json")
    }

    try {
        Log-Debug "Sending request..."
        $response = $httpClient.SendAsync($request).Result
        Log-Debug "Response received: $($response.StatusCode)"

        if ($ReturnBytes) {
            if (-not $response.IsSuccessStatusCode) {
                $content = ""
                if ($response.Content) {
                    $contentBytes = $response.Content.ReadAsByteArrayAsync().Result
                    $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
                }
                Log-Debug "Upstream Error: $($response.StatusCode) $content"
                throw "AskSage request failed: $($response.StatusCode) $content"
            }
            if ($response.Content) {
                return $response.Content.ReadAsByteArrayAsync().Result
            }
            return [byte[]]@()
        }

        $content = ""
        if ($response.Content) {
            $contentBytes = $response.Content.ReadAsByteArrayAsync().Result
            $content = [System.Text.Encoding]::UTF8.GetString($contentBytes)
        }

        if (-not $response.IsSuccessStatusCode) {
            Log-Debug "Upstream Error: $($response.StatusCode) $content"
            throw "AskSage request failed: $($response.StatusCode) $content"
        }

        # Check if content is JSON
        if ($response.Content -and $response.Content.Headers.ContentType -and $response.Content.Headers.ContentType.MediaType -eq "application/json") {
             return $content | ConvertFrom-Json
        }
        return $content
    }
    catch {
        Log-Debug "Exception: $_"
        throw
    }
}

function Parse-MultipartFormData {
    param([System.Net.HttpListenerRequest]$Request)

    $contentType = $Request.ContentType
    Log-Debug "Content-Type: $contentType"

    if ($contentType -notmatch "boundary=(.+)") {
        throw "Not multipart content"
    }
    # Handle quoted boundary
    $b = $matches[1]
    if ($b.StartsWith('"') -and $b.EndsWith('"')) {
        $b = $b.Substring(1, $b.Length - 2)
    }
    $boundary = "--" + $b

    $encoding = $Request.ContentEncoding
    $inputStream = $Request.InputStream
    $ms = New-Object System.IO.MemoryStream
    $inputStream.CopyTo($ms)
    $bytes = $ms.ToArray()
    $ms.Dispose()

    $latin1 = [System.Text.Encoding]::GetEncoding("iso-8859-1")
    $contentStr = $latin1.GetString($bytes)

    $parts = $contentStr -split [regex]::Escape($boundary)
    $result = @{
        files = @{}
        fields = @{}
    }

    Log-Debug "Parsing multipart content, parts count: $($parts.Count)"

    foreach ($part in $parts) {
        if (-not $part -or $part -eq "--`r`n") { continue }

        $p = $part.TrimStart("`r`n")
        $headerEnd = $p.IndexOf("`r`n`r`n")
        if ($headerEnd -lt 0) {
            Log-Debug "Part skipped: header end not found"
            continue
        }

        $headersRaw = $p.Substring(0, $headerEnd)
        $bodyRaw = $p.Substring($headerEnd + 4)

        if ($bodyRaw.EndsWith("`r`n")) {
            $bodyRaw = $bodyRaw.Substring(0, $bodyRaw.Length - 2)
        }

        $headers = @{}
        $headersRaw -split "`r`n" | ForEach-Object {
            if ($_ -match "^([^:]+):\s*(.*)$") {
                $headers[$matches[1]] = $matches[2]
            }
        }

        Log-Debug "Parsed Headers: $($headers | ConvertTo-Json -Compress)"

        $name = $null
        if ($headers["Content-Disposition"] -match 'name="?([^";]+)"?') {
            $name = $matches[1]
        }

        if ($name) {
            $filename = $null
            if ($headers["Content-Disposition"] -match 'filename="?([^";]+)"?') {
                $filename = $matches[1]
            }

            Log-Debug "Found part: name=$name, filename=$filename"

            $bodyBytes = $latin1.GetBytes($bodyRaw)

            if ($filename) {
                $result.files[$name] = @{
                    filename = $filename
                    content = $bodyBytes
                    contentType = if ($headers["Content-Type"]) { $headers["Content-Type"] } else { "application/octet-stream" }
                }
            } else {
                $result.fields[$name] = [System.Text.Encoding]::UTF8.GetString($bodyBytes)
            }
        } else {
            Log-Debug "Could not extract name from Content-Disposition: $($headers['Content-Disposition'])"
        }
    }
    return $result
}

function Convert-OpenAIMessagesToPrompt {
    param([object[]]$Messages)

    $systemParts = @()
    $convoParts = @()

    foreach ($m in $Messages) {
        $role = ($m.role -replace '\s','').ToLower()
        $content = $m.content

        # Handle content array (text/image parts)
        if ($content -is [Array]) {
            $textChunks = @()
            foreach ($part in $content) {
                if ($part.type -eq "text" -and $part.text) {
                    $textChunks += $part.text
                }
            }
            $contentStr = ($textChunks -join "`n").Trim()
        }
        else {
            $contentStr = if ($content) { "$content" } else { "" }
        }

        if ($role -eq "system") {
            if ($contentStr) { $systemParts += $contentStr }
        }
        elseif ($role -eq "user") {
            $convoParts += "User: $contentStr".Trim()
        }
        elseif ($role -eq "assistant") {
            $convoParts += "Assistant: $contentStr".Trim()
        }
        else {
            $convoParts += "User: $contentStr".Trim()
        }
    }

    $prompt = ""
    if ($systemParts.Count -gt 0) {
        $prompt += "System:`n" + ($systemParts -join "`n`n").Trim() + "`n`n"
    }
    $prompt += ($convoParts -join "`n").Trim()

    if ($prompt -and -not $prompt.EndsWith("`n")) {
        $prompt += "`n"
    }
    $prompt += "Assistant:"

    return $prompt
}

function Send-SseChunk {
    param(
        [System.IO.StreamWriter]$Writer,
        [string]$Model,
        [string]$Content,
        [bool]$Done = $false
    )

    $now = [int][double]::Parse((Get-Date -UFormat %s))
    if (-not $Done) {
        $chunk = @{
            id = "chatcmpl-$now"
            object = "chat.completion.chunk"
            created = $now
            model = $Model
            choices = @(@{
                index = 0
                delta = @{ role = "assistant"; content = $Content }
                finish_reason = $null
            })
        }
        $json = $chunk | ConvertTo-Json -Depth 10 -Compress
        $Writer.Write("data: $json`n`n")
    } else {
        $doneChunk = @{
            id = "chatcmpl-$now"
            object = "chat.completion.chunk"
            created = $now
            model = $Model
            choices = @(@{
                index = 0
                delta = @{}
                finish_reason = "stop"
            })
        }
        $json = $doneChunk | ConvertTo-Json -Depth 10 -Compress
        $Writer.Write("data: $json`n`n")
        $Writer.Write("data: [DONE]`n`n")
    }
    $Writer.Flush()
}

$listener = New-Object System.Net.HttpListener
# Use localhost on Windows to avoid admin requirement for URL reservation.
# Use * on Linux/Mac to allow container usage (user-level binding works for >1024).
# $IsWindows is available in PowerShell Core. On Windows PowerShell 5.1, check $env:OS.
if ($IsWindows -or ($env:OS -eq 'Windows_NT')) {
    $listener.Prefixes.Add("http://localhost:$Port/")
} else {
    $listener.Prefixes.Add("http://*:$Port/")
}

try {
    $listener.Start()
    Write-Host "Ask Sage OpenAI Proxy listening on port $Port..."
    Log-Debug "Server Base: $($env:ASKSAGE_SERVER_BASE)"

    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        Log-Debug "Request: $($request.HttpMethod) $($request.Url.AbsolutePath)"

        try {
            # Normalize path
            $path = $request.Url.AbsolutePath.TrimEnd('/')

            if ($path -eq "/healthz") {
                $data = @{
                    status = "ok"
                    service = "asksage-openai-proxy-powershell"
                    time = [int][double]::Parse((Get-Date -UFormat %s))
                    asksage_server_base = $env:ASKSAGE_SERVER_BASE
                    tls_verify = $env:ASKSAGE_VERIFY_TLS
                }
                Send-JsonResponse -Response $response -Data $data
            }
            elseif ($path -eq "/v1/models") {
                # GET /v1/models
                $sageData = Invoke-AskSageRequest -Path "get-models" -Method "POST" -Payload @{}

                $models = @()
                if ($sageData.data) {
                    foreach ($m in $sageData.data) {
                        $mid = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { "unknown" }
                        $models += @{
                            id = $mid
                            object = "model"
                            owned_by = if ($m.owned_by) { $m.owned_by } else { "asksage" }
                        }
                    }
                }

                $out = @{
                    object = "list"
                    data = $models
                }
                Send-JsonResponse -Response $response -Data $out
            }
            elseif ($path -match "^/v1/models/(.+)$") {
                # GET /v1/models/{model}
                $modelId = $matches[1]
                $sageData = Invoke-AskSageRequest -Path "get-models" -Method "POST" -Payload @{}

                $found = $null
                if ($sageData.data) {
                    foreach ($m in $sageData.data) {
                        $mid = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { "unknown" }
                        if ($mid -eq $modelId) {
                            $found = @{
                                id = $mid
                                object = "model"
                                owned_by = if ($m.owned_by) { $m.owned_by } else { "asksage" }
                            }
                            break
                        }
                    }
                }

                if ($found) {
                    Send-JsonResponse -Response $response -Data $found
                } else {
                    Send-ErrorResponse -Response $response -Message "Model not found" -StatusCode 404
                }
            }
            elseif ($path -eq "/v1/chat/completions") {
                if ($request.HttpMethod -ne "POST") {
                    Send-ErrorResponse -Response $response -Message "Method Not Allowed" -StatusCode 405
                    continue
                }

                # Parse Body
                $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $bodyStr = $reader.ReadToEnd()
                if (-not $bodyStr) {
                    Send-ErrorResponse -Response $response -Message "Empty body" -StatusCode 400
                    continue
                }
                $body = $bodyStr | ConvertFrom-Json

                $model = if ($body.model) { $body.model } else { $env:ASKSAGE_DEFAULT_MODEL }
                $messages = if ($body.messages) { $body.messages } else { @() }
                $temperature = if ($body.temperature -ne $null) { $body.temperature } else { $null }
                $stream = if ($body.stream) { [bool]$body.stream } else { $false }

                $asksage_cfg = if ($body.asksage) { $body.asksage } else { @{} }
                $persona = if ($asksage_cfg.persona) { $asksage_cfg.persona } else { $env:ASKSAGE_DEFAULT_PERSONA }
                $dataset = if ($asksage_cfg.dataset) { $asksage_cfg.dataset } else { $env:ASKSAGE_DEFAULT_DATASET }
                $live = if ($asksage_cfg.live) { $asksage_cfg.live } else { $env:ASKSAGE_DEFAULT_LIVE }
                $limit_references = if ($asksage_cfg.limit_references) { $asksage_cfg.limit_references } else { $env:ASKSAGE_DEFAULT_LIMIT_REFERENCES }
                $system_prompt = if ($asksage_cfg.system_prompt) { $asksage_cfg.system_prompt } else { $null }
                $usage_flag = if ($asksage_cfg.usage) { $asksage_cfg.usage } else { $env:ASKSAGE_INCLUDE_USAGE }

                if (-not $messages) {
                     Send-ErrorResponse -Response $response -Message "Missing required field: messages[]" -StatusCode 400
                     continue
                }

                $prompt = Convert-OpenAIMessagesToPrompt -Messages $messages

                $payload = @{
                    message = $prompt
                    model = $model
                    persona = [int]$persona
                    dataset = $dataset
                    limit_references = [int]$limit_references
                    live = [int]$live
                    usage = [bool]$usage_flag
                }

                if ($temperature -ne $null) { $payload.temperature = [float]$temperature }
                if ($system_prompt) { $payload.system_prompt = [string]$system_prompt }

                $sageData = Invoke-AskSageRequest -Path "query" -Method "POST" -Payload $payload

                # Extract content
                $content = $null
                if ($sageData.message) {
                    $content = $sageData.message
                } elseif ($sageData.response) {
                    $content = $sageData.response
                } else {
                    $content = $sageData | ConvertTo-Json -Depth 5 -Compress
                }

                $usage = if ($sageData.usage) { $sageData.usage } else { $null }

                if ($stream) {
                    $response.StatusCode = 200
                    $response.ContentType = "text/event-stream"
                    $response.AddHeader("Cache-Control", "no-cache")
                    $response.AddHeader("Connection", "keep-alive")

                    $writer = New-Object System.IO.StreamWriter($response.OutputStream, [System.Text.Encoding]::UTF8)

                    Send-SseChunk -Writer $writer -Model $model -Content $content -Done $false
                    Send-SseChunk -Writer $writer -Model $model -Content "" -Done $true

                    $writer.Close()
                } else {
                    $now = [int][double]::Parse((Get-Date -UFormat %s))
                    $out = @{
                        id = "chatcmpl-$now"
                        object = "chat.completion"
                        created = $now
                        model = $model
                        choices = @(@{
                            index = 0
                            message = @{ role = "assistant"; content = $content }
                            finish_reason = "stop"
                        })
                    }
                    if ($usage) { $out.usage = $usage }
                    Send-JsonResponse -Response $response -Data $out
                }
            }
            elseif ($path -eq "/v1/audio/speech") {
                if ($request.HttpMethod -ne "POST") {
                    Send-ErrorResponse -Response $response -Message "Method Not Allowed" -StatusCode 405
                    continue
                }

                $reader = New-Object System.IO.StreamReader($request.InputStream, $request.ContentEncoding)
                $body = $reader.ReadToEnd() | ConvertFrom-Json

                $input_text = $body.input
                if (-not $input_text) {
                     Send-ErrorResponse -Response $response -Message "Missing required field: input" -StatusCode 400
                     continue
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

                $audioBytes = Invoke-AskSageRequest -Path "get-text-to-speech" -Method "POST" -Payload $payload -ReturnBytes

                $response.StatusCode = 200
                $response.ContentType = "audio/mpeg"
                $response.ContentLength64 = $audioBytes.Length
                $response.OutputStream.Write($audioBytes, 0, $audioBytes.Length)
                $response.OutputStream.Close()
            }
            elseif ($path -eq "/v1/audio/transcriptions") {
                if ($request.HttpMethod -ne "POST") {
                    Send-ErrorResponse -Response $response -Message "Method Not Allowed" -StatusCode 405
                    continue
                }

                # Parse Multipart
                try {
                    $formData = Parse-MultipartFormData -Request $request
                } catch {
                     Send-ErrorResponse -Response $response -Message "Invalid multipart request: $_" -StatusCode 400
                     continue
                }

                if (-not $formData.files["file"]) {
                     Send-ErrorResponse -Response $response -Message "Missing required file" -StatusCode 400
                     continue
                }

                $file = $formData.files["file"]

                # Create Multipart Content for Upstream
                $multipartContent = New-Object System.Net.Http.MultipartFormDataContent
                # Use ::new to avoid array unraveling issues in New-Object
                $fileContent = [System.Net.Http.ByteArrayContent]::new($file.content)
                $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($file.contentType)
                $multipartContent.Add($fileContent, "file", $file.filename)

                $sageData = Invoke-AskSageRequest -Path "file" -Method "POST" -MultipartContent $multipartContent
                $multipartContent.Dispose()

                $text = if ($sageData.ret) { $sageData.ret } elseif ($sageData.response) { $sageData.response } else { "" }

                Send-JsonResponse -Response $response -Data @{ text = $text }
            }
            else {
                Send-ErrorResponse -Response $response -Message "Not Found" -StatusCode 404
            }
        }
        catch {
            Write-Error $_
            Send-ErrorResponse -Response $response -Message $_.Exception.Message -StatusCode 500
        }
    }
}
finally {
    $listener.Stop()
    $listener.Close()
    $httpClient.Dispose()
}
