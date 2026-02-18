import os
import time
import json
from typing import Any, Dict, List, Optional, Union, AsyncGenerator
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, HTTPException, Request, UploadFile, File, Form
from fastapi.responses import JSONResponse, StreamingResponse, Response

APP_NAME = "asksage-openai-proxy"

def _env_bool(name: str, default: bool) -> bool:
    v = os.getenv(name)
    if v is None:
        return default
    return v.strip().lower() in ("1", "true", "yes", "y", "on")

ASKSAGE_SERVER_BASE = os.getenv("ASKSAGE_SERVER_BASE", "https://api.genai.army.mil/server/").rstrip("/") + "/"
ASKSAGE_API_KEY = os.getenv("ASKSAGE_API_KEY", "")
ASKSAGE_DEFAULT_MODEL = os.getenv("ASKSAGE_DEFAULT_MODEL", "gpt-4o-mini")
ASKSAGE_DEFAULT_PERSONA = int(os.getenv("ASKSAGE_DEFAULT_PERSONA", "1"))
ASKSAGE_DEFAULT_DATASET = os.getenv("ASKSAGE_DEFAULT_DATASET", "none")
ASKSAGE_DEFAULT_LIVE = int(os.getenv("ASKSAGE_DEFAULT_LIVE", "0"))
ASKSAGE_DEFAULT_LIMIT_REFERENCES = int(os.getenv("ASKSAGE_DEFAULT_LIMIT_REFERENCES", "0"))
ASKSAGE_INCLUDE_USAGE = _env_bool("ASKSAGE_INCLUDE_USAGE", False)

# TLS / CA bundle handling
ASKSAGE_VERIFY_TLS = _env_bool("ASKSAGE_VERIFY_TLS", True)
ASKSAGE_CA_BUNDLE_PATH = os.getenv("ASKSAGE_CA_BUNDLE_PATH")  # optional path to PEM bundle

# HTTP timeouts (seconds)
HTTP_TIMEOUT = float(os.getenv("HTTP_TIMEOUT", "120"))

if not ASKSAGE_API_KEY:
    # Allow container to start but fail requests with a clean error
    pass

@asynccontextmanager
async def lifespan(app: FastAPI):
    verify: Union[bool, str] = ASKSAGE_VERIFY_TLS
    if ASKSAGE_CA_BUNDLE_PATH:
        verify = ASKSAGE_CA_BUNDLE_PATH

    app.state.http_client = httpx.AsyncClient(timeout=HTTP_TIMEOUT, verify=verify)
    yield
    await app.state.http_client.aclose()

app = FastAPI(title=APP_NAME, version="HEAD", lifespan=lifespan)


@app.get("/healthz")
def healthz() -> Dict[str, Any]:
    return {
        "status": "ok",
        "service": APP_NAME,
        "time": int(time.time()),
        "asksage_server_base": ASKSAGE_SERVER_BASE,
        "tls_verify": ASKSAGE_VERIFY_TLS,
    }


def openai_messages_to_prompt(messages: List[Dict[str, Any]]) -> str:
    """
    Ask Sage /query supports either a simple string or a very limited conversation array.
    To maximize compatibility with OpenAI clients, we translate the message list into a
    single prompt string with clear role markers.
    """
    system_parts: List[str] = []
    convo_parts: List[str] = []
    for m in messages:
        role = (m.get("role") or "").lower()
        content = m.get("content")
        # OpenAI allows content to be str OR a list of parts (text/images)
        if isinstance(content, list):
            # keep only text parts
            text_chunks = []
            for part in content:
                if isinstance(part, dict) and part.get("type") == "text" and "text" in part:
                    text_chunks.append(str(part["text"]))
            content_str = "\n".join(text_chunks).strip()
        else:
            content_str = "" if content is None else str(content)

        if role == "system":
            if content_str:
                system_parts.append(content_str)
        elif role == "user":
            convo_parts.append(f"User: {content_str}".strip())
        elif role == "assistant":
            convo_parts.append(f"Assistant: {content_str}".strip())
        else:
            # unknown role -> treat as user
            convo_parts.append(f"User: {content_str}".strip())

    prompt = ""
    if system_parts:
        prompt += "System:\n" + "\n\n".join(system_parts).strip() + "\n\n"
    prompt += "\n".join(convo_parts).strip()

    # Nudge toward next assistant turn
    if prompt and not prompt.endswith("\n"):
        prompt += "\n"
    prompt += "Assistant:"
    return prompt


async def asksage_post(path: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    POST to Ask Sage Server API.

    Authentication: Ask Sage uses `x-access-tokens` header carrying either a static API key
    or a 24-hour access token. See Ask Sage Server API docs.  citeturn3view0
    """
    if not ASKSAGE_API_KEY:
        raise HTTPException(status_code=500, detail="ASKSAGE_API_KEY is not set")

    url = ASKSAGE_SERVER_BASE + path.lstrip("/")
    headers = {
        "x-access-tokens": ASKSAGE_API_KEY,
        "Content-Type": "application/json",
        "Accept": "application/json",
    }

    # Use the persistent client from app state
    if hasattr(app.state, "http_client"):
        client = app.state.http_client
        resp = await client.post(url, headers=headers, json=payload)
    else:
        # Fallback if lifespan not run
        verify: Union[bool, str] = ASKSAGE_VERIFY_TLS
        if ASKSAGE_CA_BUNDLE_PATH:
            verify = ASKSAGE_CA_BUNDLE_PATH
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, verify=verify) as client:
            resp = await client.post(url, headers=headers, json=payload)

    # Ask Sage errors are typically JSON with message + status
    try:
        data = resp.json()
    except Exception:
        data = {"raw": resp.text}
    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "AskSage request failed",
                "asksage_status": resp.status_code,
                "asksage_response": data,
            },
        )
    if isinstance(data, dict):
        return data
    return {"data": data}


async def asksage_post_bytes(path: str, payload: Dict[str, Any]) -> bytes:
    """
    POST to Ask Sage Server API and return binary content.
    """
    if not ASKSAGE_API_KEY:
        raise HTTPException(status_code=500, detail="ASKSAGE_API_KEY is not set")

    url = ASKSAGE_SERVER_BASE + path.lstrip("/")
    headers = {
        "x-access-tokens": ASKSAGE_API_KEY,
        "Content-Type": "application/json",
    }

    if hasattr(app.state, "http_client"):
        client = app.state.http_client
        resp = await client.post(url, headers=headers, json=payload)
    else:
        verify: Union[bool, str] = ASKSAGE_VERIFY_TLS
        if ASKSAGE_CA_BUNDLE_PATH:
            verify = ASKSAGE_CA_BUNDLE_PATH
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, verify=verify) as client:
            resp = await client.post(url, headers=headers, json=payload)

    if resp.status_code >= 400:
        raise HTTPException(status_code=502, detail=f"AskSage request failed: {resp.status_code} {resp.text}")

    return resp.content


async def asksage_post_multipart(path: str, files: Dict[str, Any], data: Dict[str, Any] = None) -> Dict[str, Any]:
    """
    POST to Ask Sage Server API with multipart/form-data.
    """
    if not ASKSAGE_API_KEY:
        raise HTTPException(status_code=500, detail="ASKSAGE_API_KEY is not set")

    url = ASKSAGE_SERVER_BASE + path.lstrip("/")
    headers = {
        "x-access-tokens": ASKSAGE_API_KEY,
        # Content-Type is set by httpx when using files
    }

    if hasattr(app.state, "http_client"):
        client = app.state.http_client
        resp = await client.post(url, headers=headers, files=files, data=data)
    else:
        verify: Union[bool, str] = ASKSAGE_VERIFY_TLS
        if ASKSAGE_CA_BUNDLE_PATH:
            verify = ASKSAGE_CA_BUNDLE_PATH
        async with httpx.AsyncClient(timeout=HTTP_TIMEOUT, verify=verify) as client:
            resp = await client.post(url, headers=headers, files=files, data=data)

    try:
        response_data = resp.json()
    except Exception:
        response_data = {"raw": resp.text}

    if resp.status_code >= 400:
        raise HTTPException(
            status_code=502,
            detail={
                "error": "AskSage request failed",
                "asksage_status": resp.status_code,
                "asksage_response": response_data,
            },
        )
    return response_data


@app.get("/v1/models")
@app.get("/v1/models/")
async def v1_models() -> JSONResponse:
    """
    OpenAI-compatible models listing.

    Backed by Ask Sage /get-models.  citeturn1view1
    """
    data = await asksage_post("get-models", payload={})
    # Expected format: {object: "list", data: [{id,name,...}, ...]}
    models = []
    for m in (data.get("data") or []):
        mid = m.get("id") or m.get("name") or "unknown"
        models.append({"id": mid, "object": "model", "owned_by": m.get("owned_by", "asksage")})

    out = {"object": "list", "data": models}
    return JSONResponse(out)


@app.get("/v1/models/{model}")
async def v1_model_retrieve(model: str) -> JSONResponse:
    """
    Retrieve a specific model.
    """
    data = await asksage_post("get-models", payload={})
    for m in (data.get("data") or []):
        mid = m.get("id") or m.get("name") or "unknown"
        if mid == model:
             return JSONResponse({"id": mid, "object": "model", "owned_by": m.get("owned_by", "asksage")})

    raise HTTPException(status_code=404, detail="Model not found")


@app.post("/v1/audio/speech")
async def v1_audio_speech(req: Request) -> Response:
    """
    OpenAI-compatible Text-to-Speech -> Ask Sage /get-text-to-speech
    """
    body = await req.json()

    input_text = body.get("input")
    if not input_text:
        raise HTTPException(status_code=400, detail="Missing required field: input")

    voice = body.get("voice", "alloy")
    model = body.get("model", "tts-1")

    # Map model
    asksage_model = "tts"
    if model == "tts-1-hd":
        asksage_model = "tts-hd"
    elif model == "tts-1":
        asksage_model = "tts"
    else:
        # Fallback to provided model name if it's custom, or default to tts
        # For safety, if it's not a known openai model, we'll try passing it as is or default?
        # Ask Sage docs specifically list 'tts' and 'tts-hd'.
        asksage_model = "tts"

    payload = {
        "text": input_text,
        "voice": voice,
        "model": asksage_model
    }

    audio_content = await asksage_post_bytes("get-text-to-speech", payload=payload)

    return Response(content=audio_content, media_type="audio/mpeg")


@app.post("/v1/audio/transcriptions")
async def v1_audio_transcriptions(
    file: UploadFile = File(...),
    model: str = Form("whisper-1")
) -> Dict[str, Any]:
    """
    OpenAI-compatible Speech-to-Text -> Ask Sage /file
    """
    # Read file content to pass to httpx
    content = await file.read()
    files = {"file": (file.filename, content, file.content_type)}

    # Ask Sage /server/file endpoint
    # Response: { "ret": "extracted text", "status": 200, "response": "OK" }
    data = await asksage_post_multipart("file", files=files)

    text = data.get("ret")
    if text is None:
         # Fallback
         text = data.get("response") or ""

    return {"text": text}


def _now_epoch() -> int:
    return int(time.time())


def _make_openai_chat_response(
    model: str,
    content: str,
    usage: Optional[Dict[str, Any]] = None,
    finish_reason: str = "stop",
) -> Dict[str, Any]:
    out: Dict[str, Any] = {
        "id": f"chatcmpl-{_now_epoch()}",
        "object": "chat.completion",
        "created": _now_epoch(),
        "model": model,
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": finish_reason,
            }
        ],
    }
    if usage:
        out["usage"] = usage
    return out


async def _stream_single_chunk(model: str, content: str) -> AsyncGenerator[bytes, None]:
    """
    Minimal SSE streaming compatible with many OpenAI clients:
    - send one delta chunk with full content
    - send [DONE]
    """
    created = _now_epoch()
    chunk = {
        "id": f"chatcmpl-{created}",
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": {"role": "assistant", "content": content}, "finish_reason": None}],
    }
    yield f"data: {json.dumps(chunk)}\n\n".encode("utf-8")
    done = {
        "id": f"chatcmpl-{created}",
        "object": "chat.completion.chunk",
        "created": created,
        "model": model,
        "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
    }
    yield f"data: {json.dumps(done)}\n\n".encode("utf-8")
    yield b"data: [DONE]\n\n"


@app.post("/v1/chat/completions")
@app.post("/v1/chat/completions/")
async def v1_chat_completions(req: Request) -> Any:
    """
    OpenAI-compatible Chat Completions -> Ask Sage /query.

    Ask Sage /query accepts:
      - message (string or conversation array)
      - persona (int), dataset, model, temperature, limit_references, live, system_prompt, usage, tools
    citeturn3view0
    """
    body = await req.json()

    model = body.get("model") or ASKSAGE_DEFAULT_MODEL
    messages = body.get("messages") or []
    temperature = body.get("temperature", None)
    stream = bool(body.get("stream", False))

    # Optional Ask Sage knobs via "asksage": {...}
    asksage_cfg = body.get("asksage") or {}
    persona = asksage_cfg.get("persona", ASKSAGE_DEFAULT_PERSONA)
    dataset = asksage_cfg.get("dataset", ASKSAGE_DEFAULT_DATASET)
    live = asksage_cfg.get("live", ASKSAGE_DEFAULT_LIVE)
    limit_references = asksage_cfg.get("limit_references", ASKSAGE_DEFAULT_LIMIT_REFERENCES)
    system_prompt = asksage_cfg.get("system_prompt", None)
    usage_flag = asksage_cfg.get("usage", ASKSAGE_INCLUDE_USAGE)

    if not isinstance(messages, list) or not messages:
        raise HTTPException(status_code=400, detail="Missing required field: messages[]")

    prompt = openai_messages_to_prompt(messages)

    payload: Dict[str, Any] = {
        "message": prompt,
        "model": model,
        "persona": int(persona) if persona is not None else ASKSAGE_DEFAULT_PERSONA,
        "dataset": dataset,
        "limit_references": int(limit_references) if limit_references is not None else ASKSAGE_DEFAULT_LIMIT_REFERENCES,
        "live": int(live) if live is not None else ASKSAGE_DEFAULT_LIVE,
        "usage": bool(usage_flag),
    }

    # Only forward temperature if provided (Ask Sage default is 0.0)
    if temperature is not None:
        payload["temperature"] = float(temperature)

    if system_prompt:
        payload["system_prompt"] = str(system_prompt)

    # NOTE: Tools/function calling isn’t mapped here; Ask Sage has a "tools" param
    # but OpenAI tool formats vary by provider. If you need tool use, extend here.
    data = await asksage_post("query", payload=payload)

    # Ask Sage response: message contains the generated response text.  citeturn3view0
    content = data.get("message")
    if content is None:
        # Some tenants may use `response` or other keys; fall back to stringified response
        content = data.get("response") or json.dumps(data)

    # Usage mapping (best-effort). Ask Sage usage format can vary by tenant/model.
    usage = None
    if isinstance(data, dict) and ("usage" in data):
        usage = data.get("usage")

    if stream:
        return StreamingResponse(
            _stream_single_chunk(model=str(model), content=str(content)),
            media_type="text/event-stream",
        )

    return JSONResponse(_make_openai_chat_response(model=str(model), content=str(content), usage=usage))
