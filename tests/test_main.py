import os
import json
import pytest
import respx
from fastapi.testclient import TestClient
from httpx import Response

# Set env vars before importing app to avoid startup errors or default issues
os.environ["ASKSAGE_API_KEY"] = "test-api-key"
os.environ["ASKSAGE_SERVER_BASE"] = "https://mock.asksage.server/server/"

from app.main import app

client = TestClient(app)

MOCK_BASE = "https://mock.asksage.server/server/"

def test_healthz():
    resp = client.get("/healthz")
    assert resp.status_code == 200
    data = resp.json()
    assert data["status"] == "ok"
    assert data["service"] == "asksage-openai-proxy"

@respx.mock
def test_v1_models():
    # Mock Ask Sage /get-models
    route = respx.post(f"{MOCK_BASE}get-models").mock(
        return_value=Response(
            200,
            json={
                "object": "list",
                "data": [
                    {"id": "gpt-4o-mini", "owned_by": "openai"},
                    {"name": "claude-3-opus", "owned_by": "anthropic"}
                ]
            }
        )
    )

    resp = client.get("/v1/models")
    assert resp.status_code == 200
    data = resp.json()
    assert data["object"] == "list"
    assert len(data["data"]) == 2
    assert data["data"][0]["id"] == "gpt-4o-mini"
    assert data["data"][1]["id"] == "claude-3-opus"

@respx.mock
def test_chat_completions_success():
    # Mock Ask Sage /query
    route = respx.post(f"{MOCK_BASE}query").mock(
        return_value=Response(
            200,
            json={
                "message": "Hello world!",
                "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}
            }
        )
    )

    payload = {
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Hi"}],
        "temperature": 0.5
    }
    resp = client.post("/v1/chat/completions", json=payload)
    assert resp.status_code == 200
    data = resp.json()
    assert data["object"] == "chat.completion"
    assert data["choices"][0]["message"]["content"] == "Hello world!"
    assert data["usage"]["total_tokens"] == 15

    # Verify request sent to Ask Sage
    assert route.called
    req = route.calls.last.request
    sent_json = json.loads(req.content)
    assert "User: Hi" in sent_json["message"]
    assert sent_json["temperature"] == 0.5

@respx.mock
def test_chat_completions_error_handling():
    # Mock Ask Sage error
    respx.post(f"{MOCK_BASE}query").mock(
        return_value=Response(
            500,
            json={"error": "Internal Server Error"}
        )
    )

    payload = {
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Hi"}]
    }
    resp = client.post("/v1/chat/completions", json=payload)
    assert resp.status_code == 502
    data = resp.json()
    assert data["detail"]["error"] == "AskSage request failed"
    assert data["detail"]["asksage_status"] == 500

@respx.mock
def test_chat_completions_stream():
    # Mock Ask Sage /query
    respx.post(f"{MOCK_BASE}query").mock(
        return_value=Response(
            200,
            json={
                "message": "Streamed response",
            }
        )
    )

    payload = {
        "model": "gpt-4o-mini",
        "messages": [{"role": "user", "content": "Hi"}],
        "stream": True
    }
    resp = client.post("/v1/chat/completions", json=payload)
    assert resp.status_code == 200
    assert "text/event-stream" in resp.headers["content-type"]

    content = resp.text
    assert "data: " in content
    assert "Streamed response" in content
    assert "[DONE]" in content


@respx.mock
def test_v1_model_retrieve():
    # Mock Ask Sage /get-models
    respx.post(f"{MOCK_BASE}get-models").mock(
        return_value=Response(
            200,
            json={
                "object": "list",
                "data": [
                    {"id": "gpt-4o-mini", "owned_by": "openai"},
                    {"name": "claude-3-opus", "owned_by": "anthropic"}
                ]
            }
        )
    )

    resp = client.get("/v1/models/gpt-4o-mini")
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == "gpt-4o-mini"
    assert data["object"] == "model"

    resp = client.get("/v1/models/claude-3-opus")
    assert resp.status_code == 200
    data = resp.json()
    assert data["id"] == "claude-3-opus"

    resp = client.get("/v1/models/non-existent")
    assert resp.status_code == 404


@respx.mock
def test_audio_speech():
    # Mock Ask Sage /get-text-to-speech
    mock_audio = b"fake audio content"
    respx.post(f"{MOCK_BASE}get-text-to-speech").mock(
        return_value=Response(
            200,
            content=mock_audio
        )
    )

    payload = {
        "model": "tts-1",
        "input": "Hello",
        "voice": "alloy"
    }
    resp = client.post("/v1/audio/speech", json=payload)
    assert resp.status_code == 200
    assert resp.content == mock_audio
    assert resp.headers["content-type"] == "audio/mpeg"


@respx.mock
def test_audio_transcriptions():
    # Mock Ask Sage /file
    respx.post(f"{MOCK_BASE}file").mock(
        return_value=Response(
            200,
            json={
                "ret": "Extracted text from audio",
                "status": 200
            }
        )
    )

    # Use a dummy file
    files = {'file': ('test.mp3', b'audio data', 'audio/mpeg')}
    resp = client.post("/v1/audio/transcriptions", files=files, data={"model": "whisper-1"})

    assert resp.status_code == 200
    data = resp.json()
    assert data["text"] == "Extracted text from audio"
