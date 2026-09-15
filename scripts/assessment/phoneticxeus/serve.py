"""JSON-lines daemon loop for the PhoneticXeus helper. No torch import here; the handler is injected."""
import json, sys, hashlib, time
from collections import OrderedDict
class ReferenceCache:
    def __init__(self, max_entries=32): self.max=max_entries; self.items=OrderedDict()
    @staticmethod
    def key(pcm_bytes): return hashlib.sha256(pcm_bytes).hexdigest()+':'+str(len(pcm_bytes))
    def get(self, key):
        if key not in self.items: return None
        self.items.move_to_end(key); return self.items[key]
    def put(self, key, value):
        self.items[key]=value; self.items.move_to_end(key)
        while len(self.items)>self.max: self.items.popitem(last=False)
def _write(stdout, obj): stdout.write(json.dumps(obj, ensure_ascii=False, allow_nan=False)+'\n'); stdout.flush()
def serve(handler, stdin, stdout, ready):
    _write(stdout, dict(status='ready', **ready))
    for line in stdin:
        line=line.strip()
        if not line: continue
        try: message=json.loads(line)
        except Exception: _write(stdout, dict(status='error', message='malformed request line')); continue
        if not isinstance(message, dict): _write(stdout, dict(status='error', message='malformed request line')); continue
        rid=message.get('id')
        if message.get('command')=='ping': _write(stdout, dict(id=rid, status='ready')); continue
        try:
            start=time.monotonic(); result=handler(message['request'], message['output'])
            with open(message['output'],'w') as f: json.dump(result, f, ensure_ascii=False, allow_nan=False)
            _write(stdout, dict(id=rid, status='complete', output=message['output'], seconds=time.monotonic()-start))
        except Exception as e:
            _write(stdout, dict(id=rid, status='error', message=str(e) or type(e).__name__))
    return 0
