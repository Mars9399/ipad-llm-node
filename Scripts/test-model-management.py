#!/usr/bin/env python3
"""Real iPad model lifecycle test; downloads then deletes the 0.6B test model."""
import argparse, datetime, importlib.util, json, time, os, subprocess
from pathlib import Path

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--endpoint',default='http://127.0.0.1:18080')
parser.add_argument('--token-file',type=Path,default=Path(__file__).resolve().parent.parent/'.local/ipad-api-token.txt')
parser.add_argument('--report',type=Path,default=Path('model-management-verification.json'))
parser.add_argument('--device-id')
parser.add_argument('--bundle-id')
parser.add_argument('--exercise-fallback',action='store_true',help='With device access, inject a bad test-model config before deleting it')
args=parser.parse_args()
if bool(args.device_id)!=bool(args.bundle_id):parser.error('Provide both --device-id and --bundle-id')
spec=importlib.util.spec_from_file_location('client',Path(__file__).with_name('ipad-api-client.py'))
api=importlib.util.module_from_spec(spec);spec.loader.exec_module(api)
client=api.NodeClient(args.endpoint,api.read_token(args.token_file),timeout=30)
BASE='mlx-community/Qwen3-4B-4bit'
SMALL='mlx-community/Qwen3-0.6B-4bit'
report={'tested_at_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'endpoint':args.endpoint,'checks':[]}
def save():args.report.write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
def check(name,condition,details=None):
 report['checks'].append({'name':name,'passed':bool(condition),'details':details});save()
 print(name, 'PASS' if condition else 'FAIL',flush=True)
 assert condition,name
def state():return client.request_json('GET','/v1/node/models')[0]
def post(action,body):return client.request_json('POST','/v1/node/models/'+action,body)[0]
def expect_error(action,body,status=400):
 try:post(action,body)
 except api.APIError as e:return e.status==status
 return False
def wait_for(predicate,timeout=60):
 deadline=time.monotonic()+timeout
 while time.monotonic()<deadline:
  try:
   result=predicate()
   if result:return result
  except api.APIError:pass
  time.sleep(.3)
 raise AssertionError('Timed out waiting for node state')
def activate_app(bundle, restart=False):
 env=dict(os.environ,DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer'))
 command=['xcrun','devicectl','device','process','launch','--device',args.device_id,'--activate']
 if restart:command.append('--terminate-existing')
 subprocess.run(command+[bundle],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
def ready(model):
 h=client.request_json('GET','/health')[0]
 return h if h['ready'] and not h['busy'] and h['model']==model else None
try:
 wait_for(lambda:ready(BASE))
 catalog=state();check('catalog_pinned_revisions',len(catalog['data'])==4 and all(len(m['revision'])==40 for m in catalog['data']))
 status,_,_,_=client.request_raw('GET','/v1/node/models',auth=False)
 check('management_auth_required',status==401)
 check('unknown_model_rejected',expect_error('download',{'model':'unlisted/model'}))
 check('active_model_delete_rejected',expect_error('delete',{'model':BASE}))
 if next(m for m in catalog['data'] if m['id']==SMALL)['installed']:
  post('delete',{'model':SMALL})
 check('uninstalled_activation_rejected',expect_error('activate',{'model':SMALL}))
 post('download',{'model':SMALL});time.sleep(.25)
 downloading=state();check('real_device_download_started',downloading['downloading_model']==SMALL,{'phase':downloading['phase'],'progress':downloading['progress']})
 check('concurrent_download_rejected',expect_error('download',{'model':BASE}))
 check('activation_during_download_rejected',expect_error('activate',{'model':BASE}))
 post('cancel',{})
 cancelled=wait_for(lambda:(s if (s:=state())['downloading_model'] is None else None),120)
 check('download_cancelled_and_drained',not next(m for m in cancelled['data'] if m['id']==SMALL)['installed'],{'phase':cancelled['phase'],'message':cancelled['message']})
 response,_=client.request_json('POST','/v1/chat/completions',{'model':BASE,'messages':[{'role':'user','content':'Reply with: still ready'}],'max_tokens':16,'temperature':0})
 check('baseline_inference_after_cancel',bool(response['choices'][0]['message']['content']))
 if args.device_id:
  post('download',{'model':SMALL});time.sleep(.25)
  activate_app('com.apple.Preferences');time.sleep(1.2)
  activate_app(args.bundle_id)
  wait_for(lambda:ready(BASE))
  paused=wait_for(lambda:(s if (s:=state())['downloading_model'] is None else None),120)
  check('background_pauses_download',not next(m for m in paused['data'] if m['id']==SMALL)['installed'],{'phase':paused['phase']})
 started=time.monotonic();post('download',{'model':SMALL})
 last_log=0
 def downloaded():
  global last_log
  s=state()
  if time.monotonic()-last_log>5:
   print('download',s['phase'],round(s['progress'],3),flush=True);last_log=time.monotonic()
  if s['downloading_model'] is None:
   assert next(m for m in s['data'] if m['id']==SMALL)['installed'],s['message']
   return s
  return None
 installed=wait_for(downloaded,1200)
 check('download_retry_and_integrity_verified',True,{'seconds':time.monotonic()-started,'phase':installed['phase'],'model':next(m for m in installed['data'] if m['id']==SMALL)})
 post('activate',{'model':SMALL});h=wait_for(lambda:ready(SMALL),120)
 check('activate_downloaded_model',True,{'model':h['model'],'revision':h['model_revision'],'memory':h['memory']})
 models=client.request_json('GET','/v1/models')[0]
 check('api_reports_active_model',models['data'][0]['id']==SMALL and models['data'][0]['quantization_bits']==4)
 answer,_=client.request_json('POST','/v1/chat/completions',{'model':SMALL,'messages':[{'role':'user','content':'Reply briefly in Chinese: 你好'}],'max_tokens':32,'temperature':0})
 check('downloaded_model_generates_real_text',answer['model']==SMALL and bool(answer['choices'][0]['message']['content']) and answer['device_metrics']['token_counts_match'],answer)
 wrong=False
 try:client.request_json('POST','/v1/chat/completions',{'model':BASE,'messages':[{'role':'user','content':'Hello'}],'max_tokens':8})
 except api.APIError as e:wrong=e.status==400
 check('old_model_id_rejected_after_switch',wrong)
 if args.device_id:
  activate_app(args.bundle_id,restart=True)
  h=wait_for(lambda:ready(SMALL),120)
  restored=state()
  check('selection_and_download_survive_restart',h['model']==SMALL and restored['downloading_model'] is None)
 post('activate',{'model':BASE});h=wait_for(lambda:ready(BASE),120)
 check('switch_back_to_baseline',True,{'model':h['model'],'memory':h['memory']})
 if args.exercise_fallback:
  assert args.device_id, 'Fallback injection requires device access'
  import tempfile, urllib.request
  meta=next(m for m in state()['data'] if m['id']==SMALL)
  revision=meta['revision']
  raw=urllib.request.urlopen('https://huggingface.co/'+SMALL+'/resolve/'+revision+'/config.json',timeout=30).read()
  bad=raw.replace(b'"num_hidden_layers": 28',b'"num_hidden_layers": 99')
  assert bad!=raw and len(bad)==len(raw)
  destination='Library/Application Support/NodeModels/'+SMALL.replace('/','--')+'/'+revision+'/cache/models--'+SMALL.replace('/','--')+'/snapshots/'+revision+'/config.json'
  with tempfile.NamedTemporaryFile() as fixture:
   fixture.write(bad);fixture.flush()
   env=dict(os.environ,DEVELOPER_DIR=os.environ.get('DEVELOPER_DIR','/Applications/Xcode.app/Contents/Developer'))
   subprocess.run(['xcrun','devicectl','device','copy','to','--device',args.device_id,'--source',fixture.name,'--destination',destination,'--domain-type','appDataContainer','--domain-identifier',args.bundle_id],env=env,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=30)
  post('activate',{'model':SMALL})
  def fallback_restored():
   h=ready(BASE)
   if not h:return None
   m=state()
   return m if '已恢复上一模型' in m['message'] else None
  restored=wait_for(fallback_restored,120)
  check('failed_load_restores_previous_model',restored['active_model']==BASE,{'message':restored['message']})
 post('delete',{'model':SMALL});s=state()
 check('delete_inactive_model',not next(m for m in s['data'] if m['id']==SMALL)['installed'])
 report['passed']=True
except Exception as e:
 report['passed']=False;report['error']=client.safe(str(e));raise
finally:
 report['summary']={'passed':sum(c['passed'] for c in report['checks']),'total':len(report['checks'])}
 save()
