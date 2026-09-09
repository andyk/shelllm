# /// script
# requires-python = ">=3.10"
# dependencies = ["websockets==17.1"]
# ///
"""Local-only protocol conformance and adversarial broker ownership tests."""
import argparse
import asyncio
import contextlib
import io
import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import websockets
from websockets.asyncio.server import serve as ws_serve

ROOT = Path(__file__).resolve().parents[1]
TEST_PATH = os.environ.get("PATH", os.defpath)
M = runpy.run_path(str(ROOT / "tools/responses-ws"))
# Patch function globals, not runpy's copied result dictionary.
G = M["Broker"].handle.__globals__
LIMIT = M["MAX_FRAME"]


def completed(lane, rid="resp_ok", text="ok"):
    return {"type": "response.completed", "stream_id": lane, "response": {
        "id": rid, "status": "completed", "output": [
            {"type": "message", "content": [{"type": "output_text", "text": text}]}]}}


async def until(predicate):
    async def wait():
        while not predicate():
            await asyncio.sleep(.005)
    await asyncio.wait_for(wait(), 5)


class Capture:
    def __init__(self):
        self.events = []
        self.terminal = False
        self.exit_code = 1

    def feed(self, event):
        self.events.append(event)
        self.terminal = event.get("type") in M["TERMINAL_EVENTS"] or event.get("type") == "error"
        self.exit_code = int(event.get("type") not in ("response.completed", "response.incomplete"))
        return self.terminal


class Conformance(unittest.TestCase):
    def setUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.args = argparse.Namespace(model="test-model", max_tokens=321, thinking="",
                                       effort="", system_prompt_file="")

    def body(self, value):
        path = Path(self.tmp.name) / "body.json"
        path.write_text(json.dumps(value))
        os.environ["LLM_RESPONSES_BODY_FILE"] = str(path)

    def test_exact_dependency(self):
        self.assertEqual(websockets.__version__, "17.1")
        self.assertIn('dependencies = ["websockets==17.1"]', (ROOT / "tools/responses-ws").read_text())

    def test_invalid_terminal_never_succeeds(self):
        path = Path(self.tmp.name) / "response.json"
        os.environ["LLM_RESPONSE_FILE"] = str(path)
        for response in ({}, {"id": "resp_a", "status": "completed"},
                         {"id": "resp_a", "status": "incomplete", "output": []},
                         {"id": "resp_a", "status": "completed", "output": [], "error": {"message": "broken"}}):
            emitter = M["Emitter"](stream=False)
            with self.subTest(response=response), contextlib.redirect_stderr(io.StringIO()):
                self.assertTrue(emitter.feed({"type": "response.completed", "response": response}))
                self.assertEqual(emitter.exit_code, 1)
                self.assertEqual(json.loads(path.read_text())["error"]["code"], "outcome_unknown")

    def test_http_payload_conformance(self):
        # Exercise the actual HTTP builder without its CLI, curl, or inference.
        source = (ROOT / "bin/llm").read_text()
        builder = source.split("_build_payload_responses() {", 1)[1].split("\nbuild_payload_gemini()", 1)[0]
        for settings, body, system, effort in [
            ({}, {"instructions": "stale", "previous_response_id": "stale", "conversation": "conv_body"}, "", ""),
            ({"LLM_PREVIOUS_RESPONSE_ID": "resp_new"}, {"store": False, "metadata": {"test": "a"}}, "brief", "high"),
            ({"LLM_RESPONSES_CONVERSATION": "conv_new", "LLM_RESPONSES_COMPACT_THRESHOLD": "123"},
             {"conversation": "conv_old", "context_management": [{"type": "compaction", "compact_threshold": 99}]}, "", ""),
            ({"LLM_RESPONSES_BACKGROUND": "0"}, {"background": False, "include": ["reasoning.encrypted_content"]}, "", ""),
            ({"LLM_RESPONSES_BACKGROUND": "0"}, {"background": True}, "", ""),
            ({}, {"instructions": "stale", "reasoning": {"effort": "low"}}, "", ""),
        ]:
            with self.subTest(settings=settings, body=body), patch.dict(os.environ, settings, clear=True):
                self.body(body)
                system_file = Path(self.tmp.name) / "system"
                system_file.write_text(system)
                self.args.system_prompt_file = str(system_file) if system else ""
                self.args.effort = effort
                items = [{"role": "user", "content": "unicode λ and \"escapes\""},
                         {"type": "reasoning", "encrypted_content": "opaque", "summary": []}]
                ws = M["build_create"](self.args, items)
                env = dict(os.environ, PATH=TEST_PATH, LLM_MODEL=self.args.model, LLM_MAX_TOKENS="321",
                           LLM_MESSAGES=json.dumps(items), LLM_SYSTEM=system, LLM_EFFORT=effort,
                           LLM_PROVIDER="openai-compatible", LLM_STREAM="1")
                result = subprocess.run(["bash", "-c", "_build_payload_responses() {" + builder +
                                         "\n_build_payload_responses"], env=env, capture_output=True, text=True, check=True)
                http = json.loads(result.stdout)
                http.pop("stream", None)
                http.pop("background", None)
                http["type"] = "response.create"
                self.assertEqual(ws, http)

    def test_background_and_unsupported_body_rejected(self):
        for body in ({"background": True}, {"stream_options": {}}, {"provider": {"zdr": True}}):
            with self.subTest(body=body):
                self.body(body)
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    M["build_create"](self.args, [])
        self.body({})
        for value in ("1", "true"):
            os.environ["LLM_RESPONSES_BACKGROUND"] = value
            with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                M["build_create"](self.args, [])

    def test_conversation_exclusion(self):
        self.body({"conversation": "conv_body", "previous_response_id": "stale"})
        self.assertNotIn("previous_response_id", M["build_create"](self.args, []))
        os.environ["LLM_PREVIOUS_RESPONSE_ID"] = "resp_new"
        with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            M["build_create"](self.args, [])

    def test_compaction_threshold_validation(self):
        for value in ("0", "-1", "1.5", "abc", "１２"):
            with self.subTest(value=value), patch.dict(os.environ, LLM_RESPONSES_COMPACT_THRESHOLD=value):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    M["build_create"](self.args, [])

    def test_endpoint_and_auth_matrix(self):
        cases = [
            ({}, M["DEFAULT_URL"], "native-test-key"),
            ({"LLM_PROVIDER": "openai", "LLM_API_URL": "https://example.invalid/custom?x=1"}, "wss://example.invalid/custom?x=1", "native-test-key"),
            ({"LLM_PROVIDER": "openai-compatible", "SHELLM_API_URL": "http://example.invalid/v1/responses"}, "ws://example.invalid/v1/responses", "compatible-test-key"),
            ({"LLM_PROVIDER": "adapter", "RESPONSES_WS_PROVIDER": "openai-compatible", "LLM_API_URL": "https://example.invalid/responses"}, "wss://example.invalid/responses", "compatible-test-key"),
            ({"LLM_PROVIDER": "adapter", "LLM_API_URL": "http://example.invalid/responses"}, "ws://example.invalid/responses", "compatible-test-key"),
            ({"RESPONSES_WS_PROVIDER": "openai-compatible", "LLM_API_URL": "http://example.invalid/old", "RESPONSES_WS_URL": "ws://example.invalid/new"}, "ws://example.invalid/new", "compatible-test-key"),
        ]
        for env, url, key in cases:
            with self.subTest(env=env), patch.dict(os.environ, dict(env, OPENAI_API_KEY="native-test-key", LLM_API_KEY="compatible-test-key"), clear=True):
                self.assertEqual(M["endpoint_config"](), (url, key))
                self.assertEqual(M["connect_kwargs"]()["additional_headers"], {"Authorization": "Bearer " + key})
        with patch.dict(os.environ, {"LLM_PROVIDER": "openai-compatible", "LLM_API_URL": "http://example.invalid/responses", "OPENAI_API_KEY": "native-test-key"}, clear=True):
            self.assertEqual(M["connect_kwargs"]()["additional_headers"], {})

    def test_provider_policy_and_invalid_endpoint_rejected(self):
        for env in (
            {"RESPONSES_WS_PROVIDER": "openrouter"}, {"LLM_PROVIDER": "anthropic"},
            {"LLM_PROVIDER": "openai-compatible"}, {"LLM_OR_ZDR": "1"},
            {"LLM_OR_DATA_COLLECTION": "deny"}, {"LLM_OR_ONLY": "some-provider"},
            {"LLM_STOP_AFTER_CODE_BLOCK": "1"}, {"RESPONSES_WS_URL": "ftp://example.invalid"},
            {"RESPONSES_WS_URL": "https://user:secret@example.invalid/responses"},
        ):
            with self.subTest(env=env), patch.dict(os.environ, env, clear=True):
                with contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                    M["endpoint_config"]()

    def test_frame_byte_boundary(self):
        self.assertEqual(len(M["encode_frame"]("a" * (LIMIT - 2))), LIMIT)
        with self.assertRaisesRegex(ValueError, "frame_too_large"):
            M["encode_frame"]("a" * (LIMIT - 1))
        with self.assertRaisesRegex(ValueError, "frame_too_large"):
            M["encode_frame"]("λ" * (LIMIT // 2))

    def test_queue_count_bound(self):
        lane = M["Lane"]()
        for _ in range(M["MAX_QUEUE_EVENTS"]):
            lane.put({"type": "response.output_text.delta", "delta": "a"})
        with self.assertRaisesRegex(ValueError, "bounded event queue"):
            lane.put({"type": "response.output_text.delta"})
        lane.fail(M["transport_error"]("failure"))
        self.assertEqual(lane.queue.qsize(), 1)

    def test_queue_byte_bound(self):
        lane = M["Lane"]()
        with patch.dict(G, MAX_QUEUE_BYTES=200):
            lane.put({"delta": "a" * 100})
            with self.assertRaisesRegex(ValueError, "bounded event queue"):
                lane.put({"delta": "a" * 100})


class BrokerFaults(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.env = patch.dict(os.environ, {}, clear=True)
        self.env.start()
        self.addCleanup(self.env.stop)
        # Keep the Unix socket path below macOS's sockaddr_un limit as well.
        self.tmp = tempfile.TemporaryDirectory(dir="/tmp")
        self.addCleanup(self.tmp.cleanup)
        self.requests = asyncio.Queue()
        self.received = []
        self.handlers = set()
        self.writers = []
        self.calls = []

        async def provider(ws):
            try:
                async for raw in ws:
                    body = json.loads(raw)
                    self.received.append(body)
                    await self.requests.put((ws, body))
            except websockets.exceptions.ConnectionClosed:
                pass

        self.provider = await ws_serve(provider, "127.0.0.1", 0, max_size=LIMIT + 1024)
        port = self.provider.sockets[0].getsockname()[1]
        self.url = f"ws://127.0.0.1:{port}/v1/responses"
        self.broker = M["Broker"](self.url, 60)
        self.path = self.tmp.name + "/broker.sock"

        async def handle(reader, writer):
            task = asyncio.current_task()
            self.handlers.add(task)
            try:
                await self.broker.handle(reader, writer)
            finally:
                self.handlers.discard(task)

        self.server = await asyncio.start_unix_server(handle, path=self.path, limit=LIMIT + 1)

    async def asyncTearDown(self):
        for writer in self.writers:
            writer.close()
        for task in self.calls:
            task.cancel()
        await asyncio.gather(*self.calls, return_exceptions=True)
        for task in list(self.handlers):
            task.cancel()
        await asyncio.gather(*list(self.handlers), return_exceptions=True)
        await self.broker.close_connection()
        self.server.close()
        await self.server.wait_closed()
        self.provider.close()
        await self.provider.wait_closed()

    async def request(self):
        return await asyncio.wait_for(self.requests.get(), 5)

    async def client(self):
        reader, writer = await asyncio.open_unix_connection(self.path, limit=LIMIT + 1)
        self.writers.append(writer)
        await M["drain_line"](writer, {"op": "create", "body": {"type": "response.create"}})
        return reader, writer

    def call(self, body=None, emitter=None):
        emitter = emitter or Capture()
        task = asyncio.create_task(M["run_via_broker"](self.path, body or {"type": "response.create"}, emitter))
        self.calls.append(task)
        return task, emitter

    async def send(self, ws, event):
        await ws.send(json.dumps(event))

    async def test_sixteen_silent_abandoned_clients_release_capacity(self):
        clients = [await self.client() for _ in range(16)]
        requests = [await self.request() for _ in range(16)]
        self.assertEqual(len({id(ws) for ws, _ in requests}), 1)
        for _, writer in clients:
            writer.close()
        await until(lambda: self.broker.slots._value == 16)
        task, capture = self.call()
        ws, body = await self.request()
        self.assertIsNot(ws, requests[0][0])
        await self.send(ws, completed(body["stream_id"]))
        self.assertEqual(await asyncio.wait_for(task, 5), 0)
        self.assertEqual(len(self.received), 17)

    async def test_abandonment_fails_other_current_calls_without_recreation(self):
        _, writer = await self.client()
        await self.request()
        task, capture = self.call()
        await self.request()
        writer.close()
        self.assertEqual(await asyncio.wait_for(task, 5), 1)
        self.assertEqual(capture.events[-1]["error"]["code"], "outcome_unknown")
        self.assertEqual(len(self.received), 2)

    async def test_delayed_old_terminal_and_reader_cleanup_cannot_reach_new_lane(self):
        close_gate = asyncio.Event()
        real_close = self.broker._close

        async def delayed_close(ws):
            await close_gate.wait()
            await real_close(ws)

        self.broker._close = delayed_close
        try:
            reader, writer = await self.client()
            old_ws, old_body = await self.request()
            old_generation = self.broker.connection
            await self.send(old_ws, {"type": "response.output_text.delta", "stream_id": old_body["stream_id"], "delta": "partial"})
            await asyncio.wait_for(reader.readline(), 5)
            writer.close()
            await until(lambda: old_generation.retired)
            task, capture = self.call()
            new_ws, new_body = await self.request()
            new_generation = self.broker.connection
            self.assertEqual(old_body["stream_id"], new_body["stream_id"])
            await self.send(old_ws, completed(old_body["stream_id"], "resp_abandoned", "WRONG ANSWER"))
            # Old reader consumes its late event and runs finally while the
            # new generation owns an identically named lane.
            await asyncio.sleep(.05)
            self.assertIs(self.broker.connection, new_generation)
            self.assertFalse(task.done())
            close_gate.set()
            await real_close(old_ws)
            await self.send(new_ws, completed(new_body["stream_id"], "resp_new", "correct"))
            self.assertEqual(await asyncio.wait_for(task, 5), 0)
            self.assertEqual(capture.events[-1]["response"]["id"], "resp_new")
            self.assertEqual(len(self.received), 2)
        finally:
            close_gate.set()

    async def test_queued_disconnected_client_is_never_dispatched(self):
        clients = [await self.client() for _ in range(16)]
        requests = [await self.request() for _ in range(16)]
        _, waiting_writer = await self.client()
        waiting_writer.close()
        await asyncio.sleep(.05)
        for index, (ws, body) in enumerate(requests):
            await self.send(ws, completed(body["stream_id"], f"resp_{index}"))
        for reader, _ in clients:
            await asyncio.wait_for(reader.readline(), 5)
        await until(lambda: self.broker.slots._value == 16)
        self.assertEqual(len(self.received), 16)

    async def test_completed_lane_cannot_deliver_a_stale_terminal_to_a_later_call(self):
        old_ws = None
        for index in range(M["MAX_LANES"]):
            task, capture = self.call()
            ws, body = await self.request()
            old_ws = old_ws or ws
            self.assertIs(ws, old_ws)
            await self.send(ws, {"type": "response.created", "stream_id": body["stream_id"],
                                 "response": {"id": f"resp_{index}"}})
            await self.send(ws, completed(body["stream_id"], f"resp_{index}"))
            self.assertEqual(await asyncio.wait_for(task, 5), 0)
            await until(lambda: not self.broker.connection.lanes)

        old_generation = self.broker.connection
        close_gate = asyncio.Event()
        real_close = self.broker._close

        async def delayed_close(ws):
            await close_gate.wait()
            await real_close(ws)

        self.broker._close = delayed_close
        try:
            task, capture = self.call()
            ws, body = await self.request()
            await self.send(old_ws, completed("lane-0", "resp_0", "stale response"))
            await until(lambda: task.done() or old_generation.retired)
            self.assertFalse(task.done(), "a retired response settled a later call")
            self.assertIsNot(ws, old_ws)
            await self.send(ws, {"type": "response.created", "stream_id": body["stream_id"],
                                 "response": {"id": "resp_current"}})
            await self.send(ws, completed(body["stream_id"], "resp_current", "current response"))
            self.assertEqual(await asyncio.wait_for(task, 5), 0)
            self.assertEqual(capture.events[-1]["response"]["id"], "resp_current")
            self.assertEqual(len(self.received), M["MAX_LANES"] + 1)
        finally:
            close_gate.set()

    async def test_lane_exhaustion_preserves_the_last_active_call_before_rotation(self):
        old_ws = None
        for index in range(M["MAX_LANES"] - 1):
            task, _ = self.call()
            ws, body = await self.request()
            old_ws = old_ws or ws
            self.assertIs(ws, old_ws)
            await self.send(ws, completed(body["stream_id"], f"resp_{index}"))
            self.assertEqual(await asyncio.wait_for(task, 5), 0)
            await until(lambda: not self.broker.connection.lanes)

        last, last_capture = self.call()
        last_ws, last_body = await self.request()
        self.assertIs(last_ws, old_ws)
        next_call, next_capture = self.call()
        await until(lambda: self.broker.slots._value == M["MAX_IN_FLIGHT"] - 2)
        await self.send(last_ws, completed(last_body["stream_id"], "resp_last"))
        self.assertEqual(await asyncio.wait_for(last, 5), 0)
        self.assertEqual(last_capture.events[-1]["response"]["id"], "resp_last")
        next_ws, next_body = await self.request()
        self.assertIsNot(next_ws, old_ws)
        await self.send(next_ws, completed(next_body["stream_id"], "resp_new"))
        self.assertEqual(await asyncio.wait_for(next_call, 5), 0)
        self.assertEqual(next_capture.events[-1]["response"]["id"], "resp_new")

    async def last_available_lane(self):
        for index in range(M["MAX_LANES"] - 1):
            task, _ = self.call()
            ws, body = await self.request()
            await self.send(ws, completed(body["stream_id"], f"resp_{index}"))
            self.assertEqual(await asyncio.wait_for(task, 5), 0)
            await until(lambda: not self.broker.connection.lanes)
        task, capture = self.call()
        ws, body = await self.request()
        return task, capture, ws, body

    async def test_disconnected_exhaustion_waiter_never_creates(self):
        last, _, ws, body = await self.last_available_lane()
        _, writer = await self.client()
        await until(lambda: self.broker.slots._value == M["MAX_IN_FLIGHT"] - 2)
        writer.close()
        await until(lambda: self.broker.slots._value == M["MAX_IN_FLIGHT"] - 1)
        self.assertEqual(len(self.received), M["MAX_LANES"])
        await self.send(ws, completed(body["stream_id"], "resp_last"))
        self.assertEqual(await asyncio.wait_for(last, 5), 0)
        next_call, capture = self.call()
        next_ws, next_body = await self.request()
        self.assertIsNot(next_ws, ws)
        await self.send(next_ws, completed(next_body["stream_id"], "resp_next"))
        self.assertEqual(await asyncio.wait_for(next_call, 5), 0)
        self.assertEqual(capture.events[-1]["response"]["id"], "resp_next")
        self.assertEqual(len(self.received), M["MAX_LANES"] + 1)

    async def test_exhaustion_wait_is_bounded_without_abandoning_live_call(self):
        last, _, ws, body = await self.last_available_lane()
        with patch.dict(G, IO_TIMEOUT=.05):
            waiting, capture = self.call()
            self.assertEqual(await asyncio.wait_for(waiting, 1), 1)
        self.assertIn("lane exhaustion wait timed out", capture.events[-1]["error"]["message"])
        self.assertEqual(len(self.received), M["MAX_LANES"])
        self.assertFalse(self.broker.connection.retired)
        await self.send(ws, completed(body["stream_id"], "resp_last"))
        self.assertEqual(await asyncio.wait_for(last, 5), 0)

    async def test_shutdown_wakes_exhaustion_waiters_without_reconnecting(self):
        last, _, _, _ = await self.last_available_lane()
        waiting, capture = self.call()
        await until(lambda: self.broker.slots._value == M["MAX_IN_FLIGHT"] - 2)
        self.broker.stopping.set()
        await asyncio.wait_for(self.broker.close_connection(), 5)
        self.assertEqual(await asyncio.wait_for(last, 5), 1)
        self.assertEqual(await asyncio.wait_for(waiting, 5), 1)
        self.assertIn("broker stopped before admission", capture.events[-1]["error"]["message"])
        self.assertIsNone(self.broker.connection)
        self.assertEqual(len(self.received), M["MAX_LANES"])

    async def test_shutdown_during_connect_never_admits_a_create(self):
        connected, release = asyncio.Event(), asyncio.Event()
        connect = G["ws_connect"]

        async def held_connect(*args, **kwargs):
            ws = await connect(*args, **kwargs)
            connected.set()
            await release.wait()
            return ws

        with patch.dict(G, ws_connect=held_connect):
            task, capture = self.call()
            await asyncio.wait_for(connected.wait(), 5)
            self.broker.stopping.set()
            await asyncio.wait_for(self.broker.close_connection(), 5)
            release.set()
            self.assertEqual(await asyncio.wait_for(task, 5), 1)
        self.assertIn("broker stopped before admission", capture.events[-1]["error"]["message"])
        self.assertIsNone(self.broker.connection)
        self.assertEqual(self.received, [])

    async def test_untagged_error_fans_out_original_diagnostic(self):
        a, ca = self.call()
        b, cb = self.call()
        ws, _ = await self.request()
        await self.request()
        error = {"type": "error", "error": {"code": "connection_limit", "message": "synthetic connection failure"}}
        await self.send(ws, error)
        self.assertEqual(await asyncio.wait_for(asyncio.gather(a, b), 5), [1, 1])
        self.assertEqual(ca.events[-1], error)
        self.assertEqual(cb.events[-1], error)

    async def test_local_client_admission_is_bounded(self):
        with patch.dict(G, MAX_CLIENTS=2):
            await self.client()
            await self.client()
            await self.request()
            await self.request()
            reader, writer = await asyncio.open_unix_connection(self.path, limit=LIMIT + 1)
            self.writers.append(writer)
            result = json.loads(await asyncio.wait_for(reader.readline(), 5))
            self.assertIn("broker_busy", result["message"])
            self.assertEqual(len(self.received), 2)

    async def test_received_terminal_survives_immediate_upstream_close(self):
        task, capture = self.call()
        ws, body = await self.request()
        await self.send(ws, completed(body["stream_id"]))
        await ws.close()
        self.assertEqual(await asyncio.wait_for(task, 5), 0)
        self.assertEqual(capture.events[-1]["response"]["id"], "resp_ok")

    async def test_cross_lane_response_id_is_rejected(self):
        a, ca = self.call()
        b, cb = self.call()
        ws, first = await self.request()
        _, second = await self.request()
        for body in (first, second):
            await self.send(ws, {"type": "response.created", "stream_id": body["stream_id"], "response": {"id": "resp_same"}})
        self.assertEqual(await asyncio.wait_for(asyncio.gather(a, b), 5), [1, 1])
        self.assertIn("another stream_id", ca.events[-1]["error"]["message"])
        self.assertIn("another stream_id", cb.events[-1]["error"]["message"])

    async def test_idle_age_rotation_precedes_admission(self):
        a, _ = self.call()
        old_ws, body = await self.request()
        await self.send(old_ws, completed(body["stream_id"]))
        self.assertEqual(await asyncio.wait_for(a, 5), 0)
        await until(lambda: not self.broker.connection.lanes)
        self.broker.connection.opened_at -= M["CONNECTION_MAX_AGE"] + 1
        b, _ = self.call()
        new_ws, body = await self.request()
        self.assertIsNot(old_ws, new_ws)
        await self.send(new_ws, completed(body["stream_id"], "resp_new"))
        self.assertEqual(await asyncio.wait_for(b, 5), 0)

    async def test_response_id_mismatch_fails_not_success(self):
        task, capture = self.call()
        ws, body = await self.request()
        await self.send(ws, {"type": "response.created", "stream_id": body["stream_id"], "response": {"id": "resp_owned"}})
        await self.send(ws, completed(body["stream_id"], "resp_wrong"))
        self.assertEqual(await asyncio.wait_for(task, 5), 1)
        self.assertIn("response ID mismatch", capture.events[-1]["error"]["message"])

    async def test_large_input_terminal_unicode_escapes_and_encrypted_reasoning(self):
        text = ('λ\\\"\n' * 30000)
        body = {"type": "response.create", "input": [{"role": "user", "content": text}]}
        output = io.StringIO()
        sidecar = Path(self.tmp.name) / "response.json"
        usage = Path(self.tmp.name) / "usage.json"
        with patch.dict(os.environ, LLM_RESPONSE_FILE=str(sidecar), LLM_USAGE_FILE=str(usage)), contextlib.redirect_stdout(output):
            task, _ = self.call(body, M["Emitter"](False))
            ws, request = await self.request()
            self.assertEqual(request["input"], body["input"])
            terminal = completed(request["stream_id"], text=text)
            terminal["response"]["output"].append({"type": "reasoning", "encrypted_content": "opaque" * 30000, "summary": []})
            terminal["response"]["usage"] = {"input_tokens": 100, "output_tokens": 200}
            await self.send(ws, terminal)
            self.assertEqual(await asyncio.wait_for(task, 5), 0)
        self.assertEqual(output.getvalue(), text)
        self.assertEqual(json.loads(sidecar.read_text()), terminal["response"])
        self.assertEqual(sidecar.stat().st_mode & 0o777, 0o600)
        self.assertEqual(json.loads(usage.read_text()), {"in_tok": 100, "out_tok": 200})

    async def test_oversize_local_frame_clean_rejection_before_dispatch(self):
        reader, writer = await asyncio.open_unix_connection(self.path, limit=LIMIT + 1)
        self.writers.append(writer)
        writer.write(b"x" * (LIMIT + 2) + b"\n")
        with contextlib.suppress(ConnectionError):
            await writer.drain()
        result = json.loads(await asyncio.wait_for(reader.readline(), 5))
        self.assertIn("frame_too_large", result["message"])
        self.assertEqual(self.received, [])

    async def test_oversize_upstream_frame_clean_failure(self):
        task, capture = self.call()
        ws, body = await self.request()
        await self.send(ws, completed(body["stream_id"], text="x" * LIMIT))
        self.assertEqual(await asyncio.wait_for(task, 5), 1)
        self.assertEqual(capture.events[-1]["error"]["code"], "outcome_unknown")

    async def test_malformed_upstream_fails_all_lanes(self):
        task, capture = self.call()
        ws, _ = await self.request()
        await ws.send("not JSON")
        self.assertEqual(await asyncio.wait_for(task, 5), 1)
        self.assertEqual(capture.events[-1]["type"], "error")

    async def test_slow_consumer_queue_overflow_retires_connection(self):
        gate = asyncio.Event()
        original = G["drain_line"]
        blocked = asyncio.Event()

        async def slow_drain(writer, obj):
            if obj.get("op") == "event" and obj["event"].get("type") == "response.output_text.delta":
                blocked.set()
                await gate.wait()
            await original(writer, obj)

        with patch.dict(G, drain_line=slow_drain):
            task, capture = self.call()
            ws, body = await self.request()
            generation = self.broker.connection
            delta = {"type": "response.output_text.delta", "stream_id": body["stream_id"], "delta": "x"}
            await self.send(ws, delta)
            await asyncio.wait_for(blocked.wait(), 5)
            for _ in range(M["MAX_QUEUE_EVENTS"] + 1):
                await self.send(ws, delta)
            await until(lambda: generation.retired)
            gate.set()
            self.assertEqual(await asyncio.wait_for(task, 5), 1)
            self.assertIn("bounded event queue", capture.events[-1]["error"]["message"])

    async def test_actual_endpoint_path_and_provider_headers(self):
        for provider, expected in (("openai", "Bearer native-test-key"), ("openai-compatible", "Bearer compatible-test-key")):
            with self.subTest(provider=provider), patch.dict(os.environ, {
                "LLM_PROVIDER": "adapter", "RESPONSES_WS_PROVIDER": provider,
                "LLM_API_URL": self.url.replace("ws:", "http:") + "?test=1",
                "OPENAI_API_KEY": "native-test-key", "LLM_API_KEY": "compatible-test-key",
            }, clear=True):
                proc = await asyncio.create_subprocess_exec(sys.executable, str(ROOT / "tools/responses-ws"),
                    "--model", "test-model", "--max-tokens", "32", "--api-format", "responses",
                    stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
                communicate = asyncio.create_task(proc.communicate(b"[]"))
                try:
                    ws, _ = await self.request()
                    self.assertEqual(ws.request.path, "/v1/responses?test=1")
                    self.assertEqual(ws.request.headers["Authorization"], expected)
                    await self.send(ws, completed(None))
                    out, err = await asyncio.wait_for(communicate, 5)
                    self.assertEqual(proc.returncode, 0, err)
                    self.assertEqual(out, b"ok")
                finally:
                    if proc.returncode is None:
                        proc.terminate()
                        await proc.wait()
                    await communicate

    async def test_missing_configured_broker_does_not_fall_back(self):
        with patch.dict(os.environ, RESPONSES_WS_URL=self.url, RESPONSES_WS_SOCKET=self.tmp.name + "/missing"):
            proc = await asyncio.create_subprocess_exec(sys.executable, str(ROOT / "tools/responses-ws"),
                "--model", "test-model", "--max-tokens", "32", "--api-format", "responses",
                stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
            out, err = await asyncio.wait_for(proc.communicate(b"[]"), 5)
            self.assertNotEqual(proc.returncode, 0)
            self.assertNotIn(b"Traceback", err)
            self.assertEqual(out, b"")
            self.assertEqual(self.received, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
