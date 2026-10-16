import http.server,threading,subprocess,time,json,tempfile,os
from pathlib import Path
DATA=bytes(range(256))*12288
RANGES=[]
class Server(http.server.ThreadingHTTPServer):
 def handle_error(self,*a):pass
class Handler(http.server.BaseHTTPRequestHandler):
 def log_message(self,*a):pass
 def do_GET(self):
  header=self.headers.get('Range');RANGES.append((self.path,header))
  offset=int(header[6:].split('-')[0]) if header else 0
  if self.path=='/error':self.send_response(503);self.end_headers();return
  if self.path=='/ignore':offset=0
  self.send_response(206 if header and self.path!='/ignore' else 200)
  if header and self.path!='/ignore':self.send_header('Content-Range',f'bytes {offset+1 if self.path=="/bad" else offset}-{len(DATA)-1}/{len(DATA)}')
  self.send_header('Content-Length',str(len(DATA)-offset+(1 if self.path=='/oversize' else 0)))
  self.end_headers()
  end=offset+131072 if self.path=='/truncate' else len(DATA)
  for i in range(offset,end,16384):self.wfile.write(DATA[i:min(i+16384,end)]);self.wfile.flush();time.sleep(.003)
server=Server(('127.0.0.1',0),Handler);threading.Thread(target=server.serve_forever,daemon=True).start()
base='http://127.0.0.1:'+str(server.server_port)
repo=Path(__file__).resolve().parent.parent
scratch=tempfile.TemporaryDirectory()
folder=Path(scratch.name);fixture=folder/'fixture';checks=[]
env=dict(os.environ,DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer'))
subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library',str(repo/'Applications/LLMEval/Services/ModelFileDownload.swift'),str(repo/'Tests/DownloadTransport/Fixture.swift'),'-o',str(fixture)],env=env,check=True)
def run(name,path='/resume',prefix=b'',cancel=None,success=True,unchanged=False):
 f=folder/(name+'.partial');f.write_bytes(prefix)
 args=[str(fixture),base+path,str(f),str(len(DATA))]+([str(cancel)] if cancel else [])
 r=subprocess.run(args,capture_output=True,text=True,timeout=10)
 ok=(r.returncode==0)==success
 if success:ok=ok and f.read_bytes()==DATA
 if unchanged:ok=ok and f.read_bytes()==prefix
 checks.append({'name':name,'passed':ok,'bytes':f.stat().st_size,'exit':r.returncode})
 assert ok,(name,r.stdout,r.stderr)
 return f
try:
 run('fresh')
 f=run('cancel',cancel=70,success=False)
 prefix=f.read_bytes();assert 0<len(prefix)<len(DATA)
 run('resume',prefix=prefix)
 assert RANGES[-1][1]=='bytes='+str(len(prefix))+'-'
 run('ignore_range',path='/ignore',prefix=DATA[:327680])
 run('bad_range',path='/bad',prefix=DATA[:327680],success=False,unchanged=True)
 run('http_error',path='/error',prefix=DATA[:327680],success=False,unchanged=True)
 f=run('truncated',path='/truncate',success=False);prefix=f.read_bytes();assert prefix
 run('resume_after_error',prefix=prefix)
 run('oversize',path='/oversize',success=False,unchanged=True)
 count=len(RANGES);run('complete_prefix',prefix=DATA);assert len(RANGES)==count
finally:server.shutdown()
report={'passed':all(c['passed'] for c in checks),'summary':{'passed':sum(c['passed'] for c in checks),'total':len(checks)},'checks':checks}
(repo/'.local').mkdir(exist_ok=True)
(repo/'.local/resume-transport-verification.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
