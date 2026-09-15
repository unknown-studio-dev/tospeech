import io, json, unittest
from serve import serve, ReferenceCache
class ServeTests(unittest.TestCase):
    def run_lines(self, lines, handler):
        out=io.StringIO(); serve(handler, io.StringIO(''.join(l+'\n' for l in lines)), out, ready=dict(loadSeconds=1.5)); return [json.loads(l) for l in out.getvalue().splitlines()]
    def test_ready_then_complete_then_eof(self):
        calls=[]
        def handler(request, output): calls.append((request,output)); return dict(policy='p')
        msgs=self.run_lines([json.dumps(dict(id='a',request=dict(words=[]),output='/tmp/x.json'))], handler)
        self.assertEqual(msgs[0], dict(status='ready', loadSeconds=1.5))
        self.assertEqual(msgs[1]['id'],'a'); self.assertEqual(msgs[1]['status'],'complete'); self.assertEqual(msgs[1]['output'],'/tmp/x.json')
        self.assertEqual(calls[0][1],'/tmp/x.json')
    def test_error_is_reported_per_request_and_loop_continues(self):
        def handler(request, output):
            if request.get('boom'): raise ValueError('no_speech')
            return {}
        msgs=self.run_lines([json.dumps(dict(id='1',request=dict(boom=True),output='/tmp/a')), json.dumps(dict(id='2',request={},output='/tmp/b'))], handler)
        self.assertEqual((msgs[1]['id'],msgs[1]['status'],msgs[1]['message']),('1','error','no_speech'))
        self.assertEqual((msgs[2]['id'],msgs[2]['status']),('2','complete'))
    def test_ping_and_malformed_line(self):
        msgs=self.run_lines(['not json', json.dumps(dict(id='p',command='ping'))], lambda r,o: {})
        self.assertEqual(msgs[1]['status'],'error'); self.assertEqual((msgs[2]['id'],msgs[2]['status']),('p','ready'))
    def test_non_object_json_line_is_reported_and_loop_continues(self):
        msgs=self.run_lines(['null', json.dumps(dict(id='p',command='ping'))], lambda r,o: {})
        self.assertEqual(msgs[1]['status'],'error'); self.assertEqual((msgs[2]['id'],msgs[2]['status']),('p','ready'))
    def test_reference_cache_is_lru_by_bytes(self):
        c=ReferenceCache(max_entries=2); k=lambda b: c.key(b)
        c.put(k(b'a'),'A'); c.put(k(b'b'),'B'); self.assertEqual(c.get(k(b'a')),'A'); c.put(k(b'c'),'C')
        self.assertIsNone(c.get(k(b'b'))); self.assertEqual(c.get(k(b'c')),'C'); self.assertNotEqual(k(b'a'),k(b'b'))
