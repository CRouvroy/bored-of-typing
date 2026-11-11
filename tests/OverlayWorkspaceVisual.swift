// Isolated offscreen fixture. Production controls/renderer are inserted unchanged.
import AppKit
import SwiftUI
import CoreImage
import Combine

enum BoardTrackingState { case off, tracking, lost }
struct FixtureCamera: Identifiable { let id: String; let name: String }
@MainActor final class CameraController: ObservableObject {
    @Published var isRunning=true
    @Published var isStarting=false
    @Published var isCalibrating=false
    @Published var selectedDeviceID="fixture"
    @Published var trackingState=BoardTrackingState.tracking
    @Published var centerStageEnabled=false
    let devices=[FixtureCamera(id:"fixture",name:"Synthetic camera")]
    var centerStageSupported=false, centerStageLocked=true, captureAllowed=true
    var trackedQuad: BoardQuad?
    init(_ quad: BoardQuad) { trackedQuad=quad }
    func start() { fatalError("No camera in fixture") }
    func stop() { fatalError("Inert fixture") }
    func clearCalibration() { fatalError("Inert fixture") }
    func setCenterStage(_ value: Bool) { fatalError("Inert fixture") }
    func refreshDevices() { fatalError("No camera enumeration") }
    func openCameraSettings() { fatalError("Inert fixture") }
}
@MainActor final class BoardModel: ObservableObject {
    @Published var isCapturing=false
    @Published var isLive=true
    @Published var isAnnotatingLive=false
    @Published var copyPulse=0
    @Published var preservePhysicalWriting=true
    var image:NSImage?=nil
    let displayedAnnotations:[BoardAnnotation]
    let canCopyRegion=true
    let library:BoardLibrary
    let overlays:BoardOverlayStore
    init(root:URL,annotations:[BoardAnnotation],overlays:[BoardOverlay]) throws {
        displayedAnnotations=annotations;library=BoardLibrary(rootURL:root);self.overlays=BoardOverlayStore(rootURL:root)
        for overlay in overlays { _=try self.overlays.upsert(overlay,expectedRevision:nil) }
    }
    func showLive() { fatalError("Inert fixture") }
    func beginBoardCalibration() { fatalError("Inert fixture") }
    func beginAnnotation() { fatalError("Inert fixture") }
    func copyBoard() { fatalError("No clipboard in fixture") }
    func copyFolderPath() { fatalError("No clipboard in fixture") }
    func copyRegion(_ id:UUID) { fatalError("No clipboard in fixture") }
    func importImage() { fatalError("Inert fixture") }
    func select(_ snapshot:BoardSnapshot) { fatalError("Inert fixture") }
    func setOverlayHidden(_ overlay:BoardOverlay,hidden:Bool) { fatalError("Inert fixture") }
    func setOverlayOpacity(_ overlay:BoardOverlay,opacity:Double) { fatalError("Inert fixture") }
}
// PRODUCTION FRAGMENTS
struct CopyChoiceFixture:View {
    @ObservedObject var model:BoardModel
    private var copyDisabled:Bool { false }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            // PRODUCTION COPY CHOICES
        }.buttonStyle(.plain).font(.system(size:14)).foregroundStyle(BoardTheme.ink)
            .padding(18).frame(width:280,alignment:.leading).background(BoardTheme.paper)
    }
}
struct WorkspaceFixture:View {
    @ObservedObject var model:BoardModel
    @ObservedObject var camera:CameraController
    let physical:NSImage
    let quad:BoardQuad
    let masks:[UUID:CGImage]
    let backdrop:[BoardOverlay]
    var pinned = false
    var body:some View {
        ZStack {
            ZStack {
                Image(nsImage:physical).resizable().interpolation(.high)
                if !backdrop.isEmpty {
                    BoardLiveOverlayLayer(overlays:backdrop,annotations:model.displayedAnnotations,quad:quad,imageSize:CGSize(width:960,height:600),foregroundMasks:masks)
                }
                BoardLiveOverlayLayer(overlays:model.overlays.overlays,annotations:model.displayedAnnotations,quad:quad,imageSize:CGSize(width:960,height:600),foregroundMasks:masks)
                BoardTrackedOutline(quad:quad,imageSize:CGSize(width:960,height:600))
                LiveBoardAnnotationOverlay(annotations:model.displayedAnnotations,quad:quad,imageSize:CGSize(width:960,height:600),isEditing:false,isLost:false,label:"",onMark:{_ in fatalError("Inert fixture")})
            }.frame(width:960,height:600).clipped()
            BoardProximityDock(edge:.trailing,expandedWidth:258,railHeight:52,expandedHeight:230,pinned:pinned,dismissal:0) { _ in
                VStack(spacing:0) {
                    HStack(spacing:8) {
                        Text("Board").font(.system(size:14,weight:.medium))
                        Spacer()
                        Image(systemName:"pin.fill").foregroundStyle(BoardTheme.orange).frame(width:28,height:30)
                        Image(systemName:"xmark").frame(width:28,height:30)
                    }.padding(.leading,14).padding(.trailing,8).frame(height:40)
                    BoardDockHatchRule(height:5)
                    BoardCameraControls(model:model,camera:camera).padding(10)
                    Spacer(minLength:0)
                }
            } rail: {
                Image(systemName:"slider.horizontal.3").font(.system(size:16)).frame(width:40,height:52)
            }
        }.frame(width:960,height:600).coordinateSpace(name:BoardDockCoordinateSpace.name)
            .foregroundStyle(BoardTheme.ink).background(BoardTheme.paper).environment(\.colorScheme,.light)
    }
}
@main struct RenderOverlayWorkspace {
    @MainActor static func main() throws {
        _=NSApplication.shared;NSApp.setActivationPolicy(.prohibited);NSApp.appearance=NSAppearance(named:.aqua)
        let output=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
        let dataRoot=FileManager.default.temporaryDirectory.appendingPathComponent("BoardOverlayVisual-\(UUID())")
        defer { try? FileManager.default.removeItem(at:dataRoot) }
        let regions=[BoardAnnotation(rect:CGRect(x:0.08,y:0.18,width:0.43,height:0.61),label:"Current Architecture"),
                     BoardAnnotation(rect:CGRect(x:0.58,y:0.18,width:0.34,height:0.61),label:"Next experiment"),
                     BoardAnnotation(rect:CGRect(x:0.08,y:0.85,width:0.24,height:0.1),label:"")]
        let text=BoardOverlay(regionID:regions[0].id,title:"Design note",opacity:1,text:"Compare both designs.\n\nKeep the cache boundary explicit.")
        let diagram=BoardOverlay(regionID:regions[1].id,title:"Experiment flow",opacity:1,kind:.diagram,
            nodes:[BoardOverlayNode(id:"a",x:0.15,y:0.08,width:0.7,height:0.25,label:"Measure"),BoardOverlayNode(id:"b",x:0.15,y:0.64,width:0.7,height:0.25,label:"Compare")],
            edges:[BoardOverlayEdge(from:"a",to:"b",label:"latency")])
        let model=try BoardModel(root:dataRoot,annotations:regions,overlays:[text,diagram])
        let quad=BoardQuad(points:[CGPoint(x:0.10,y:0.07),CGPoint(x:0.93,y:0.14),CGPoint(x:0.86,y:0.94),CGPoint(x:0.04,y:0.87)])
        let camera=CameraController(quad)
        let c=CGContext(data:nil,width:1000,height:600,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.setFillColor(NSColor(srgbRed:0.96,green:0.96,blue:0.94,alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:1000,height:600))
        c.setStrokeColor(NSColor.darkGray.cgColor);c.setLineWidth(10);c.stroke(CGRect(x:5,y:5,width:990,height:590))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:c,flipped:false)
        NSString(string:"new cache →").draw(in:CGRect(x:120,y:195,width:350,height:48),withAttributes:[.font:NSFont.systemFont(ofSize:36,weight:.medium),.foregroundColor:NSColor.systemBlue])
        NSString(string:"Research board").draw(at:CGPoint(x:80,y:530),withAttributes:[.font:NSFont.systemFont(ofSize:28,weight:.medium),.foregroundColor:NSColor.darkGray])
        NSString(string:"old path ↗").draw(at:CGPoint(x:600,y:300),withAttributes:[.font:NSFont.systemFont(ofSize:33),.foregroundColor:NSColor.darkGray])
        c.setStrokeColor(NSColor.systemBlue.cgColor);c.setLineWidth(4);c.move(to:CGPoint(x:620,y:220));c.addLine(to:CGPoint(x:900,y:380));c.strokePath()
        NSGraphicsContext.restoreGraphicsState()
        let points=quad.points.map { CIVector(x:$0.x*960,y:(1-$0.y)*600) }
        let warped=CIImage(cgImage:c.makeImage()!).applyingFilter("CIPerspectiveTransform",parameters:["inputTopLeft":points[0],"inputTopRight":points[1],"inputBottomRight":points[2],"inputBottomLeft":points[3]])
        let extent=CGRect(x:0,y:0,width:960,height:600), background=CIImage(color:CIColor(red:0.25,green:0.27,blue:0.29)).cropped(to:CGRect(x:0,y:0,width:960,height:600))
        let cg=CIContext().createCGImage(warped.composited(over:background).cropped(to:extent),from:extent)!
        let physical=NSImage(cgImage:cg,size:extent.size)
        var bytes=[UInt8](repeating:0,count:128*96)
        for y in 54..<84 { for x in 8..<118 { bytes[y*128+x]=255 } }
        let mask=CGImage(width:128,height:96,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceGray(),bitmapInfo:[],provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        func render<V:View>(_ view:V,name:String,expectedDock:CGRect?=nil) throws {
            var excluded: [CGRect] = []
            let hosting=NSHostingView(rootView:view.onPreferenceChange(BoardDockExclusionKey.self) { excluded = $0 })
            let size=hosting.fittingSize
            hosting.frame=CGRect(origin:.zero,size:size)
            let window=NSWindow(contentRect:CGRect(x:-10000,y:-10000,width:size.width,height:size.height),styleMask:.borderless,backing:.buffered,defer:false)
            window.contentView=hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until:Date(timeIntervalSinceNow:0.6))
            hosting.layoutSubtreeIfNeeded()
            if let expectedDock {
                guard excluded == [expectedDock] else { fatalError("Dock excluded \(excluded), expected \(expectedDock)") }
                guard hosting.bounds.size == CGSize(width:960,height:600) else { fatalError("Dock changed canvas size") }
            }
            guard let bitmap=hosting.bitmapImageRepForCachingDisplay(in:hosting.bounds) else { fatalError("Native hosting render failed") }
            hosting.cacheDisplay(in:hosting.bounds,to:bitmap)
            try bitmap.representation(using:.png,properties:[:])!.write(to:output.appendingPathComponent(name))
            print("Rendered \(name): \(bitmap.pixelsWide)×\(bitmap.pixelsHigh)")
            window.orderOut(nil)
        }
        try render(WorkspaceFixture(model:model,camera:camera,physical:physical,quad:quad,masks:[:],backdrop:[]),name:"workspace-unmasked.png",expectedDock:CGRect(x:912,y:238,width:40,height:52))
        try render(WorkspaceFixture(model:model,camera:camera,physical:physical,quad:quad,masks:[:],backdrop:[],pinned:true),name:"workspace-controls-open.png",expectedDock:CGRect(x:694,y:149,width:258,height:230))
        try render(WorkspaceFixture(model:model,camera:camera,physical:physical,quad:quad,masks:[text.id:mask],backdrop:[]),name:"workspace-writing-visible.png")
        let pale=BoardOverlay(regionID:regions[1].id,revision:1,opacity:1,text:"")
        try render(WorkspaceFixture(model:model,camera:camera,physical:physical,quad:quad,masks:[text.id:mask],backdrop:[pale]),name:"diagram-background-proposal.png")
        try render(CopyChoiceFixture(model:model).environment(\.colorScheme,.light),name:"copy-options-content.png")
        let labels=["Whole board"]+regions.enumerated().map { BoardRegionCopy.title(for:$0.element,index:$0.offset) }
        guard labels == ["Whole board","Current Architecture","Next experiment","Rectangle 3"] else { fatalError("Copy choices mismatch") }
        print("Copy choices verified: \(labels.joined(separator:" | "))")
    }
}
