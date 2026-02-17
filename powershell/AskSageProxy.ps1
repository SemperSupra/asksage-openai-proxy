# powershell/AskSageProxy.ps1

param (
    [string]$Port = $env:ASKSAGE_PROXY_PORT,
    [string]$ServerBase = $env:ASKSAGE_SERVER_BASE,
    [string]$ApiKey = $env:ASKSAGE_API_KEY
)

# Ensure required assemblies are loaded
Add-Type -AssemblyName System.Net.Http

if (-not $Port) { $Port = "8000" }
if (-not $ServerBase) { $ServerBase = "https://api.genai.army.mil/server/" }
# Ensure trailing slash for base
if (-not $ServerBase.EndsWith("/")) { $ServerBase += "/" }

# Helper to write JSON response
function Write-JsonResponse {
    param(
        $Response,
        $StatusCode = 200,
        $Data
    )
    $Response.StatusCode = $StatusCode
    $Response.ContentType = "application/json"
    $json = $Data | ConvertTo-Json -Depth 10 -Compress
    $buffer = [System.Text.Encoding]::UTF8.GetBytes($json)
    $Response.ContentLength64 = $buffer.Length
    $Response.OutputStream.Write($buffer, 0, $buffer.Length)
}

function Convert-OpenAIMessagesToPrompt {
    param($Messages)
    $systemParts = @()
    $convoParts = @()

    foreach ($m in $Messages) {
        $role = if ($m.role) { $m.role.ToLower() } else { "" }
        $content = $m.content

        # Handle content list (text/image) - simple check if it's an array
        if ($content -is [System.Collections.IList] -or $content -is [Array]) {
            $textChunks = @()
            foreach ($part in $content) {
                # Access hashtable or object properties
                if ($part.type -eq "text" -and $part.text) {
                    $textChunks += [string]$part.text
                }
            }
            $contentStr = $textChunks -join "`n"
        } else {
            $contentStr = if ($content) { [string]$content } else { "" }
        }
        $contentStr = $contentStr.Trim()

        if ($role -eq "system") {
            if ($contentStr) { $systemParts += $contentStr }
        } elseif ($role -eq "user") {
            $convoParts += "User: $contentStr"
        } elseif ($role -eq "assistant") {
            $convoParts += "Assistant: $contentStr"
        } else {
            # unknown role -> treat as user
            $convoParts += "User: $contentStr"
        }
    }

    $prompt = ""
    if ($systemParts.Count -gt 0) {
        $prompt += "System:`n" + ($systemParts -join "`n`n") + "`n`n"
    }
    $prompt += ($convoParts -join "`n")

    if ($prompt -and -not $prompt.EndsWith("`n")) {
        $prompt += "`n"
    }
    $prompt += "Assistant:"

    return $prompt
}

# Create a shared HttpClient
$httpClient = [System.Net.Http.HttpClient]::new()
# Set timeout if needed, default is usually 100s
if ($env:HTTP_TIMEOUT) {
    $httpClient.Timeout = [TimeSpan]::FromSeconds([double]$env:HTTP_TIMEOUT)
} else {
    $httpClient.Timeout = [TimeSpan]::FromSeconds(120)
}

# Function to Invoke Ask Sage API (JSON)
function Invoke-AskSageRequest {
    param(
        [string]$Path,
        [hashtable]$Payload,
        [string]$Method = "POST"
    )

    if (-not $ApiKey) {
        throw "ASKSAGE_API_KEY is not set"
    }

    $url = "${ServerBase}$($Path.TrimStart('/'))"

    $requestMsg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]$Method, $url)
    $requestMsg.Headers.Add("x-access-tokens", $ApiKey)
    $requestMsg.Headers.Add("Accept", "application/json")

    if ($Payload) {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress
        $requestMsg.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
    }

    # Synchronous call
    $responseMsg = $httpClient.SendAsync($requestMsg).GetAwaiter().GetResult()

    $contentBytes = $responseMsg.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $contentStr = [System.Text.Encoding]::UTF8.GetString($contentBytes)

    $data = $null
    try {
        $data = $contentStr | ConvertFrom-Json
    } catch {
        $data = @{ raw = $contentStr }
    }

    if (-not $responseMsg.IsSuccessStatusCode) {
        throw @{
            status = [int]$responseMsg.StatusCode
            detail = @{
                error = "AskSage request failed"
                asksage_status = [int]$responseMsg.StatusCode
                asksage_response = $data
            }
        }
    }

    return $data
}

# Function to Invoke Ask Sage API and return Bytes (for TTS)
function Invoke-AskSageRequestBytes {
    param(
        [string]$Path,
        [hashtable]$Payload,
        [string]$Method = "POST"
    )
    if (-not $ApiKey) { throw "ASKSAGE_API_KEY is not set" }
    $url = "${ServerBase}$($Path.TrimStart('/'))"

    $requestMsg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]$Method, $url)
    $requestMsg.Headers.Add("x-access-tokens", $ApiKey)
    $requestMsg.Headers.Add("Accept", "application/json") # Ask Sage might default to JSON, but for TTS it returns bytes

    if ($Payload) {
        $json = $Payload | ConvertTo-Json -Depth 10 -Compress
        $requestMsg.Content = [System.Net.Http.StringContent]::new($json, [System.Text.Encoding]::UTF8, "application/json")
    }

    $responseMsg = $httpClient.SendAsync($requestMsg).GetAwaiter().GetResult()

    if (-not $responseMsg.IsSuccessStatusCode) {
        $contentStr = $responseMsg.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        throw "AskSage request failed: $($responseMsg.StatusCode) $contentStr"
    }

    return $responseMsg.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
}

# Function to Invoke Ask Sage API with Multipart (for Transcriptions)
function Invoke-AskSageMultipartRequest {
    param(
        [string]$Path,
        [hashtable]$FilePart # { filename, content (bytes), contentType }
    )
    if (-not $ApiKey) { throw "ASKSAGE_API_KEY is not set" }
    $url = "${ServerBase}$($Path.TrimStart('/'))"

    $content = [System.Net.Http.MultipartFormDataContent]::new()

    $fileContent = [System.Net.Http.ByteArrayContent]::new($FilePart.content)
    if ($FilePart.contentType) {
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse($FilePart.contentType)
    }
    $content.Add($fileContent, "file", $FilePart.filename)

    $requestMsg = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, $url)
    $requestMsg.Headers.Add("x-access-tokens", $ApiKey)
    $requestMsg.Content = $content

    $responseMsg = $httpClient.SendAsync($requestMsg).GetAwaiter().GetResult()
    $respBytes = $responseMsg.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    $respStr = [System.Text.Encoding]::UTF8.GetString($respBytes)

    try {
        return $respStr | ConvertFrom-Json
    } catch {
        return @{ raw = $respStr }
    }
}

# Helper to parse multipart request
function Parse-MultipartRequest {
    param($Request)

    $contentType = $Request.ContentType
    if (-not $contentType -or -not $contentType.StartsWith("multipart/form-data")) {
        throw "Content-Type is not multipart/form-data"
    }

    # Wrap InputStream in StreamContent
    $streamContent = [System.Net.Http.StreamContent]::new($Request.InputStream)
    $streamContent.Headers.Add("Content-Type", $contentType)

    $provider = [System.Net.Http.MultipartMemoryStreamProvider]::new()
    # Synchronously wait for task
    $streamContent.ReadAsMultipartAsync($provider).Wait()

    $parts = @{}

    foreach ($content in $provider.Contents) {
        $disposition = $content.Headers.ContentDisposition
        $name = if ($disposition.Name) { $disposition.Name.Trim('"') } else { "" }
        $filename = if ($disposition.FileName) { $disposition.FileName.Trim('"') } else { $null }

        if ($filename) {
            $bytes = $content.ReadAsByteArrayAsync().Result
            $parts[$name] = @{
                filename = $filename
                content = $bytes
                contentType = if ($content.Headers.ContentType) { $content.Headers.ContentType.MediaType } else { "application/octet-stream" }
            }
        } else {
            $str = $content.ReadAsStringAsync().Result
            $parts[$name] = $str
        }
    }

    return $parts
}


# Start Listener
$listener = [System.Net.HttpListener]::new()
$prefixesToTry = @("http://*:${Port}/", "http://localhost:${Port}/")
$bound = $false
foreach ($prefix in $prefixesToTry) {
    try {
        $listener.Prefixes.Clear()
        $listener.Prefixes.Add($prefix)
        $listener.Start()
        Write-Host "Ask Sage OpenAI Proxy listening on $prefix"
        $bound = $true
        break
    } catch {
        Write-Warning "Could not bind to $prefix : $_"
    }
}

if (-not $bound) {
    Write-Error "Failed to start listener. On Windows, ensure you are running as Administrator to bind to '*' or use a different port."
    exit 1
}

try {
    while ($listener.IsListening) {
        $context = $listener.GetContext()
        $request = $context.Request
        $response = $context.Response

        $path = $request.Url.AbsolutePath
        $method = $request.HttpMethod

        Write-Host "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] $method $path"

        try {
            # Route: GET /healthz
            if ($method -eq "GET" -and $path -eq "/healthz") {
                $epoch = [int][double]::Parse((Get-Date -UFormat %s))
                $payload = @{
                    status = "ok"
                    service = "asksage-openai-proxy"
                    time = $epoch
                    asksage_server_base = $ServerBase
                }
                Write-JsonResponse -Response $response -Data $payload
            }
            # Route: GET /v1/models
            elseif ($method -eq "GET" -and ($path -eq "/v1/models" -or $path -eq "/v1/models/")) {
                $data = Invoke-AskSageRequest -Path "get-models" -Method "POST" -Payload @{}

                $models = @()
                if ($data.data) {
                    foreach ($m in $data.data) {
                        $mid = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { "unknown" }
                        $models += @{
                            id = $mid
                            object = "model"
                            owned_by = if ($m.owned_by) { $m.owned_by } else { "asksage" }
                        }
                    }
                }

                Write-JsonResponse -Response $response -Data @{
                    object = "list"
                    data = $models
                }
            }
            # Route: GET /v1/models/{model}
            elseif ($method -eq "GET" -and $path -like "/v1/models/*") {
                $modelName = $path.Substring("/v1/models/".Length)
                $data = Invoke-AskSageRequest -Path "get-models" -Method "POST" -Payload @{}

                $found = $false
                if ($data.data) {
                    foreach ($m in $data.data) {
                        $mid = if ($m.id) { $m.id } elseif ($m.name) { $m.name } else { "unknown" }
                        if ($mid -eq $modelName) {
                            $foundData = @{
                                id = $mid
                                object = "model"
                                owned_by = if ($m.owned_by) { $m.owned_by } else { "asksage" }
                            }
                            Write-JsonResponse -Response $response -Data $foundData
                            $found = $true
                            break
                        }
                    }
                }

                if (-not $found) {
                    Write-JsonResponse -Response $response -StatusCode 404 -Data @{ error = "Model not found" }
                }
            }
            # Route: POST /v1/chat/completions
            elseif ($method -eq "POST" -and ($path -eq "/v1/chat/completions" -or $path -eq "/v1/chat/completions/")) {
                # Parse Body
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $bodyStr = $reader.ReadToEnd()
                $body = $bodyStr | ConvertFrom-Json

                $model = if ($body.model) { $body.model } else { $env:ASKSAGE_DEFAULT_MODEL }
                if (-not $model) { $model = "gpt-4o-mini" }

                $messages = $body.messages
                if (-not $messages) {
                    Write-JsonResponse -Response $response -StatusCode 400 -Data @{ error = "Missing required field: messages[]" }
                    continue
                }

                $prompt = Convert-OpenAIMessagesToPrompt -Messages $messages

                # Configs
                $asksageCfg = if ($body.asksage) { $body.asksage } else { @{} }

                $persona = if ($asksageCfg.persona) { $asksageCfg.persona } else { $env:ASKSAGE_DEFAULT_PERSONA }
                if (-not $persona) { $persona = 1 }

                $dataset = if ($asksageCfg.dataset) { $asksageCfg.dataset } else { $env:ASKSAGE_DEFAULT_DATASET }
                if (-not $dataset) { $dataset = "none" }

                $live = if ($asksageCfg.live) { $asksageCfg.live } else { $env:ASKSAGE_DEFAULT_LIVE }
                if (-not $live) { $live = 0 }

                $limitRefs = if ($asksageCfg.limit_references) { $asksageCfg.limit_references } else { $env:ASKSAGE_DEFAULT_LIMIT_REFERENCES }
                if (-not $limitRefs) { $limitRefs = 0 }

                $usageFlag = if ($asksageCfg.usage -ne $null) { $asksageCfg.usage } else {
                    if ($env:ASKSAGE_INCLUDE_USAGE -eq "true" -or $env:ASKSAGE_INCLUDE_USAGE -eq "1") { $true } else { $false }
                }

                $payload = @{
                    message = $prompt
                    model = $model
                    persona = [int]$persona
                    dataset = $dataset
                    limit_references = [int]$limitRefs
                    live = [int]$live
                    usage = [bool]$usageFlag
                }

                if ($body.temperature -ne $null) {
                    $payload.temperature = [double]$body.temperature
                }
                if ($asksageCfg.system_prompt) {
                    $payload.system_prompt = [string]$asksageCfg.system_prompt
                }

                $askRes = Invoke-AskSageRequest -Path "query" -Payload $payload

                # Extract content
                $content = $askRes.message
                if (-not $content) {
                    $content = if ($askRes.response) { $askRes.response } else { $askRes | ConvertTo-Json -Depth 2 }
                }

                $usage = if ($askRes.usage) { $askRes.usage } else { $null }

                $isStream = $false
                if ($body.stream) {
                    if ($body.stream -is [bool]) { $isStream = $body.stream }
                    elseif ($body.stream -eq "true") { $isStream = $true }
                }

                $created = [int][double]::Parse((Get-Date -UFormat %s))

                if ($isStream) {
                    $response.StatusCode = 200
                    $response.ContentType = "text/event-stream"
                    $response.AddHeader("Cache-Control", "no-cache")
                    $response.AddHeader("Connection", "keep-alive")

                    # 1. Content Chunk
                    $chunk = @{
                        id = "chatcmpl-$created"
                        object = "chat.completion.chunk"
                        created = $created
                        model = $model
                        choices = @(
                            @{
                                index = 0
                                delta = @{ role = "assistant"; content = $content }
                                finish_reason = $null
                            }
                        )
                    }
                    $jsonChunk = $chunk | ConvertTo-Json -Depth 5 -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $jsonChunk`n`n")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Flush()

                    # 2. Done Chunk
                     $doneChunk = @{
                        id = "chatcmpl-$created"
                        object = "chat.completion.chunk"
                        created = $created
                        model = $model
                        choices = @(
                            @{
                                index = 0
                                delta = @{}
                                finish_reason = "stop"
                            }
                        )
                    }
                    $jsonDone = $doneChunk | ConvertTo-Json -Depth 5 -Compress
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: $jsonDone`n`n")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Flush()

                    # 3. [DONE]
                    $bytes = [System.Text.Encoding]::UTF8.GetBytes("data: [DONE]`n`n")
                    $response.OutputStream.Write($bytes, 0, $bytes.Length)
                    $response.OutputStream.Flush()

                } else {
                    $respObj = @{
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
                    if ($usage) { $respObj.usage = $usage }
                    Write-JsonResponse -Response $response -Data $respObj
                }
            }
            # Route: POST /v1/audio/speech
            elseif ($method -eq "POST" -and ($path -eq "/v1/audio/speech" -or $path -eq "/v1/audio/speech/")) {
                # Parse Body
                $reader = [System.IO.StreamReader]::new($request.InputStream, $request.ContentEncoding)
                $bodyStr = $reader.ReadToEnd()
                $body = $bodyStr | ConvertFrom-Json

                $inputText = $body.input
                if (-not $inputText) {
                    Write-JsonResponse -Response $response -StatusCode 400 -Data @{ error = "Missing required field: input" }
                    continue
                }

                $voice = if ($body.voice) { $body.voice } else { "alloy" }
                $model = if ($body.model) { $body.model } else { "tts-1" }

                $asksageModel = "tts"
                if ($model -eq "tts-1-hd") { $asksageModel = "tts-hd" }

                $payload = @{
                    text = $inputText
                    voice = $voice
                    model = $asksageModel
                }

                try {
                    $audioBytes = Invoke-AskSageRequestBytes -Path "get-text-to-speech" -Payload $payload
                    $response.StatusCode = 200
                    $response.ContentType = "audio/mpeg"
                    $response.ContentLength64 = $audioBytes.Length
                    $response.OutputStream.Write($audioBytes, 0, $audioBytes.Length)
                } catch {
                     Write-Error "TTS Error: $_"
                     $response.StatusCode = 502
                     $err = @{ error = "AskSage TTS failed"; detail = "$_" }
                     Write-JsonResponse -Response $response -StatusCode 502 -Data $err
                }
            }
            # Route: POST /v1/audio/transcriptions
            elseif ($method -eq "POST" -and ($path -eq "/v1/audio/transcriptions" -or $path -eq "/v1/audio/transcriptions/")) {
                $parts = Parse-MultipartRequest -Request $request

                if (-not $parts.file) {
                     Write-JsonResponse -Response $response -StatusCode 400 -Data @{ error = "Missing file upload" }
                     continue
                }

                # $parts.file is { filename, content, contentType }

                $askRes = Invoke-AskSageMultipartRequest -Path "file" -FilePart $parts.file

                $text = $askRes.ret
                if (-not $text) {
                    $text = if ($askRes.response) { $askRes.response } else { "" }
                }

                Write-JsonResponse -Response $response -Data @{ text = $text }
            }
            else {
                $response.StatusCode = 404
                $err = @{ error = "Not Found"; path = $path }
                Write-JsonResponse -Response $response -StatusCode 404 -Data $err
            }
        } catch {
            $msg = $_.Exception.Message
            Write-Error "Error processing request: $msg"
            $response.StatusCode = 500

            # Check if it's a custom error object thrown by Invoke-AskSageRequest
            if ($_.TargetObject -and $_.TargetObject.status) {
                 $response.StatusCode = 502
                 Write-JsonResponse -Response $response -StatusCode 502 -Data $_.TargetObject.detail
            } else {
                 $err = @{ error = "Internal Server Error"; detail = $msg }
                 Write-JsonResponse -Response $response -StatusCode 500 -Data $err
            }
        } finally {
            $response.Close()
        }
    }
} finally {
    if ($listener.IsListening) {
        $listener.Stop()
    }
    $listener.Close()
    $httpClient.Dispose()
}
