# API Compatibility Guide

This proxy facilitates the use of Ask Sage with tools that expect OpenAI-compatible endpoints.

## Supported Endpoints

| OpenAI Endpoint | Ask Sage Equivalent | Notes |
| :--- | :--- | :--- |
| `POST /v1/chat/completions` | `POST /server/query` | Messages are flattened into a prompt. Supports `stream=true` (minimal streaming). |
| `GET /v1/models` | `POST /server/get-models` | Returns list of available models. |
| `POST /v1/audio/speech` | `POST /server/get-text-to-speech` | Converts text to speech. |
| `POST /v1/audio/transcriptions` | `POST /server/file` | Extracts text from uploaded audio file (using `ret` field). |

## Limitations

- **Tool Calling:** Not currently implemented. Ask Sage supports tools, but the format translation is not yet built into this proxy.
- **Streaming:** The proxy implements "minimal" streaming, emitting a single Server-Sent Event (SSE) chunk with the full response, rather than token-by-token streaming. This satisfies clients expecting a stream but does not provide real-time feedback.
- **Parameters:** Not all OpenAI parameters are mapped. Key parameters like `model`, `temperature`, `messages` are supported.
- **Ask Sage Specifics:** You can pass Ask Sage specific configurations (like `persona`, `dataset`, `live`) via the `asksage` object in the JSON payload if the client supports custom parameters, or via environment variables.

## Client Configuration

### Continue.dev

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

You can optionally add Ask Sage-specific knobs:

```json
{
  "asksage": { "persona": 1, "dataset": "none", "live": 0 }
}
```
