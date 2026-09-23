"""Exercise the built macOS CLI with a loopback fixture, never a paid API."""
import json
import os
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

calls = []
state = 'finished_dispatching'
partial_failure = False
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        calls.append((self.path, body))
        action = self.path.rsplit('/', 1)[-1]
        if action == 'status':
            response = {'ok': True, 'configured': True, 'jobs': [{'id': 'job', 'status': state}]}
        elif action == 'meeting-status':
            response = {'ok': True, 'meeting': {'id': 'plan', 'status': 'finished'}}
        elif action.startswith('meeting-'):
            response = {'ok': True, 'meeting': {'id': 'plan', 'status': 'starting'}}
        elif action == 'remove-all':
            response = {'ok': not partial_failure, 'removed': [], 'failures': [{'botId': 'bot', 'error': 'fixture'}] if partial_failure else []}
        else:
            response = {'ok': True, 'job': {'id': 'job', 'status': 'preparing'}}
        data = json.dumps(response).encode()
        self.send_response(200)
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

server = HTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()
env = {key: value for key, value in os.environ.items() if key not in ('RECALL_API_KEY', 'RECALL_AI_API_KEY')}
env.update(BOTSPEAKER_CONTROL_URL=f'http://127.0.0.1:{server.server_port}', BOTSPEAKER_TOKEN='fixture', BOTSPEAKER_NO_LAUNCH='1')
def run(*args, stdin=None, code=0):
    calls.clear()
    result = subprocess.run([sys.argv[1], 'recall', *args], input=stdin, env=env, text=True, capture_output=True, timeout=10)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result
try:
    run('list', '--meeting', '123')
    assert calls[-1] == ('/v1/recall/list', {'meetingId': '123'})
    run('add', '--file', '-', '--name', 'Alice', '--passcode', 'abc', stdin='Meeting ID: 123\nPasscode: abc')
    assert calls[-1][1] == {'meetingUrl': 'Meeting ID: 123\nPasscode: abc', 'name': 'Alice', 'passcode': 'abc'}
    run('remove-all', '--meeting', '123')
    assert calls[-1][1] == {'meetingId': '123'}
    partial_failure = True
    result = run('remove-all', '--meeting', '123', code=1)
    assert json.loads(result.stdout)['failures'][0]['error'] == 'fixture'
    partial_failure = False
    print('PASS: scoped list/removal, invitation stdin, passcode, partial-failure exit')

    state = 'prepared'
    result = run('prepare', 'bot', 'hello', '--voice', 'voice', '--wait')
    assert calls[0][1] == {'botId': 'bot', 'text': 'hello', 'voice': 'voice'}
    assert json.loads(result.stdout)['job']['status'] == 'prepared'
    state = 'finished_dispatching'
    run('dispatch', 'job', '--wait')
    assert calls[0] == ('/v1/recall/dispatch', {'id': 'job'})
    run('speak', 'bot', '--file', '-', '--repeat', '2', '--wait', stdin='hello')
    assert calls[0][1]['repeat'] == 2 and calls[0][1]['text'] == 'hello'
    run('wait', 'job')
    state = 'failed'
    run('wait', 'job', '--json', code=1)
    state = 'prepared'
    result = run('wait', 'job', '--timeout', '0.1', '--json', code=1)
    assert 'Work continues' in result.stdout
    print('PASS: preparation, dispatch, speech repeats, waits, failure and timeout exits')

    plan = {'turns': [{'botId': 'bot', 'voice': 'voice', 'text': 'hello'}]}
    run('meeting-create', '--file', '-', stdin=json.dumps(plan))
    assert calls[0][1] == plan
    run('meeting-start', 'plan', '--wait')
    assert [c[0] for c in calls] == ['/v1/recall/meeting-start', '/v1/recall/meeting-status']
    for action in ('meeting-status', 'meeting-skip', 'meeting-stop', 'meeting-wait'):
        run(action, 'plan')
        assert calls[0][1] == {'id': 'plan'}
    for args in [('remove-all',), ('prepare', 'bot', 'x', '--at', '+10'), ('list', '--wait'), ('speak', 'bot', 'x', '--repeat', '0'), ('wait', 'job', '--timeout', 'nan'), ('status', 'extra')]:
        run(*args, code=64)
        assert not calls, args
    print('PASS: JSON plans and all meeting controls; invalid commands rejected before HTTP')
finally:
    server.shutdown()
    server.server_close()
