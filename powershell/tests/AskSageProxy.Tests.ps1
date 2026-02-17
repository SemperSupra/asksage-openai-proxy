
$here = $PSScriptRoot
$proxyScript = Join-Path $here "../AskSageProxy.ps1"

Describe "AskSageProxy Integration" {
    BeforeAll {
        # Start Mock Ask Sage Server
        $mockBlock = {
            param($Port)

            # Simple HttpListener based mock
            $listener = [System.Net.HttpListener]::new()
            try {
                $listener.Prefixes.Add("http://localhost:${Port}/")
                $listener.Start()
            } catch {
                Write-Error "Mock failed to bind to port $Port : $_"
                return
            }

            while ($listener.IsListening) {
                try {
                    $context = $listener.GetContext()
                    $request = $context.Request
                    $response = $context.Response

                    $path = $request.Url.AbsolutePath
                    $method = $request.HttpMethod

                    # Default response
                    $statusCode = 200
                    $contentType = "application/json"
                    $bodyContent = "{}"

                    if ($path -match "get-models") {
                        $bodyContent = '{ "data": [ { "id": "gpt-4o-mini", "owned_by": "asksage" }, { "id": "gpt-4", "owned_by": "asksage" } ] }'
                    }
                    elseif ($path -match "query") {
                        # Simulate chat completion
                        # We can inspect body if needed, but for now just return static
                        $bodyContent = '{ "message": "Mock Response", "usage": { "total_tokens": 10 }, "finish_reason": "stop" }'
                    }
                    elseif ($path -match "get-text-to-speech") {
                        $contentType = "audio/mpeg"
                        $bodyContent = "MOCK_AUDIO_DATA" # Will be converted to bytes
                    }
                    elseif ($path -match "file") {
                         # Audio transcription
                         $bodyContent = '{ "ret": "Mock Transcription" }'
                    }
                    else {
                        $statusCode = 404
                        $bodyContent = '{ "error": "Mock Not Found" }'
                    }

                    $response.StatusCode = $statusCode
                    $response.ContentType = $contentType

                    if ($contentType -eq "audio/mpeg") {
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($bodyContent)
                    } else {
                        $buffer = [System.Text.Encoding]::UTF8.GetBytes($bodyContent)
                    }

                    $response.ContentLength64 = $buffer.Length
                    $response.OutputStream.Write($buffer, 0, $buffer.Length)
                    $response.Close()
                } catch {
                    # Continue listening
                }
            }
        }

        # Pick ports
        $mockPort = 8092
        $proxyPort = 8093

        # Start Mock Job
        $mockJob = Start-Job -ScriptBlock $mockBlock -ArgumentList $mockPort
        if (-not $mockJob) { Throw "Failed to start mock job" }

        # Wait for mock to be ready (naive wait)
        Start-Sleep -Seconds 2

        # Start Proxy Job
        # Pass arguments directly to script
        $proxyArgs = @(
            "-Port", $proxyPort,
            "-ServerBase", "http://localhost:${mockPort}/server/",
            "-ApiKey", "test-key"
        )

        $proxyJob = Start-Job -FilePath $proxyScript -ArgumentList $proxyArgs
        if (-not $proxyJob) { Throw "Failed to start proxy job" }

        # Wait for Proxy Health
        $proxyUrl = "http://localhost:${proxyPort}"
        $retry = 0
        $started = $false

        while ($retry -lt 20) {
            try {
                $res = Invoke-RestMethod "$proxyUrl/healthz" -ErrorAction Stop
                if ($res.status -eq "ok") {
                    $started = $true
                    break
                }
            } catch {
                Start-Sleep -Milliseconds 500
            }
            $retry++
        }

        if (-not $started) {
            Write-Host "Proxy Output:"
            Receive-Job -Job $proxyJob | Write-Host
            Throw "Proxy failed to start on $proxyPort"
        }

        # Share base URL with tests
        $script:baseUrl = $proxyUrl
        $script:jobs = @($mockJob, $proxyJob)
    }

    AfterAll {
        if ($script:jobs) {
            $script:jobs | Stop-Job -PassThru | Remove-Job
        }
    }

    It "GET /healthz returns ok" {
        $res = Invoke-RestMethod "$script:baseUrl/healthz"
        $res.status | Should -Be "ok"
    }

    It "GET /v1/models returns models list" {
        $res = Invoke-RestMethod "$script:baseUrl/v1/models"
        $res.object | Should -Be "list"
        $res.data.Count | Should -BeGreaterThan 0
        $res.data[0].id | Should -Be "gpt-4o-mini"
    }

    It "GET /v1/models/{model} returns specific model" {
        $res = Invoke-RestMethod "$script:baseUrl/v1/models/gpt-4"
        $res.id | Should -Be "gpt-4"
    }

    It "POST /v1/chat/completions returns response" {
        $payload = @{
            model = "gpt-4o-mini"
            messages = @( @{ role = "user"; content = "Hello" } )
        } | ConvertTo-Json

        $res = Invoke-RestMethod "$script:baseUrl/v1/chat/completions" -Method Post -Body $payload -ContentType "application/json"

        $res.object | Should -Be "chat.completion"
        $res.choices[0].message.content | Should -Be "Mock Response"
    }

    It "POST /v1/audio/speech returns audio data" {
         $payload = @{
            model = "tts-1"
            input = "Test Speech"
            voice = "alloy"
        } | ConvertTo-Json

        # Use Invoke-WebRequest to get raw content
        $res = Invoke-WebRequest "$script:baseUrl/v1/audio/speech" -Method Post -Body $payload -ContentType "application/json"

        $res.StatusCode | Should -Be 200
        $res.Headers["Content-Type"] | Should -Be "audio/mpeg"

        $content = [System.Text.Encoding]::UTF8.GetString($res.Content)
        $content | Should -Be "MOCK_AUDIO_DATA"
    }

    It "POST /v1/audio/transcriptions (Multipart) returns text" {
        # Use .NET HttpClient to construct multipart request
        Add-Type -AssemblyName System.Net.Http
        $client = [System.Net.Http.HttpClient]::new()

        $multipart = [System.Net.Http.MultipartFormDataContent]::new()

        $fileBytes = [System.Text.Encoding]::UTF8.GetBytes("fake audio file content")
        $fileContent = [System.Net.Http.ByteArrayContent]::new($fileBytes)
        $fileContent.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::Parse("audio/mpeg")
        $multipart.Add($fileContent, "file", "audio.mp3")

        $multipart.Add([System.Net.Http.StringContent]::new("whisper-1"), "model")

        $responseMsg = $client.PostAsync("$script:baseUrl/v1/audio/transcriptions", $multipart).GetAwaiter().GetResult()

        $responseMsg.StatusCode | Should -Be 200
        $respStr = $responseMsg.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        $json = $respStr | ConvertFrom-Json

        $json.text | Should -Be "Mock Transcription"

        $client.Dispose()
    }

    It "Returns 404 for unknown path" {
        try {
            Invoke-RestMethod "$script:baseUrl/v1/unknown-path"
            $true | Should -Be $false
        } catch {
             $_.Exception.Response.StatusCode.value__ | Should -Be 404
        }
    }
}
