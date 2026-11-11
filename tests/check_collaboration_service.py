"""Actual Swift mailbox service + actual Python MCP adapter, with a fixture-only camera.

Uses an isolated temporary library. No camera devices, assistant APIs, or user data.
Requires the native tracker object produced by scripts/test-tracking and Pillow.
"""
import base64
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import subprocess
import sys
import tempfile
import time
import uuid
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
SDK = subprocess.check_output([str(ROOT / "scripts/macos-sdk")], text=True).strip()
REGION = '00000000-0000-4000-8000-000000000001'
OVERLAY = '00000000-0000-4000-8000-000000000002'
STUB = r'''
import AppKit
import Foundation

@MainActor final class FixtureCamera {
    var isRunning = true
    var trackingState: BoardTrackingState = .tracking
    var trackedQuad: BoardQuad? = try! BoardQuad(points: [CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1)])
    var captureAllowed: Bool { isRunning && trackingState == .tracking }
    var onBoardSample: ((CGImage, UUID) -> Void)?
    var captures = 0
    var sampling = false
    var captureDelay = 0.0
    func setBoardSamplingEnabled(_ value: Bool) { sampling = value }
    func capture(completion: @escaping (Result<NSImage, Error>) -> Void) {
        captures += 1
        let context = CGContext(data:nil,width:640,height:480,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (color,x,y) in [(NSColor.red,0,240),(NSColor.green,320,240),(NSColor.blue,0,0),(NSColor.yellow,320,0)] {
            context.setFillColor(color.cgColor); context.fill(CGRect(x:x,y:y,width:320,height:240))
        }
        let image = NSImage(cgImage:context.makeImage()!,size:CGSize(width:640,height:480))
        if captureDelay > 0 { DispatchQueue.main.asyncAfter(deadline:.now()+captureDelay) { completion(.success(image)) } }
        else { completion(.success(image)) }
    }
}
@MainActor final class BoardModel {
    let library: BoardLibrary
    let liveAnnotations: LiveBoardAnnotationStore
    let overlays: BoardOverlayStore
    let camera = FixtureCamera()
    var isLive = true
    var preservePhysicalWriting = true
    var foregroundMasks: [UUID:CGImage] = [:]
    var isCapturing = false
    var errorMessage: String?
    init(root: URL) {
        library=BoardLibrary(rootURL:root); liveAnnotations=LiveBoardAnnotationStore(rootURL:root); overlays=BoardOverlayStore(rootURL:root)
        _=liveAnnotations.replace([BoardAnnotation(id:UUID(uuidString:"00000000-0000-4000-8000-000000000001")!,rect:CGRect(x:0.25,y:0.25,width:0.5,height:0.5),label:"Fixture region")])
    }
}
@main struct FixtureService {
    @MainActor static func main() throws {
        let root=URL(fileURLWithPath:CommandLine.arguments[1]), model=BoardModel(root:root)
        let service=try BoardCollaborationService(model:model)
        var lastSampleToken = "", sampleEpoch = UUID(), metadataPrepared = false
        let controls=Timer(timeInterval:0.05,repeats:true) { _ in Task { @MainActor in
            if let data=try? Data(contentsOf:root.appendingPathComponent("control.json")),let value=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any] {
                if let running=value["cameraOn"] as? Bool { model.camera.isRunning=running }
                if let state=value["tracking"] as? String,let parsed=BoardTrackingState(rawValue:state) { model.camera.trackingState=parsed }
                if let delay=value["captureDelay"] as? Double { model.camera.captureDelay=delay }
                if let live=value["isLive"] as? Bool { model.isLive=live }
                if let automatic=value["automatic"] as? Bool { model.preservePhysicalWriting=automatic }
                if let token=value["sampleToken"] as? String, token != lastSampleToken, model.camera.sampling {
                    lastSampleToken=token
                    if let raw=value["epoch"] as? String,let epoch=UUID(uuidString:raw) { sampleEpoch=epoch }
                    let context=CGContext(data:nil,width:640,height:480,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.setFillColor(NSColor.white.cgColor);context.fill(CGRect(x:0,y:0,width:640,height:480))
                    if value["sampleInk"] as? Bool == true {
                        context.setFillColor(NSColor.black.cgColor);context.fill(CGRect(x:230,y:260,width:18,height:40))
                    }
                    if value["sampleOccluder"] as? Bool == true {
                        context.setFillColor(NSColor.darkGray.cgColor);context.fill(CGRect(x:180,y:150,width:130,height:180))
                    }
                    if value["sampleLowerRight"] as? Bool == true {
                        context.setFillColor(NSColor.black.cgColor);context.fill(CGRect(x:380,y:150,width:18,height:25))
                    }
                    model.camera.onBoardSample?(context.makeImage()!,sampleEpoch)
                }
                if value["metadataBounds"] as? Bool == true, !metadataPrepared {
                    metadataPrepared=true
                    let label=String(repeating:"🧪",count:160)
                    let first=model.liveAnnotations.annotations[0]
                    let regions=(0..<110).map { i in BoardAnnotation(id:i == 0 ? first.id : UUID(),rect:first.rect,label:label) }
                    _=model.liveAnnotations.replace(regions)
                    for _ in model.overlays.overlays.count..<60 {
                        _=try? model.overlays.upsert(BoardOverlay(regionID:first.id,title:String(repeating:"🧪",count:120)),expectedRevision:nil)
                    }
                }
            }
            var maskRanges:[String:[Int]] = [:]
            for (id,mask) in model.foregroundMasks {
                if let data=mask.dataProvider?.data, let bytes=CFDataGetBytePtr(data) {
                    var low=255,high=0;for i in 0..<CFDataGetLength(data) { low=min(low,Int(bytes[i]));high=max(high,Int(bytes[i])) }
                    maskRanges[id.uuidString]=[low,high]
                }
            }
            let value:[String:Any] = ["captures":model.camera.captures,"sampling":model.camera.sampling,"masks":model.foregroundMasks.count,"maskRanges":maskRanges]
            if let data=try? JSONSerialization.data(withJSONObject:value) { try? data.write(to:root.appendingPathComponent("metrics.json"),options:.atomic) }
        } }
        RunLoop.main.add(controls,forMode:.common)
        print("READY"); fflush(stdout)
        withExtendedLifetime((model,service,controls)) { RunLoop.main.run() }
    }
}
'''


def line(process, timeout=20):
    if not select.select([process.stdout], [], [], timeout)[0]:
        raise RuntimeError('Timed out waiting for fixture process')
    value = process.stdout.readline()
    if not value:
        raise RuntimeError('Fixture process exited: ' + process.stderr.read())
    return value


def main():
    failures = []
    passed = 0
    def check(value, label):
        nonlocal passed
        if value: passed += 1
        else: failures.append(label); print('FAIL:', label, flush=True)
    with tempfile.TemporaryDirectory(prefix='board-native-ipc-') as temporary:
        folder = Path(temporary); stub = folder / 'FixtureService.swift'; stub.write_text(STUB)
        binary = folder / 'fixture-service'
        runtime = ROOT / '.build/OpenCVRuntime'
        native = ROOT / '.build/tracking-test-runner'
        sources = ['BoardLibrary.swift', 'LiveBoardAnnotations.swift', 'BoardTracking.swift', 'BoardOverlays.swift',
                   'BoardOverlayViews.swift', 'BoardInkChange.swift', 'BoardCollaboration.swift']
        command = ['xcrun','swiftc','-O','-swift-version','5','-target','arm64-apple-macosx26.0',
            '-sdk',SDK,'-I',str(native/'BoardNativeTracker'),
            *[str(ROOT/'Sources/BoardApp'/name) for name in sources],str(stub),str(native/'BoardNativeTracker.o'),
            '-L',str(runtime/'lib'),'-lopencv_calib3d','-lopencv_features2d','-lopencv_flann','-lopencv_imgproc','-lopencv_core','-lc++',
            '-Xlinker','-rpath','-Xlinker',str(runtime/'lib'),'-o',str(binary)]
        subprocess.run(command,check=True,cwd=ROOT)
        service = subprocess.Popen([str(binary),str(folder)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        adapter = None
        try:
            check(line(service).strip() == 'READY','real Swift service starts')
            environment = dict(os.environ,BOARD_DATA_DIR=str(folder))
            adapter = subprocess.Popen([sys.executable,str(ROOT/'scripts/board-mcp.py'),'mcp'],env=environment,
                stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
            next_id = 0
            def rpc(method, params=None):
                nonlocal next_id
                next_id += 1
                adapter.stdin.write(json.dumps({'jsonrpc':'2.0','id':next_id,'method':method,'params':params or {}})+'\n'); adapter.stdin.flush()
                response = json.loads(line(adapter))
                check(response.get('id') == next_id,'MCP response ID')
                return response.get('result',response)
            def call(name, arguments=None): return rpc('tools/call',{'name':name,'arguments':arguments or {}})
            def payload(result): return json.loads(result['content'][0]['text'])
            def photo(result): return Image.open(io.BytesIO(base64.b64decode(result['content'][1]['data']))).convert('RGB')
            def control(value):
                path=folder/'control.tmp';path.write_text(json.dumps(value));path.replace(folder/'control.json');time.sleep(.35)
            def metrics():
                return json.loads((folder/'metrics.json').read_text())
            check(rpc('initialize',{'protocolVersion':'2025-06-18'})['protocolVersion']=='2025-06-18','MCP initialization')
            check(len(rpc('tools/list')['tools'])==5,'five bounded tools exposed')
            status=call('board_status'); initial=payload(status)
            check(initial.get('automaticTransparency') is True and initial.get('overlayVisibilityPolicy')=='temporary-uniform-opacity','status exposes the actual automatic-opacity policy')
            check(initial.get('capabilities',{}).get('overlayFrame')=='normalized-top-left-in-region' and
                  initial.get('capabilities',{}).get('overlayKinds')==['text','diagram'],'status advertises bounded text/diagram placement coordinates')
            check([v['type'] for v in status['content']]==['text'] and metrics()['captures']==0,'status does not capture/load camera image')
            unchanged=payload(call('board_status',{'since_revision':initial['revision'],'instance_id':initial['instanceID']}))
            check(unchanged.get('unchanged') is True,'unchanged revision omits region/overlay lists')
            overlay={'id':OVERLAY,'regionID':REGION,'kind':'text','title':'Fixture overlay','text':'','opacity':1}
            created=call('board_put_overlay',{'overlay':overlay}); check(not created.get('isError') and payload(created)['overlay']['revision']==1,'real native create')
            edited=call('board_set_overlay',{'overlay_id':OVERLAY,'expected_revision':1,'opacity':1,'hidden':False})
            check(not edited.get('isError') and payload(edited)['overlay']['revision']==2,'combined CAS increments once')
            conflict=call('board_set_overlay',{'overlay_id':OVERLAY,'expected_revision':1,'hidden':True})
            check(conflict.get('isError') is True,'stale CAS rejected by real native store')
            raw=call('board_read_region',{'region_id':REGION}); image=photo(raw)
            check(image.size==(320,240),'native exact marked crop dimensions')
            check(image.getpixel((40,30))[0]>240 and image.getpixel((280,30))[1]>240 and image.getpixel((40,210))[2]>240,'native crop preserves all top-left oriented quadrants')
            before=metrics()['captures'];control({'cameraOn':False})
            off=call('board_read_region',{'region_id':REGION})
            check(off.get('isError') is True and metrics()['captures']==before,'camera OFF refuses image without starting capture')
            control({'cameraOn':True,'tracking':'lost'})
            lost=call('board_read_region',{'region_id':REGION})
            check(lost.get('isError') is True and metrics()['captures']==before,'lost tracking refuses image without stale capture')
            control({'tracking':'tracking'})
            request_id=str(uuid.uuid4()).upper();request=folder/'collaboration/requests'/f'{request_id}.json';response=folder/'collaboration/responses'/f'{request_id}.json'
            envelope={'schemaVersion':1,'id':request_id,'createdAt':time.time(),'method':'board_set_overlay','arguments':{'overlay_id':OVERLAY,'expected_revision':2,'opacity':.8}}
            request.write_text(json.dumps(envelope))
            for _ in range(100):
                if response.exists():break
                time.sleep(.02)
            original=response.read_bytes();response.unlink();request.write_text(json.dumps(envelope))
            for _ in range(100):
                if response.exists():break
                time.sleep(.02)
            check(response.read_bytes()==original,'duplicate IPC request ID returns original response')
            full=payload(call('board_list_overlays',{'overlay_id':OVERLAY}))['overlay']
            check(full['revision']==3 and full['opacity']==.8,'duplicate request does not apply mutation twice')
            check(full.get('frame') is None,'legacy overlay without a frame retains full-region semantics')
            specification=importlib.util.spec_from_file_location('board_mcp',ROOT/'scripts/board-mcp.py');module=importlib.util.module_from_spec(specification);specification.loader.exec_module(module)
            uncertain=module.BoardIPC(folder,timeout=.001,poll=.001)
            new_id=str(uuid.uuid4()).upper()
            try:
                uncertain.call('board_put_overlay',{'overlay':dict(overlay,id=new_id)})
                check(False,'timeout must report uncertain mutation')
            except ValueError as error: check('may already have happened' in str(error) and 'not retried' in str(error),'timeout reports uncertainty without retry')
            time.sleep(.3)
            persisted=json.loads((folder/'overlays.json').read_text())['overlays']
            check(sum(o['id']==new_id for o in persisted)<=1,'timeout never duplicates overlay creation')
            def sample(ink=False, **extra):
                control(dict(sampleToken=str(uuid.uuid4()),sampleInk=ink,**extra))
            def mask_range(): return metrics().get('maskRanges',{}).get(OVERLAY,[0,0])
            def quiet(ink=False, occluder=False):
                # Keep realistic fresh samples flowing while the temporal hold expires.
                end=time.monotonic()+3.6
                while time.monotonic()<end: sample(ink,sampleOccluder=occluder)
            current=payload(call('board_list_overlays',{'overlay_id':OVERLAY}))['overlay']
            current=payload(call('board_put_overlay',{'overlay':overlay,'expected_revision':current['revision']}))['overlay']
            sample(False)
            check(mask_range()==[0,0],'new overlay starts completely opaque')
            sample(True)
            low,high=mask_range()
            check(low==high and 0<low<255,'motion uniformly fades whole overlay and never cuts spatial holes')
            faded=call('board_read_region',{'region_id':REGION,'include_overlays':True}); image=photo(faded)
            physical=[image.getpixel((40,30))[1],image.getpixel((280,30))[0],image.getpixel((40,210))[0],image.getpixel((280,210))[2]]
            check(min(physical)>30 and max(physical)<230,'include_overlays retains translucent AI in all four quadrants')
            check(max(physical)-min(physical)<10,'include_overlays applies one opacity to the entire region')
            current=payload(call('board_set_overlay',{'overlay_id':OVERLAY,'expected_revision':current['revision'],'opacity':.5}))['overlay']
            sample(True)
            check(mask_range()[0]==mask_range()[1],'manual opacity edits cannot reintroduce spatial holes')
            quiet(True)
            check(mask_range()==[0,0],'new physical ink that stays still cannot leave permanent holes or fading')
            stored=payload(call('board_list_overlays',{'overlay_id':OVERLAY}))['overlay']
            check(stored['opacity']==.5 and stored['revision']==current['revision'],'automatic fading does not mutate manual opacity or CAS revision')
            sample(False)
            check(mask_range()[0]>0,'a new visual intervention reactivates temporary transparency')
            current=payload(call('board_set_overlay',{'overlay_id':OVERLAY,'expected_revision':current['revision'],'hidden':True}))['overlay']
            sample(False)
            check(mask_range()==[0,0],'hidden overlays discard temporary activity state')
            current=payload(call('board_set_overlay',{'overlay_id':OVERLAY,'expected_revision':current['revision'],'hidden':False}))['overlay']
            sample(False)
            check(mask_range()==[0,0],'showing a hidden overlay begins intact')
            sample(True);sample(True,epoch=str(uuid.uuid4()))
            check(mask_range()==[0,0],'new tracking epoch clears uncertain activity instead of preserving holes')
            sample(False);control({'isLive':False})
            check(metrics()['masks']==0,'leaving live view clears transient automatic opacity')
            control({'isLive':True});sample(True)
            check(mask_range()==[0,0],'returning to live view begins with an intact overlay')
            sample(False);control({'automatic':False})
            check(metrics()['masks']==0 and not metrics()['sampling'],'disabling automatic transparency clears state and stops samples')
            control({'automatic':True});sample(False,sampleOccluder=True,epoch=str(uuid.uuid4()))
            check(mask_range()==[0,0],'person present in the new baseline leaves the entire overlay visible')
            sample(False,sampleOccluder=False)
            check(mask_range()[0]==mask_range()[1] and mask_range()[0]>0,'person departure produces only uniform temporary transparency')
            quiet(False)
            check(mask_range()==[0,0],'departed person cannot leave a silhouette or permanent hole')
            sample(True)
            current=payload(call('board_put_overlay',{'overlay':dict(overlay,text='Refreshed content'),'expected_revision':current['revision']}))['overlay']
            time.sleep(.1);check(mask_range()==[0,0],'explicit replacement withdraws the previous automatic opacity immediately')
            sample(True);sample(True)
            check(mask_range()==[0,0],'refreshed content accepts stable existing writing without fading')
            sample(False)
            check(mask_range()[0]>0,'activity is present before camera-stop regression check')
            control({'cameraOn':False})
            check(metrics()['masks']==0 and not metrics()['sampling'],'camera OFF clears temporary opacity rather than freezing faded content')
            control({'cameraOn':True});sample(True)
            check(mask_range()==[0,0],'camera restart reanchors instead of resurrecting old activity')
            sample(False);control({});time.sleep(2)
            check(metrics()['masks']==0,'a stalled sample stream cannot leave a permanently faded overlay')
            sample(False)
            check(mask_range()==[0,0],'first sample after a stall starts from an intact overlay')
            sample(True);control({'tracking':'lost'})
            check(metrics()['masks']==0 and not metrics()['sampling'],'tracking loss clears uncertain automatic opacity')
            control({'tracking':'tracking'});sample(True)
            check(mask_range()==[0,0],'tracking recovery starts opaque rather than resurrecting activity')

            # Independent compact notes must preserve their placement end-to-end,
            # without obscuring all of the parent rectangle or moving other notes.
            summaries=payload(call('board_list_overlays'))['overlays']
            for value in summaries:
                if not value['hidden']:
                    call('board_set_overlay',{'overlay_id':value['id'],'expected_revision':value['revision'],'hidden':True})
            small_id=str(uuid.uuid4()).upper(); second_id=str(uuid.uuid4()).upper()
            small_frame={'x':.05,'y':.05,'width':.35,'height':.25}
            second_frame={'x':.6,'y':.65,'width':.3,'height':.25}
            small=dict(overlay,id=small_id,title='LIKE answer',text='LIKE uses a pattern.',frame=small_frame)
            second=dict(overlay,id=second_id,title='Small diagram',kind='diagram',text='',frame=second_frame,
                        nodes=[{'id':'a','label':'A','x':.1,'y':.25,'width':.3,'height':.5},
                               {'id':'b','label':'B','x':.6,'y':.25,'width':.3,'height':.5}],edges=[{'from':'a','to':'b'}])
            placed=payload(call('board_put_overlay',{'overlay':small}))['overlay']
            other=payload(call('board_put_overlay',{'overlay':second}))['overlay']
            check(placed.get('frame')==small_frame and other.get('frame')==second_frame,'MCP creation summaries retain exact parent-relative frames')
            full_small=payload(call('board_list_overlays',{'overlay_id':small_id}))['overlay']
            check(full_small['frame']==small_frame and full_small['text']==small['text'],'native storage round-trips placed text payload')
            image=photo(call('board_read_region',{'region_id':REGION,'include_overlays':True}))
            check(any(min(image.getpixel(point))>220 for point in [(23,64),(26,64),(120,64),(120,20)]),'small text background appears at its top-left placement')
            check(image.getpixel((280,30))[1]>240 and image.getpixel((280,30))[0]<20,'small notes leave unrelated parent-region pixels untouched')
            check(min(image.getpixel((240,211)))>220,'a separate diagram retains its independent lower-right placement')
            moved_frame={'x':.08,'y':.45,'width':.35,'height':.2}
            moved=payload(call('board_put_overlay',{'overlay':dict(small,frame=moved_frame),'expected_revision':placed['revision']}))['overlay']
            check(moved['revision']==placed['revision']+1 and moved.get('frame')==moved_frame,'CAS can move one small note without changing its parent region')
            stale=call('board_put_overlay',{'overlay':small,'expected_revision':placed['revision']})
            check(stale.get('isError') is True,'stale placed-note replacement is rejected')
            other_full=payload(call('board_list_overlays',{'overlay_id':second_id}))['overlay']
            check(other_full['frame']==second_frame and other_full['revision']==other['revision'],'moving one note preserves the neighboring diagram exactly')
            # Bypass only Python validation to confirm native defense of the
            # normalized frame contract; this remains an isolated test mailbox.
            invalid_id=str(uuid.uuid4()).upper()
            invalid_request=folder/'collaboration/requests'/f'{invalid_id}.json'
            invalid_response=folder/'collaboration/responses'/f'{invalid_id}.json'
            bad=dict(small,frame={'x':.9,'y':0,'width':.2,'height':.2})
            invalid_request.write_text(json.dumps({'schemaVersion':1,'id':invalid_id,'createdAt':time.time(),
                'method':'board_put_overlay','arguments':{'overlay':bad,'expected_revision':moved['revision']}}))
            for _ in range(100):
                if invalid_response.exists():break
                time.sleep(.02)
            rejected=json.loads(invalid_response.read_text())
            check('error' in rejected,'native service rejects a frame extending outside its parent')
            preserved=payload(call('board_list_overlays',{'overlay_id':small_id}))['overlay']
            check(preserved['frame']==moved_frame and preserved['revision']==moved['revision'],'native invalid placement preserves the preceding exact note revision')
            sample(False,epoch=str(uuid.uuid4()))
            sample(True)
            check(metrics().get('maskRanges',{}).get(second_id,[0,0])==[0,0],'motion elsewhere in the parent region does not fade a small distant diagram')
            sample(True,sampleLowerRight=True)
            second_motion=metrics().get('maskRanges',{}).get(second_id,[0,0])
            check(second_motion[0]==second_motion[1] and second_motion[0]>0,'motion inside the placed diagram triggers uniform transparency for that diagram')
            repositioned=payload(call('board_put_overlay',{'overlay':dict(second,frame={'x':.6,'y':.05,'width':.3,'height':.25}),
                                     'expected_revision':other['revision']}))['overlay']
            time.sleep(.1)
            check(metrics().get('maskRanges',{}).get(second_id,[0,0])==[0,0],'moving an active small diagram immediately clears its prior activity')
            sample(True,sampleLowerRight=True)
            check(metrics().get('maskRanges',{}).get(second_id,[0,0])==[0,0] and repositioned['revision']==other['revision']+1,
                  'moved diagram establishes a fresh placement baseline without inheriting its previous motion')
            captures=metrics()['captures'];control({'metadataBounds':True})
            large=call('board_status');metadata=payload(large)
            check(len(metadata['regions'])==100 and metadata['regionsTruncated'] and len(metadata['overlays'])==60,'bounded status handles maximum overlays and excess regions')
            check(all(len(r['label'].encode('utf-8'))<=160 for r in metadata['regions']) and all(len(o['title'].encode('utf-8'))<=120 for o in metadata['overlays']),'metadata limits count UTF-8 bytes')
            check(len(large['content'][0]['text'].encode('utf-8'))<65536 and metrics()['captures']==captures,'bounded metadata remains compact and does not capture')
        finally:
            for process in (adapter,service):
                if process:
                    process.terminate()
                    try: process.wait(timeout=3)
                    except subprocess.TimeoutExpired: process.kill();process.wait()
        print(f'{passed} checks passed; {len(failures)} failures. Actual native service/stdio adapter, fixture camera only.')
        if failures: raise SystemExit(1)


if __name__=='__main__': main()
