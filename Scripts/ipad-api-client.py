#!/usr/bin/env python3
"""Mac client for the local MLX iPad node; Python standard library only.

Examples (keep the iPad app in the foreground and the USB forwarder running):
  python3 Scripts/ipad-api-client.py health
  python3 Scripts/ipad-api-client.py models
  python3 Scripts/ipad-api-client.py chat '用中文介绍一下你自己。' --max-tokens 128
  python3 Scripts/ipad-api-client.py chat 'Explain unified memory.' --stream

The default bearer-token file is  .local/ipad-api-token.txt next to outputs/.
Use --endpoint and --token-file before the command to override these defaults.
No OpenAI account or external Python package is needed.
"""

import argparse
import http.client
import json
import math
from pathlib import Path
import sys
import time
from urllib.parse import urlsplit


DEFAULT_ENDPOINT = "http://127.0.0.1:18080"
DEFAULT_MODEL = "mlx-community/Qwen3-4B-4bit"
DEFAULT_TOKEN_FILE = Path(__file__).resolve().parent.parent / ".local" / "ipad-api-token.txt"
MAX_RESPONSE_BYTES = 8 * 1024 * 1024


class APIError(Exception):
    """A transport, response-format, or HTTP error without credential disclosure."""

    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def read_token(path):
    try:
        token = Path(path).read_text(encoding="utf-8").strip()
    except OSError as exc:
        raise APIError("Cannot read the bearer-token file: " + str(exc)) from None
    if not token or len(token) > 4096 or any(ch.isspace() for ch in token):
        raise APIError("Bearer-token file must contain one nonempty token without whitespace.")
    return token


def encode_json(value):
    return json.dumps(value, ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode("utf-8")


class NodeClient:
    def __init__(self, endpoint, token, timeout=120):
        parsed = urlsplit(endpoint)
        if parsed.scheme not in ("http", "https") or not parsed.hostname:
            raise APIError("Endpoint must be an http:// or https:// URL.")
        if parsed.username or parsed.password or parsed.query or parsed.fragment:
            raise APIError("Endpoint must not contain credentials, query parameters, or fragments.")
        try:
            port = parsed.port
        except ValueError as exc:
            raise APIError(str(exc)) from None
        self.endpoint = endpoint.rstrip("/")
        self.host = parsed.hostname
        self.port = port or (443 if parsed.scheme == "https" else 80)
        self.scheme = parsed.scheme
        self.prefix = parsed.path.rstrip("/")
        self.token = token
        self.timeout = timeout

    def safe(self, value):
        return str(value).replace(self.token, "[redacted]") if self.token else str(value)

    def connection(self):
        connection_class = http.client.HTTPSConnection if self.scheme == "https" else http.client.HTTPConnection
        return connection_class(self.host, self.port, timeout=self.timeout)

    def open_response(self, method, path, body=None, auth=True, token_override=None, headers=None):
        request_headers = {"Accept": "application/json", "Connection": "close"}
        if auth:
            request_headers["Authorization"] = "Bearer " + (self.token if token_override is None else token_override)
        if body is not None:
            request_headers["Content-Type"] = "application/json"
        request_headers.update(headers or {})
        connection = self.connection()
        started = time.perf_counter()
        try:
            connection.request(method, self.prefix + path, body=body, headers=request_headers)
            response = connection.getresponse()
        except (OSError, http.client.HTTPException) as exc:
            connection.close()
            raise APIError(self.safe("Cannot reach iPad API: " + str(exc))) from None
        return connection, response, started

    def request_raw(self, method, path, body=None, **kwargs):
        connection, response, started = self.open_response(method, path, body, **kwargs)
        try:
            payload = response.read(MAX_RESPONSE_BYTES + 1)
            if len(payload) > MAX_RESPONSE_BYTES:
                raise APIError("Response exceeds the client safety limit.", response.status)
            return response.status, dict(response.getheaders()), payload, (time.perf_counter() - started) * 1000
        except (OSError, http.client.HTTPException) as exc:
            raise APIError(self.safe("Could not finish reading response: " + str(exc))) from None
        finally:
            response.close()
            connection.close()

    def request_json(self, method, path, payload=None):
        status, headers, data, elapsed_ms = self.request_raw(method, path, None if payload is None else encode_json(payload))
        try:
            value = json.loads(data)
        except (ValueError, UnicodeDecodeError):
            raise APIError("API returned invalid JSON (HTTP %d)." % status, status) from None
        if not 200 <= status < 300:
            raise APIError(self.safe("HTTP %d: %s" % (status, json.dumps(value, ensure_ascii=False))), status)
        return value, elapsed_ms

    def stream_chat(self, payload, timing=None):
        """Yield SSE JSON chunks; closing this generator also closes the socket.

        Network TTFT measures the first nonempty content chunk received on the Mac.
        The device's raw-token TTFT is a separate metric in the final JSON chunk.
        """
        timing = timing if timing is not None else {}
        body = dict(payload, stream=True)
        connection, response, started = self.open_response(
            "POST", "/v1/chat/completions", encode_json(body), headers={"Accept": "text/event-stream"})
        timing["response_headers_ms"] = (time.perf_counter() - started) * 1000
        timing["network_time_to_first_content_ms"] = None
        timing["completed"] = False
        received_bytes = 0
        data_lines = []
        try:
            if response.status != 200:
                detail = response.read(65536).decode("utf-8", errors="replace")
                raise APIError(self.safe("HTTP %d: %s" % (response.status, detail)), response.status)
            if "text/event-stream" not in response.getheader("Content-Type", "").lower():
                raise APIError("Streaming response is not text/event-stream.")
            while True:
                line = response.readline(1024 * 1024 + 1)
                received_bytes += len(line)
                if received_bytes > MAX_RESPONSE_BYTES or len(line) > 1024 * 1024:
                    raise APIError("Streaming response exceeds the client safety limit.")
                if not line:
                    raise APIError("SSE connection ended before [DONE].")
                try:
                    text_line = line.decode("utf-8").rstrip("\r\n")
                except UnicodeDecodeError:
                    raise APIError("SSE response contains invalid UTF-8.") from None
                if text_line.startswith("data:"):
                    data_lines.append(text_line[5:].lstrip(" "))
                elif not text_line and data_lines:
                    event = "\n".join(data_lines)
                    data_lines.clear()
                    if event == "[DONE]":
                        timing["completed"] = True
                        return
                    try:
                        chunk = json.loads(event)
                    except ValueError:
                        raise APIError("SSE event contains invalid JSON.") from None
                    if "error" in chunk:
                        raise APIError(self.safe("SSE error: " + json.dumps(chunk["error"], ensure_ascii=False)))
                    for choice in chunk.get("choices", []):
                        if choice.get("delta", {}).get("content") and timing["network_time_to_first_content_ms"] is None:
                            timing["network_time_to_first_content_ms"] = (time.perf_counter() - started) * 1000
                    yield chunk
        except (OSError, http.client.HTTPException) as exc:
            raise APIError(self.safe("Could not finish streaming response: " + str(exc))) from None
        finally:
            timing["total_ms"] = (time.perf_counter() - started) * 1000
            response.close()
            connection.close()


def cli():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--endpoint", default=DEFAULT_ENDPOINT)
    parser.add_argument("--token-file", type=Path, default=DEFAULT_TOKEN_FILE)
    parser.add_argument("--timeout", type=float, default=120, help="socket timeout in seconds")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("health")
    commands.add_parser("models")
    chat = commands.add_parser("chat")
    chat.add_argument("prompt")
    chat.add_argument("--system")
    chat.add_argument("--model", default=DEFAULT_MODEL)
    chat.add_argument("--max-tokens", type=int, default=128)
    chat.add_argument("--temperature", type=float, default=0)
    chat.add_argument("--seed", type=int)
    chat.add_argument("--stream", action="store_true")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    if args.command == "chat":
        if not 1 <= args.max_tokens <= 512:
            parser.error("--max-tokens must be between 1 and 512")
        if not math.isfinite(args.temperature) or not 0 <= args.temperature <= 2:
            parser.error("--temperature must be between 0 and 2")
    try:
        client = NodeClient(args.endpoint, read_token(args.token_file), args.timeout)
        if args.command != "chat":
            path = "/health" if args.command == "health" else "/v1/models"
            result, latency_ms = client.request_json("GET", path)
            print(json.dumps(result, ensure_ascii=False, indent=2))
            print("Mac request time: %.1f ms" % latency_ms, file=sys.stderr)
            return 0
        messages = []
        if args.system:
            messages.append({"role": "system", "content": args.system})
        messages.append({"role": "user", "content": args.prompt})
        payload = dict(model=args.model, messages=messages, max_tokens=args.max_tokens, temperature=args.temperature, stream=args.stream)
        if args.seed is not None:
            payload["seed"] = args.seed
        if args.stream:
            timing = {}
            final = {}
            for chunk in client.stream_chat(payload, timing):
                for choice in chunk.get("choices", []):
                    content = choice.get("delta", {}).get("content")
                    if content:
                        print(content, end="", flush=True)
                if chunk.get("usage") is not None or chunk.get("device_metrics") is not None:
                    final = {key: chunk[key] for key in ("usage", "device_metrics") if key in chunk}
            print()
            final["mac_timing"] = timing
            print(json.dumps(final, ensure_ascii=False, indent=2), file=sys.stderr)
        else:
            result, elapsed_ms = client.request_json("POST", "/v1/chat/completions", payload)
            print(result["choices"][0]["message"]["content"])
            print(json.dumps({"usage": result.get("usage"), "device_metrics": result.get("device_metrics"),
                              "mac_total_ms": elapsed_ms}, ensure_ascii=False, indent=2), file=sys.stderr)
        return 0
    except (APIError, KeyError, TypeError, ValueError) as exc:
        print("Error: " + str(exc), file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("\nRequest cancelled.", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(cli())
