#!/usr/bin/env python3
"""Real-device end-to-end checks for the iPad inference service (stdlib only).

Run only with the real app in the foreground and USB forwarding active:
  python3 outputs/test-ipad-api.py

The script performs actual short generations, tests contention and cancellation,
and writes api-verification.json beside this file. It does not start a forwarder,
install the app, or invent timing values. It never records the bearer token.
"""

import argparse
from datetime import datetime, timezone
import http.client
import importlib.util
import json
import math
from pathlib import Path
import socket
import ssl
import sys
import time


HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("ipad_api_client", HERE / "ipad-api-client.py")
api = importlib.util.module_from_spec(spec)
spec.loader.exec_module(api)


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def verify_generation(value, streamed=False):
    require(isinstance(value, dict), "Generation must be a JSON object")
    usage = value.get("usage")
    metrics = value.get("device_metrics")
    require(isinstance(usage, dict), "Response must include usage")
    require(isinstance(metrics, dict), "Response must include device_metrics")
    for key in ("prompt_tokens", "completion_tokens", "total_tokens"):
        require(isinstance(usage.get(key), int) and not isinstance(usage[key], bool) and usage[key] >= 0,
                "Invalid usage." + key)
    require(usage["completion_tokens"] > 0, "Generation returned no raw completion tokens")
    require(usage["total_tokens"] == usage["prompt_tokens"] + usage["completion_tokens"], "Token totals do not add up")
    for key in ("prepare_ms", "time_to_first_token_ms", "generation_tokens", "decode_tokens_per_second", "mlx_active_bytes", "mlx_peak_bytes"):
        require(number(metrics.get(key)) and metrics[key] >= 0, "Invalid device_metrics." + key)
    require(metrics["generation_tokens"] == usage["completion_tokens"], "Raw generation counter differs from usage.completion_tokens")
    require(isinstance(metrics.get("thermal_state"), (str, int)), "Missing thermal state")
    require(metrics["mlx_peak_bytes"] >= metrics["mlx_active_bytes"], "MLX peak memory is less than active memory")
    if not streamed:
        choices = value.get("choices", [])
        require(bool(choices), "Missing choices")
        require(choices[0].get("message", {}).get("role") == "assistant", "Unexpected response role")
        require(isinstance(choices[0]["message"].get("content"), str) and bool(choices[0]["message"]["content"]), "Empty generated content")
        require(choices[0].get("finish_reason") in ("length", "stop"), "Unexpected finish_reason")
    return {"usage": usage, "device_metrics": metrics}


class Verification:
    def __init__(self, args, token):
        self.args = args
        self.token = token
        self.client = api.NodeClient(args.endpoint, token, args.timeout)
        self.results = []
        self.model = args.model
        self.pending_stream = None
        self.pending_timing = None
        self.base = {"model": self.model, "messages": [
            {"role": "system", "content": "You are a concise assistant. /no_think"},
            {"role": "user", "content": "Reply with one short English sentence about the Moon. /no_think"}],
            "max_tokens": 48, "temperature": 0, "seed": 42, "stream": False}

    def safe(self, value):
        if isinstance(value, str):
            return value.replace(self.token, "[redacted]")
        if isinstance(value, dict):
            return {self.safe(k): self.safe(v) for k, v in value.items()}
        if isinstance(value, (list, tuple)):
            return [self.safe(v) for v in value]
        return value

    def run(self, name, function):
        start = time.perf_counter()
        try:
            detail = function()
            result = {"name": name, "passed": True, "details": detail}
        except Exception as exc:
            result = {"name": name, "passed": False, "error": self.safe(type(exc).__name__ + ": " + str(exc))}
        result["elapsed_ms"] = (time.perf_counter() - start) * 1000
        self.results.append(result)
        print(("PASS " if result["passed"] else "FAIL ") + name, flush=True)
        return result["passed"]

    def rejected(self, body, expected=(400,), auth=True, token_override=None, method="POST", path="/v1/chat/completions", headers=None):
        if isinstance(body, (dict, list)):
            body = api.encode_json(body)
        status, response_headers, content, elapsed_ms = self.client.request_raw(
            method, path, body, auth=auth, token_override=token_override, headers=headers)
        require(status in expected, "Expected HTTP %s, got %d" % (expected, status))
        require(len(content) <= 65536, "Error response too large")
        try:
            error = json.loads(content)
        except (ValueError, UnicodeDecodeError):
            raise AssertionError("Error response must be JSON") from None
        require(isinstance(error, dict) and "error" in error, "Error response lacks error object")
        return {"status": status, "error": error, "mac_roundtrip_ms": elapsed_ms}

    def health(self):
        value, elapsed_ms = self.client.request_json("GET", "/health")
        require(isinstance(value, dict), "Health must be a JSON object")
        require(value.get("ready") is True, "Model is not ready")
        require(value.get("busy") is False, "Node is already busy; run verification with no other client")
        return {"response": value, "mac_roundtrip_ms": elapsed_ms}

    def models(self):
        value, elapsed_ms = self.client.request_json("GET", "/v1/models")
        require(isinstance(value.get("data"), list), "Models must contain a data list")
        require(any(model.get("id") == self.model for model in value["data"]), "Expected model is not advertised")
        return {"response": value, "mac_roundtrip_ms": elapsed_ms}

    def nonstream(self):
        value, elapsed_ms = self.client.request_json("POST", "/v1/chat/completions", self.base)
        detail = verify_generation(value)
        require(value.get("model") == self.model, "Response model differs from request")
        require(detail["usage"]["completion_tokens"] <= self.base["max_tokens"], "max_tokens was exceeded")
        detail.update(content=value["choices"][0]["message"]["content"], mac_total_ms=elapsed_ms)
        return detail

    def streaming(self):
        timing, content, chunks, final, finish = {}, [], 0, None, None
        for chunk in self.client.stream_chat(self.base, timing):
            chunks += 1
            require(chunk.get("object") == "chat.completion.chunk", "Unexpected SSE object")
            require(chunk.get("model") == self.model, "SSE model differs from request")
            for choice in chunk.get("choices", []):
                delta = choice.get("delta", {}).get("content")
                if delta is not None:
                    require(isinstance(delta, str), "SSE content must be a string")
                    content.append(delta)
                if choice.get("finish_reason") is not None:
                    finish = choice["finish_reason"]
            if chunk.get("usage") is not None:
                final = chunk
        require(timing.get("completed") is True, "Missing SSE [DONE]")
        require(final is not None, "No SSE final usage chunk")
        require(bool("".join(content)), "SSE returned no content")
        require(finish in ("length", "stop"), "Missing SSE finish reason")
        detail = verify_generation(final, streamed=True)
        require(detail["usage"]["completion_tokens"] <= self.base["max_tokens"], "SSE max_tokens was exceeded")
        require(number(timing.get("network_time_to_first_content_ms")), "No Mac first-content timing")
        detail.update(content="".join(content), sse_json_chunks=chunks, mac_timing=timing)
        detail["timing_definitions"] = {
            "mac_network_time_to_first_content_ms": "Mac monotonic request start to first nonempty SSE content received; includes preparation, inference, transport, and buffering.",
            "device_time_to_first_token_ms": "iPad-reported monotonic preparation/generation timing to first raw token; see server definition. First raw token and first decoded content may differ.",
        }
        return detail

    def stream_without_usage(self):
        payload = dict(self.base, stream_options={"include_usage": False})
        timing, content, final, finish = {}, [], None, None
        for chunk in self.client.stream_chat(payload, timing):
            require(chunk.get("usage") is None, "include_usage=false emitted usage data")
            for choice in chunk.get("choices", []):
                if choice.get("delta", {}).get("content"):
                    content.append(choice["delta"]["content"])
                if choice.get("finish_reason") is not None:
                    finish = choice["finish_reason"]
                    final = chunk
        require(timing.get("completed") is True, "Missing SSE [DONE]")
        require(bool("".join(content)), "SSE returned no content")
        require(finish in ("length", "stop") and final is not None, "No finish chunk")
        metrics = final.get("device_metrics")
        require(isinstance(metrics, dict), "include_usage=false lost device_metrics from finish chunk")
        require(number(metrics.get("generation_tokens")) and metrics["generation_tokens"] > 0, "Missing raw generation counter")
        require(number(metrics.get("time_to_first_token_ms")) and metrics["time_to_first_token_ms"] >= 0, "Missing device TTFT")
        return {"content": "".join(content), "device_metrics": metrics, "mac_timing": timing,
                "usage_emitted": False}

    def unicode_parity(self, max_tokens):
        # Exercise UTF-8 byte boundaries, ZWJ sequences and a combining character.
        sample = "中文你好，👩\u200d💻，e\u0301，👨\u200d👩\u200d👧\u200d👦。"
        payload = dict(self.base, max_tokens=max_tokens, seed=42, temperature=0, messages=[
            {"role": "system", "content": "只复制用户给定的文字，不添加任何解释。 /no_think"},
            {"role": "user", "content": "请原样输出：" + sample + " /no_think"}])
        response, nonstream_ms = self.client.request_json("POST", "/v1/chat/completions", payload)
        # At one token a legal generation can decode to an empty string; compare
        # the exact bytes rather than imposing a minimum visible text length.
        nonstream_metrics = verify_generation(response, streamed=True)
        nonstream_text = response["choices"][0]["message"]["content"]
        content, final, timing = [], None, {}
        for chunk in self.client.stream_chat(payload, timing):
            for choice in chunk.get("choices", []):
                if choice.get("delta", {}).get("content") is not None:
                    content.append(choice["delta"]["content"])
            if chunk.get("usage") is not None:
                final = chunk
        require(final is not None and timing.get("completed") is True, "Unicode SSE incomplete")
        streamed_metrics = verify_generation(final, streamed=True)
        streamed_text = "".join(content)
        require(nonstream_text.encode("utf-8") == streamed_text.encode("utf-8"),
                "SSE/nonstream UTF-8 mismatch: nonstream=%r stream=%r" % (nonstream_text, streamed_text))
        require(nonstream_metrics["usage"] == streamed_metrics["usage"], "SSE/nonstream raw token counts differ")
        require(nonstream_metrics["usage"]["completion_tokens"] <= max_tokens, "Unicode max_tokens exceeded")
        return {"max_tokens": max_tokens, "temperature": 0, "seed": 42, "input_sample": sample,
                "nonstream_content": nonstream_text, "stream_content": streamed_text,
                "utf8_equal": True, "usage_equal": True, "usage": nonstream_metrics["usage"],
                "nonstream_mac_total_ms": nonstream_ms, "stream_mac_timing": timing,
                "nonstream_device_metrics": nonstream_metrics["device_metrics"],
                "stream_device_metrics": streamed_metrics["device_metrics"]}

    def busy(self):
        payload = dict(self.base, max_tokens=512, messages=[
            {"role": "user", "content": "Write a long numbered list of 100 facts about astronomy. Continue until the limit. /no_think"}])
        self.pending_timing = {}
        self.pending_stream = self.client.stream_chat(payload, self.pending_timing)
        for chunk in self.pending_stream:
            if any(choice.get("delta", {}).get("content") for choice in chunk.get("choices", [])):
                break
        else:
            raise AssertionError("Long request completed before the contention test")
        return self.rejected(self.base, expected=(429,))

    def disconnect(self):
        require(self.pending_stream is not None, "No active stream from the busy test")
        cancelled_at = time.perf_counter()
        self.pending_stream.close()
        self.pending_stream = None
        last_health = None
        while time.perf_counter() - cancelled_at < 30:
            last_health, _ = self.client.request_json("GET", "/health")
            if last_health.get("ready") is True and last_health.get("busy") is False:
                break
            time.sleep(0.2)
        else:
            raise AssertionError("GPU task was not released within 30 seconds of disconnect")
        reusable_ms = (time.perf_counter() - cancelled_at) * 1000
        payload = dict(self.base, max_tokens=16)
        value, elapsed_ms = self.client.request_json("POST", "/v1/chat/completions", payload)
        detail = verify_generation(value)
        detail.update(disconnect_to_ready_ms=reusable_ms, next_request_mac_total_ms=elapsed_ms, health=last_health)
        return detail

    def raw_protocol(self, header_lines, body=b""):
        """Send intentionally invalid HTTP framing without client normalization."""
        client = self.client
        sock = socket.create_connection((client.host, client.port), timeout=min(15, self.args.timeout))
        if client.scheme == "https":
            sock = ssl.create_default_context().wrap_socket(sock, server_hostname=client.host)
        start = time.perf_counter()
        try:
            lines = ["POST " + client.prefix + "/v1/chat/completions HTTP/1.1", "Host: " + client.host,
                     "Authorization: Bearer " + self.token, "Connection: close", "Content-Type: application/json"] + header_lines
            sock.sendall(("\r\n".join(lines) + "\r\n\r\n").encode("ascii") + body)
            response = http.client.HTTPResponse(sock)
            response.begin()
            data = response.read(65537)
            require(len(data) <= 65536, "Protocol error response too large")
            return response.status, data, (time.perf_counter() - start) * 1000
        finally:
            sock.close()

    def transfer_rejection(self):
        status, data, elapsed_ms = self.raw_protocol(["Transfer-Encoding: chunked"], b"0\r\n\r\n")
        require(status in (400, 411, 501), "Chunked request framing must be rejected, got HTTP " + str(status))
        return {"status": status, "mac_roundtrip_ms": elapsed_ms}

    def oversized_body(self):
        # Only the declaration is sent; no oversized allocation or model work.
        status, data, elapsed_ms = self.raw_protocol(["Content-Length: 8388609"])
        require(status == 413, "Oversized declared body must be rejected with 413, got " + str(status))
        return {"status": status, "declared_bytes": 8388609, "mac_roundtrip_ms": elapsed_ms}

    def execute(self):
        if not self.run("authenticated_health_and_reachability", self.health):
            return
        self.run("advertised_model", self.models)
        for method, path, body in (("GET", "/health", None), ("GET", "/v1/models", None),
                                   ("POST", "/v1/chat/completions", self.base)):
            for label, kwargs in (("missing", {"auth": False}), ("wrong", {"token_override": "intentionally-invalid-verification-token"})):
                self.run("auth_%s_%s" % (label, path),
                         lambda method=method, path=path, body=body, kwargs=kwargs: self.rejected(
                             body, expected=(401,), method=method, path=path, **kwargs))
        self.run("malformed_json", lambda: self.rejected(b"{"))
        self.run("nonobject_json", lambda: self.rejected([]))
        invalid = (
            ("messages_missing", {k: v for k, v in self.base.items() if k != "messages"}),
            ("messages_empty", dict(self.base, messages=[])),
            ("messages_wrong_type", dict(self.base, messages="hello")),
            ("unsupported_role", dict(self.base, messages=[{"role": "tool", "content": "hello"}])),
            ("nonstring_content", dict(self.base, messages=[{"role": "user", "content": {"text": "hello"}}])),
            ("max_tokens_zero", dict(self.base, max_tokens=0)),
            ("max_tokens_too_large", dict(self.base, max_tokens=513)),
            ("max_tokens_boolean", dict(self.base, max_tokens=True)),
            ("temperature_negative", dict(self.base, temperature=-0.1)),
            ("temperature_too_large", dict(self.base, temperature=2.1)),
            ("stream_wrong_type", dict(self.base, stream="true")),
        )
        for name, payload in invalid:
            self.run(name, lambda payload=payload: self.rejected(payload))
        self.run("unsupported_model", lambda: self.rejected(dict(self.base, model="invalid-test-model"), expected=(400, 404)))
        self.run("unsupported_content_type", lambda: self.rejected(
            self.base, expected=(415,), headers={"Content-Type": "text/plain"}))
        self.run("unsupported_transfer_encoding", self.transfer_rejection)
        self.run("oversized_declared_body", self.oversized_body)
        self.run("prepared_prompt_exceeds_context_budget", lambda: self.rejected(
            dict(self.base, max_tokens=1, messages=[{"role": "user", "content": "benchmark " * 2400}]), expected=(400,)))
        self.run("nonstream_generation_and_usage", self.nonstream)
        self.run("stream_generation_usage_and_timing", self.streaming)
        self.run("stream_include_usage_false", self.stream_without_usage)
        for max_tokens in (1, 7, 64):
            self.run("unicode_stream_nonstream_parity_max_%d" % max_tokens,
                     lambda max_tokens=max_tokens: self.unicode_parity(max_tokens))
        self.run("concurrent_generation_rejected_429", self.busy)
        self.run("disconnect_releases_model_and_next_request_succeeds", self.disconnect)
        self.run("health_after_verification", self.health)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--endpoint", default=api.DEFAULT_ENDPOINT)
    parser.add_argument("--token-file", type=Path, default=api.DEFAULT_TOKEN_FILE)
    parser.add_argument("--model", default=api.DEFAULT_MODEL)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--output", type=Path, default=HERE / "api-verification.json")
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("--timeout must be a positive finite number")
    try:
        token = api.read_token(args.token_file)
        verification = Verification(args, token)
    except api.APIError as exc:
        print("Error: " + str(exc), file=sys.stderr)
        return 1
    interrupted = False
    try:
        verification.execute()
    except KeyboardInterrupt:
        interrupted = True
    finally:
        if verification.pending_stream is not None:
            verification.pending_stream.close()
    results = verification.results
    passed = sum(item["passed"] for item in results)
    artifact = verification.safe({
        "tested_at_utc": datetime.now(timezone.utc).isoformat(),
        "endpoint": args.endpoint,
        "model": args.model,
        "transport": "USB forwarding" if args.endpoint == api.DEFAULT_ENDPOINT else "user-selected endpoint",
        "measurement_source": "Actual HTTP requests to configured iPad endpoint; no simulated measurements",
        "interrupted": interrupted,
        "passed": not interrupted and bool(results) and passed == len(results),
        "summary": {"passed": passed, "failed": len(results) - passed, "total": len(results)},
        "checks": results,
    })
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(artifact, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print("%d/%d checks passed. Results: %s" % (passed, len(results), args.output))
    return 130 if interrupted else (0 if artifact["passed"] else 1)


if __name__ == "__main__":
    sys.exit(main())
