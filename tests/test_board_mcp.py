"""Isolated Board MCP checks: fake IPC only; no camera, user library or model calls."""
import base64
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from unittest import mock
import zlib

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/board-mcp.py'
SPEC = importlib.util.spec_from_file_location('board_mcp', SCRIPT)
mcp = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(mcp)
REGION = '00000000-0000-4000-8000-000000000001'
OVERLAY = '00000000-0000-4000-8000-000000000002'


def png(width=3, height=2):
    def chunk(name, data):
        return struct.pack('>I', len(data)) + name + data + struct.pack('>I', zlib.crc32(name + data))
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)) + \
        chunk(b'IDAT', zlib.compress((b'\0' + b'\x12\x34\x56' * width) * height)) + chunk(b'IEND', b'')


def overlay(**changes):
    return dict({'id': OVERLAY, 'regionID': REGION, 'kind': 'text', 'title': 'Architecture', 'text': 'Input → model'}, **changes)


class BoardMCPChecks(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(); self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name); self.ipc = self.root / 'collaboration'
        for name in ('requests', 'responses', 'images'): (self.ipc / name).mkdir(parents=True)
        self.status = {'schemaVersion': 1, 'updatedAt': time.time(), 'revision': 3, 'cameraOn': False, 'tracking': 'off', 'regions': []}
        self.write_status()
        self.client = mcp.BoardIPC(self.root, timeout=0.4, poll=0.003)
        self.requests = []; self.worker_errors = []; self.stop = threading.Event()
        self.worker = None
        self.addCleanup(self.stop_worker)

    def write_status(self):
        (self.ipc / 'status.json').write_text(json.dumps(self.status))

    def stop_worker(self):
        self.stop.set()
        if self.worker: self.worker.join(1)
        self.assertEqual(self.worker_errors, [])

    def serve(self, handler):
        def work():
            seen = set()
            while not self.stop.wait(0.002):
                for path in (self.ipc / 'requests').glob('*.json'):
                    if path.name in seen: continue
                    seen.add(path.name)
                    try:
                        request = json.loads(path.read_text()); self.requests.append(request)
                        self.assertEqual(request['schemaVersion'], 1)
                        self.assertEqual(path.stem, str(uuid.UUID(request['id'])).upper())
                        self.assertLess(abs(time.time() - request['createdAt']), 15)
                        result = handler(request)
                        if result is None: continue
                        response = {'schemaVersion': 1, 'id': request['id'], **result}
                        temporary = self.ipc / 'responses' / ('.' + path.name + '.tmp')
                        temporary.write_text(json.dumps(response)); temporary.replace(self.ipc / 'responses' / path.name)
                    except Exception as error:
                        self.worker_errors.append(repr(error)); self.stop.set(); return
        self.worker = threading.Thread(target=work, daemon=True); self.worker.start()

    def assert_own_artifacts_clean(self):
        for request in self.requests:
            for folder, extension in [('requests', '.json'), ('responses', '.json'), ('images', '.png')]:
                self.assertFalse((self.ipc / folder / (request['id'] + extension)).exists())

    def test_default_region_arguments_and_overlay_normalization(self):
        value = mcp.validate_arguments('board_read_region', {'region_id': REGION.lower()})
        self.assertEqual(value, {'region_id': REGION, 'max_edge': 1024, 'include_overlays': False})
        value = mcp.validate_arguments('board_put_overlay', {'overlay': overlay()})['overlay']
        self.assertEqual((value['opacity'], value['hidden'], value['nodes'], value['edges']), (1, False, [], []))
        self.assertNotIn('revision', value)
        self.assertNotIn('frame', value)  # Existing overlays retain full-region placement.
        self.assertEqual(mcp.validate_arguments('board_status', {'since_revision': 0}), {'since_revision': 0})
        self.assertEqual(mcp.validate_arguments('board_list_overlays', {'overlay_id': OVERLAY}), {'overlay_id': OVERLAY})

    def test_overlay_frame_schema_is_optional_and_describes_top_left_coordinates(self):
        specification = next(t for t in mcp.TOOLS if t['name'] == 'board_put_overlay')
        schema = specification['inputSchema']['properties']['overlay']
        self.assertNotIn('frame', schema['required'])
        frame_schema = schema['properties']['frame']
        self.assertEqual(set(frame_schema['required']), {'x', 'y', 'width', 'height'})
        self.assertFalse(frame_schema['additionalProperties'])
        self.assertIn('top left', frame_schema['description'])
        self.assertIn('overlay frame', mcp.NODE_SCHEMA['description'])

    def test_small_note_and_diagram_frame_forward_exactly_without_camera_reads(self):
        frame = {'x': .53, 'y': .12, 'width': .38, 'height': .22}
        self.serve(lambda request: {'result': {'overlay': request['arguments']['overlay']}})
        for kind in ('text', 'diagram'):
            with self.subTest(kind=kind):
                value = overlay(kind=kind, frame=frame)
                result = self.client.call('board_put_overlay', {'overlay': value})
                actual = json.loads(result['content'][0]['text'])['overlay']
                self.assertEqual(actual['frame'], frame)
                self.assertEqual(self.requests[-1]['arguments']['overlay']['frame'], frame)
                self.assertNotIn('expected_revision', self.requests[-1]['arguments'])
                self.assertEqual([block['type'] for block in result['content']], ['text'])
                self.assertEqual(value['frame'], frame)
        self.assert_own_artifacts_clean()

    def test_overlay_frame_repositioning_keeps_compare_and_swap(self):
        frame = {'x': 0, 'y': .8, 'width': 1, 'height': .2}
        self.serve(lambda request: {'result': {'overlay': request['arguments']['overlay']}})
        self.client.call('board_put_overlay', {'overlay': overlay(frame=frame), 'expected_revision': 7})
        self.assertEqual(self.requests[0]['arguments']['expected_revision'], 7)
        self.assertEqual(self.requests[0]['arguments']['overlay']['frame'], frame)
        self.assert_own_artifacts_clean()

    def test_invalid_overlay_frames_rejected_before_ipc(self):
        frame = {'x': .2, 'y': .3, 'width': .4, 'height': .5}
        invalid = [None, [], 'small', {}, {'x': 0, 'y': 0, 'width': .4}, dict(frame, unknown=1),
                   dict(frame, x=-.1), dict(frame, y=-.1), dict(frame, width=0), dict(frame, height=0),
                   dict(frame, width=-.1), dict(frame, height=-.1), dict(frame, x=1.1),
                   dict(frame, width=1.1), dict(frame, width=.9), dict(frame, height=.9),
                   dict(frame, x=float('nan')), dict(frame, y=float('inf')), dict(frame, width='0.4')]
        invalid.extend(dict(frame, **{key: True}) for key in frame)
        for value in invalid:
            with self.subTest(frame=value), self.assertRaises(ValueError):
                self.client.call('board_put_overlay', {'overlay': overlay(frame=value)})
        self.assertEqual(list((self.ipc / 'requests').iterdir()), [])
        for boundary in [dict(x=0, y=0, width=1, height=1), dict(x=.1, y=.2, width=.9, height=.8)]:
            self.assertEqual(mcp.validate_overlay(overlay(frame=boundary))['frame'], boundary)

    def test_bad_arguments_rejected_before_any_ipc_write(self):
        cases = [('board_read_region', {'region_id': '../private'}),
                 ('board_read_region', {'region_id': REGION, 'path': '/private'}),
                 ('board_read_region', {'region_id': REGION, 'max_edge': True}),
                 ('board_read_region', {'region_id': REGION, 'max_edge': 1601}),
                 ('board_read_region', {'region_id': REGION, 'max_edge': 255}),
                 ('board_read_region', {'region_id': REGION, 'include_overlays': 1}),
                 ('board_put_overlay', {'overlay': overlay(revision=1)}),
                 ('board_put_overlay', {'overlay': overlay(title='x' * 121)}),
                 ('board_put_overlay', {'overlay': overlay(text='x' * 4001)}),
                 ('board_put_overlay', {'overlay': overlay(opacity=float('nan'))}),
                 ('board_set_overlay', {'overlay_id': OVERLAY, 'expected_revision': 1}),
                 ('board_set_overlay', {'overlay_id': OVERLAY, 'expected_revision': True, 'hidden': True}),
                 ('board_status', {'since_revision': -1}), ('unknown', {})]
        for name, arguments in cases:
            with self.subTest(name=name, arguments=arguments), self.assertRaises(ValueError): self.client.call(name, arguments)
        self.assertEqual(list((self.ipc / 'requests').iterdir()), [])

    def test_diagram_bounds_unique_ids_and_existing_edge_endpoints(self):
        node = {'id': 'a', 'x': 0.1, 'y': 0.1, 'width': 0.3, 'height': 0.2, 'label': 'A'}
        valid = overlay(kind='diagram', nodes=[node, dict(node, id='b')], edges=[{'from': 'a', 'to': 'b'}])
        self.assertEqual(mcp.validate_overlay(valid)['edges'][0]['label'], '')
        for values in [overlay(nodes=[node, node]), overlay(nodes=[dict(node, width=1)]),
                       overlay(nodes=[dict(node, width=0)]), overlay(nodes=[node], edges=[{'from': 'a', 'to': 'b'}]),
                       overlay(nodes=[node], edges=[{'from': 'a', 'to': 'a'}]),
                       overlay(nodes=[node] * 25), overlay(edges=[{}] * 41)]:
            with self.subTest(values=values), self.assertRaises(ValueError): mcp.validate_overlay(values)

    def test_metadata_never_reads_an_image_and_cleanup_preserves_foreign_files(self):
        foreign = self.ipc / 'images' / 'user-photo.png'; foreign.write_bytes(b'preserve')
        self.serve(lambda request: {'result': {'cameraOn': False, 'overlays': [], 'revision': 3}})
        original = mcp.read_file; reads = []
        def monitored(directory, filename, limit):
            reads.append(filename); return original(directory, filename, limit)
        with mock.patch.object(mcp, 'read_file', side_effect=monitored):
            for name in ('board_status', 'board_list_overlays'):
                result = self.client.call(name, {})
                self.assertEqual([x['type'] for x in result['content']], ['text'])
        self.assertTrue(all(name.endswith('.json') for name in reads))
        self.assertEqual(foreign.read_bytes(), b'preserve'); self.assert_own_artifacts_clean()

    def image_handler(self, request):
        image_name = request['id'] + '.png'; (self.ipc / 'images' / image_name).write_bytes(png())
        return {'result': {'imageName': image_name, 'width': 3, 'height': 2, 'regionID': REGION,
                           'label': 'Current architecture', 'revision': 7}}

    def test_region_returns_one_validated_png_and_compact_metadata(self):
        self.serve(self.image_handler)
        result = self.client.call('board_read_region', {'region_id': REGION})
        self.assertEqual(base64.b64decode(result['content'][1]['data']), png())
        self.assertEqual(result['content'][1]['mimeType'], 'image/png')
        metadata = json.loads(result['content'][0]['text'])
        self.assertEqual(metadata['regionID'], REGION); self.assertNotIn('imageName', metadata)
        self.assertEqual(self.requests[0]['arguments']['max_edge'], 1024)
        self.assertFalse(self.requests[0]['arguments']['include_overlays'])
        self.assert_own_artifacts_clean()

    def test_unrequested_region_or_path_never_loaded(self):
        foreign = self.root / 'outside.png'; foreign.write_bytes(png())
        def handler(request):
            result = self.image_handler(request); result['result']['imageName'] = '../../outside.png'; return result
        self.serve(handler)
        with self.assertRaisesRegex(ValueError, 'unexpected region image name'):
            self.client.call('board_read_region', {'region_id': REGION})
        self.assertEqual(foreign.read_bytes(), png()); self.assert_own_artifacts_clean()

    def test_region_identity_checked(self):
        def handler(request):
            result = self.image_handler(request); result['result']['regionID'] = OVERLAY; return result
        self.serve(handler)
        with self.assertRaisesRegex(ValueError, 'different region'):
            self.client.call('board_read_region', {'region_id': REGION})
        self.assert_own_artifacts_clean()

    def test_png_dimensions_must_match_metadata(self):
        def handler(request):
            result = self.image_handler(request); result['result']['width'] = 4; return result
        self.serve(handler)
        with self.assertRaisesRegex(ValueError, 'matching PNG'):
            self.client.call('board_read_region', {'region_id': REGION})
        self.assert_own_artifacts_clean()

    def test_native_cannot_return_larger_than_requested(self):
        def handler(request):
            result = self.image_handler(request); result['result']['width'] = 1025; return result
        self.serve(handler)
        with self.assertRaisesRegex(ValueError, 'requested dimensions'):
            self.client.call('board_read_region', {'region_id': REGION})

    def test_symlink_image_not_followed_or_target_deleted(self):
        target = self.root / 'original.png'; target.write_bytes(png())
        def handler(request):
            name = request['id'] + '.png'; (self.ipc / 'images' / name).symlink_to(target)
            return {'result': {'imageName': name, 'width': 3, 'height': 2, 'regionID': REGION, 'label': 'Board'}}
        self.serve(handler)
        with self.assertRaises(OSError): self.client.call('board_read_region', {'region_id': REGION})
        self.assertEqual(target.read_bytes(), png()); self.assert_own_artifacts_clean()

    def test_symlink_ipc_directory_is_rejected(self):
        folder = self.ipc / 'requests'; folder.rmdir()
        target = self.root / 'other'; target.mkdir(); folder.symlink_to(target, target_is_directory=True)
        with self.assertRaises(OSError): self.client.call('board_status', {})
        self.assertEqual(list(target.iterdir()), [])

    def test_stale_future_and_invalid_heartbeats_prevent_requests(self):
        for heartbeat in [time.time() - 15.1, time.time() + 10, True, 'now', float('nan')]:
            self.status['updatedAt'] = heartbeat; self.write_status()
            with self.subTest(heartbeat=heartbeat), self.assertRaises(ValueError): self.client.call('board_status', {})
        self.assertEqual(list((self.ipc / 'requests').iterdir()), [])

    def test_timeout_mutation_is_uncertain_once_and_never_retried(self):
        self.client.timeout = 0.05
        self.serve(lambda request: None)
        with self.assertRaisesRegex(ValueError, 'may already have happened.*not retried'):
            self.client.call('board_put_overlay', {'overlay': overlay()})
        self.assertEqual(len(self.requests), 1); self.assert_own_artifacts_clean()

    def test_timeout_read_does_not_claim_mutation(self):
        self.client.timeout = 0.05; self.serve(lambda request: None)
        with self.assertRaisesRegex(ValueError, 'not retried') as error: self.client.call('board_list_overlays', {})
        self.assertNotIn('may already', str(error.exception)); self.assertEqual(len(self.requests), 1)
        self.assert_own_artifacts_clean()

    def test_revision_conflict_is_reported_without_retry(self):
        self.serve(lambda request: {'error': 'Revision conflict; inspect the current overlay.'})
        with self.assertRaisesRegex(ValueError, '^Revision conflict') as error:
            self.client.call('board_set_overlay', {'overlay_id': OVERLAY, 'expected_revision': 3, 'hidden': True})
        self.assertNotIn('uncertain', str(error.exception)); self.assertEqual(len(self.requests), 1)
        self.assertEqual(self.requests[0]['arguments']['expected_revision'], 3)
        self.assert_own_artifacts_clean()

    def test_invalid_mutation_response_does_not_claim_failure_was_certain(self):
        self.serve(lambda request: {'id': OVERLAY, 'result': {'revision': 4}})
        with self.assertRaisesRegex(ValueError, 'outcome is uncertain'):
            self.client.call('board_put_overlay', {'overlay': overlay(), 'expected_revision': 3})
        self.assertEqual(len(self.requests), 1)

    def test_oversized_status_is_preserved_without_publishing(self):
        path = self.ipc / 'status.json'; value = b'x' * (mcp.MAX_METADATA_JSON + 1); path.write_bytes(value)
        with self.assertRaisesRegex(ValueError, 'too large'): self.client.call('board_status', {})
        self.assertEqual(path.read_bytes(), value); self.assertEqual(list((self.ipc / 'requests').iterdir()), [])

    def test_request_envelope_size_is_bounded(self):
        huge = overlay(text='😀' * 4000, nodes=[{'id': str(i), 'x': 0, 'y': 0, 'width': 0.1, 'height': 0.1, 'label': '😀' * 400} for i in range(24)],
                       edges=[{'from': '0', 'to': '1', 'label': '😀' * 200} for _ in range(40)])
        # All field lengths fit, but their UTF-8 serialization exceeds the IPC budget.
        with self.assertRaisesRegex(ValueError, '64 KiB'): self.client.call('board_put_overlay', {'overlay': huge})
        self.assertEqual(list((self.ipc / 'requests').iterdir()), [])

    def test_status_revision_is_scoped_to_app_instance(self):
        instance = 'ABCDEFAB-1234-4000-8000-ABCDEFABCDEF'
        def handler(request):
            arguments = request['arguments']
            if arguments.get('since_revision') == 3 and arguments.get('instance_id') == instance:
                return {'result': {'unchanged': True, 'revision': 3, 'instanceID': instance}}
            return {'result': {'revision': 3, 'instanceID': instance, 'regions': [{'id': REGION}]}}
        self.serve(handler)
        same = self.client.call('board_status', {'since_revision': 3, 'instance_id': instance.lower()})
        self.assertTrue(json.loads(same['content'][0]['text'])['unchanged'])
        self.assertEqual(self.requests[-1]['arguments']['instance_id'], instance)
        restarted = self.client.call('board_status', {'since_revision': 3, 'instance_id': OVERLAY})
        self.assertIn('regions', json.loads(restarted['content'][0]['text']))
        legacy = self.client.call('board_status', {'since_revision': 3})
        self.assertIn('regions', json.loads(legacy['content'][0]['text']))
        with self.assertRaisesRegex(ValueError, 'UUID'):
            self.client.call('board_status', {'since_revision': 3, 'instance_id': '../invalid'})
        self.assertEqual(len(self.requests), 3)
        self.assert_own_artifacts_clean()

    def test_diagram_native_string_bounds_match_published_schema(self):
        node = {'id': 'a' * 64, 'x': 0, 'y': 0, 'width': 0.3, 'height': 0.3, 'label': 'A' * 400}
        other = dict(node, id='b')
        valid = overlay(kind='diagram', nodes=[node, other], edges=[{'from': node['id'], 'to': 'b', 'label': 'E' * 200}])
        self.assertEqual(mcp.validate_overlay(valid)['nodes'][0]['label'], node['label'])
        for value in [overlay(nodes=[dict(node, id='a' * 65)]), overlay(nodes=[dict(node, label='A' * 401)]),
                      overlay(nodes=[node, other], edges=[{'from': node['id'], 'to': 'b', 'label': 'E' * 201}]),
                      overlay(nodes=[node], edges=[{'from': node['id'], 'to': node['id']}])]:
            with self.subTest(value=value), self.assertRaises(ValueError): mcp.validate_overlay(value)
        self.assertEqual(mcp.NODE_SCHEMA['properties']['id']['maxLength'], 64)
        self.assertEqual(mcp.NODE_SCHEMA['properties']['label']['maxLength'], 400)
        self.assertEqual(mcp.EDGE_SCHEMA['properties']['label']['maxLength'], 200)
        self.assertEqual(mcp.EDGE_SCHEMA['properties']['from']['maxLength'], 64)
        self.assertEqual(mcp.EDGE_SCHEMA['properties']['to']['maxLength'], 64)
        status_schema = next(t['inputSchema'] for t in mcp.TOOLS if t['name'] == 'board_status')
        self.assertEqual(status_schema['properties']['instance_id']['format'], 'uuid')

    def test_metadata_above_request_budget_is_accepted_but_stays_bounded(self):
        self.status['padding'] = 'x' * (mcp.MAX_JSON + 1); self.write_status()
        self.serve(lambda request: {'result': {'overlays': [], 'note': 'y' * (mcp.MAX_JSON + 1)}})
        result = self.client.call('board_list_overlays', {})
        self.assertGreater(len(result['content'][0]['text']), mcp.MAX_JSON)
        self.assertLess(len(result['content'][0]['text']), mcp.MAX_METADATA_JSON)
        self.assertLess(len(mcp.encode(self.requests[0])), mcp.MAX_JSON)
        self.assertEqual([block['type'] for block in result['content']], ['text'])
        self.assertEqual(mcp.MAX_METADATA_JSON, 256 * 1024)
        self.assertEqual(mcp.MAX_IMAGE, 12 * 1024 * 1024)
        self.assertEqual(mcp.MAX_JSON, 64 * 1024)
        self.assert_own_artifacts_clean()

    def test_response_above_metadata_budget_is_rejected_and_cleaned(self):
        self.serve(lambda request: {'result': {'padding': 'x' * mcp.MAX_METADATA_JSON}})
        with self.assertRaisesRegex(ValueError, 'too large'):
            self.client.call('board_list_overlays', {})
        self.assertEqual(len(self.requests), 1)
        self.assert_own_artifacts_clean()

    def test_stdio_protocol_roundtrip_and_tool_metadata(self):
        self.serve(lambda request: {'result': {'revision': 3, 'cameraOn': False, 'regions': []}})
        requests = [{'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
                    {'jsonrpc': '2.0', 'method': 'notifications/initialized'},
                    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
                    {'jsonrpc': '2.0', 'id': 3, 'method': 'tools/call', 'params': {'name': 'board_status', 'arguments': {}}},
                    {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'board_read_region', 'arguments': {'region_id': 'bad'}}},
                    {'jsonrpc': '2.0', 'id': 5, 'method': 'ping'}]
        process = subprocess.run([sys.executable, str(SCRIPT)], input=''.join(json.dumps(x) + '\n' for x in requests),
                                 text=True, capture_output=True, env=dict(os.environ, BOARD_LIBRARY=str(self.root)), timeout=3)
        self.assertEqual(process.returncode, 0); self.assertEqual(process.stderr, '')
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([r['id'] for r in replies], [1, 2, 3, 4, 5])
        self.assertEqual(len(replies[1]['result']['tools']), 5)
        tools = {t['name']: t for t in replies[1]['result']['tools']}
        self.assertFalse(tools['board_put_overlay']['annotations']['readOnlyHint'])
        self.assertTrue(tools['board_read_region']['annotations']['readOnlyHint'])
        self.assertFalse(replies[2]['result']['isError']); self.assertTrue(replies[3]['result']['isError'])
        self.assertEqual(len(self.requests), 1)

    def test_stdio_invalid_json_and_oversized_input_are_bounded(self):
        process = subprocess.run([sys.executable, str(SCRIPT)], input=b'bad\n' + b'x' * (mcp.MAX_JSON + 1), capture_output=True, timeout=2)
        self.assertEqual(process.returncode, 0)
        replies = [json.loads(line) for line in process.stdout.splitlines()]
        self.assertEqual([r['error']['code'] for r in replies], [-32700, -32600])


if __name__ == '__main__': unittest.main()
