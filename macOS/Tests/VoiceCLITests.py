"""Exercise the real CLI against a local API fixture; no account or app required."""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

calls = []
fail_refresh = False

class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        calls.append(('GET', self.path))
        if fail_refresh:
            self.reply(502, {'ok': False, 'error': {'code': 'voices_unavailable', 'message': 'Refresh failed'}})
        else:
            self.reply(200, {'ok': True, 'selected': 'voice-id', 'model': 'eleven_v3',
                             'voices': [{'id': 'voice-id', 'name': 'Alice', 'detail': 'British'}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append(('POST', self.path, body))
        self.reply(200, {'ok': True, 'selected': {'id': 'voice-id', 'name': 'Alice'}})

server = HTTPServer(('127.0.0.1', 0), Handler)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
env = {**os.environ, 'BOTSPEAKER_CONTROL_URL': f'http://127.0.0.1:{server.server_port}',
       'BOTSPEAKER_TOKEN': 'fixture-token', 'BOTSPEAKER_NO_LAUNCH': '1'}
def run(*args):
    return subprocess.run([sys.argv[1], *args], env=env, capture_output=True, text=True, timeout=10)

try:
    result = run('voices', '--refresh', '--select', 'Alice', '--json')
    assert result.returncode == 0, result.stderr
    assert calls == [('GET', '/v1/voices?refresh=1'), ('POST', '/v1/voices/select', {'voice': 'Alice'})], calls
    assert json.loads(result.stdout)['selected']['id'] == 'voice-id'
    print('PASS: --refresh --select refreshes before selecting; JSON stays parseable')
    calls.clear()
    fail_refresh = True
    result = run('voices', '--refresh', '--select', 'Alice', '--json')
    assert result.returncode == 1 and len(calls) == 1, (result.stdout, calls)
    assert json.loads(result.stdout)['error']['code'] == 'voices_unavailable'
    print('PASS: refresh failure prevents selection and returns a structured error')
    fail_refresh = False
    result = run('voices')
    assert result.returncode == 0 and 'Model: eleven_v3' in result.stdout and '*  voice-id' in result.stdout, result.stdout
    print('PASS: voice list shows model context and selected voice')
finally:
    server.shutdown()
    server.server_close()
