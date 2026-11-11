#!/usr/bin/env python3
"""Production BoardModel/library/overlay rendering; inert camera, clipboard and IPC."""
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = subprocess.check_output([str(ROOT / "scripts/macos-sdk")], text=True).strip()
source = (ROOT / "Sources/BoardApp/BoardApp.swift").read_text()
model = source[source.index("@MainActor\nfinal class BoardModel"):source.index("struct AnnotationCanvas: View")]
fixture = r'''
import SwiftUI
import AppKit
import Combine
import Darwin
enum BoardTrackingState { case off, tracking, lost }
@MainActor final class CameraController {
    var isRunning = true, isCalibrating = false
    var trackingState = BoardTrackingState.tracking
    var trackedQuad: BoardQuad? = BoardQuad(points: [CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1)])
    var captureAllowed = true
    var pending: ((Result<NSImage, Error>) -> Void)?
    func beginCalibration() { isCalibrating = true }
    func cancelCalibration() { isCalibrating = false }
    func capture(completion: @escaping (Result<NSImage, Error>) -> Void) { pending = completion }
}
@MainActor enum BoardClipboard {
    static var copied: [URL] = []
    static func copyImage(at url: URL) throws { copied.append(url) }
    static func copyFolder(_ url: URL) throws {}
}
@MainActor final class BoardCollaborationService {
    init(model: BoardModel) throws {}
}
'''+model+r'''
@main struct AnnotationModelChecks {
    @MainActor static func main() throws {
        var checks = 0
        func expect(_ ok: @autoclosure () -> Bool, _ message: String) {
            guard ok() else { fatalError(message) }; checks += 1
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("BoardModelChecks-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        setenv("BOARD_DATA_DIR",root.path,1)
        let model = BoardModel()
        model.beginAnnotation()
        model.annotationLabel = "At click"
        model.markLive(CGRect(x:0.1,y:0.2,width:0.3,height:0.4))
        let first = model.liveAnnotations.annotations
        expect(first.count == 1, "Live drawing should save without a capture")
        expect(model.camera.pending == nil && model.isLive, "Annotate must not freeze/capture")
        model.copyBoard()
        expect(model.isCapturing, "Copy should request the frame")
        model.annotationLabel = "Added after click"
        model.markLive(CGRect(x:0.5,y:0.2,width:0.2,height:0.2))
        let cg = CGContext(data:nil,width:400,height:300,bitsPerComponent:8,bytesPerRow:0,
                           space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(NSColor.white.cgColor);cg.fill(CGRect(x:0,y:0,width:400,height:300))
        let image = NSImage(cgImage:cg.makeImage()!,size:CGSize(width:400,height:300))
        model.camera.pending?(.success(image)); model.camera.pending = nil
        expect(model.library.snapshots.first?.annotations == first, "Copy must freeze annotations at click, before async capture")
        expect(model.liveAnnotations.annotations.count == 2, "Copy must preserve later live edits")
        expect(model.isLive && model.isAnnotatingLive && !model.isCapturing, "Copy must preserve live editing")
        expect(BoardClipboard.copied.count == 1 && model.copyPulse == 1, "Successful copy should report once")
        let wholeSnapshot = model.library.snapshots[0]
        let wholeExport = BoardClipboard.copied[0]
        let wholeBytes = try Data(contentsOf: wholeExport)
        model.beginAnnotation(); expect(!model.isAnnotatingLive && model.liveAnnotations.annotations.count == 2, "Finishing drawing must retain marks")
        model.beginAnnotation()

        model.copyRegion(first[0].id)
        expect(model.isCapturing, "Live region must request an exact verified capture")
        model.removeAnnotation(first[0].id)
        model.camera.pending?(.success(image)); model.camera.pending = nil
        let regionSnapshot = model.library.snapshots[0]
        let regionImage = BoardLibrary.cgImage(model.library.image(for: regionSnapshot)!)!
        expect(regionImage.width == 120 && regionImage.height == 120, "Region copy must freeze selected rectangle geometry")
        expect(regionSnapshot.title == "At click" && regionSnapshot.annotations.first?.label == "At click", "In-flight region must retain selected label after removal")
        expect(model.liveAnnotations.annotations.count == 1 && model.isLive && model.isAnnotatingLive, "Region copy must preserve later live edits and live view")
        expect(BoardClipboard.copied.count == 2 && model.copyPulse == 2, "Successful region copy should report once")
        model.errorMessage = nil
        model.copyRegion(first[0].id)
        expect(model.errorMessage != nil && model.camera.pending == nil && BoardClipboard.copied.count == 2, "Removed or unknown ID must never fall back to whole board")
        let remaining = model.liveAnnotations.annotations[0]
        model.camera.isRunning = false; model.errorMessage = nil
        model.copyRegion(remaining.id)
        expect(model.errorMessage != nil && model.camera.pending == nil, "Camera-off region copy must fail even if captureAllowed is stale")
        model.camera.isRunning = true; model.camera.trackingState = .lost; model.errorMessage = nil
        model.copyRegion(remaining.id)
        expect(model.errorMessage != nil && model.camera.pending == nil, "Lost tracking must block region copy")
        model.camera.trackingState = .off; model.errorMessage = nil
        model.copyRegion(remaining.id)
        expect(model.errorMessage != nil && model.camera.pending == nil, "Untracked camera must not treat board coordinates as full-frame coordinates")
        model.camera.trackingState = .tracking
        model.copyRegion(remaining.id)
        model.camera.pending?(.failure(NSError(domain:"Fixture",code:1,userInfo:[NSLocalizedDescriptionKey:"Exact frame lost"]))); model.camera.pending = nil
        expect(!model.isCapturing && model.errorMessage == "Exact frame lost" && BoardClipboard.copied.count == 2, "Capture validation failure must not copy a stale region")

        model.select(wholeSnapshot)
        model.camera.isRunning = false
        model.copyRegion(first[0].id)
        expect(!model.isLive && model.draft?.id == wholeSnapshot.id, "Saved-image region copy must preserve selected image")
        expect(model.library.snapshots.count == 3 && BoardClipboard.copied.count == 3, "Saved-image region must create exactly one version without camera")
        expect(try! Data(contentsOf:wholeExport) == wholeBytes, "Region copies must preserve earlier full-board exports")
        model.showLive(); model.camera.isRunning = true; model.beginAnnotation()

        // Exercise actual overlay storage, rasterization and mask provenance too.
        // Only camera/clipboard/IPC are doubled; pixels and saved metadata are real.
        let overlayRoot = root.appendingPathComponent("overlay-copies")
        setenv("BOARD_DATA_DIR",overlayRoot.path,1)
        let overlayModel = BoardModel()
        overlayModel.beginAnnotation(); overlayModel.annotationLabel = ""
        overlayModel.markLive(CGRect(x:0.1,y:0.1,width:0.8,height:0.8))
        let region = overlayModel.liveAnnotations.annotations[0]
        let overlay = try overlayModel.overlays.upsert(BoardOverlay(regionID:region.id,opacity:1,text:""),expectedRevision:nil)
        let maskPixels = [UInt8](repeating:170,count:128*96)
        let mask = CGImage(width:128,height:96,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:128,
            space:CGColorSpaceCreateDeviceGray(),bitmapInfo:[],provider:CGDataProvider(data:Data(maskPixels) as CFData)!,
            decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
        overlayModel.foregroundMasks = [overlay.id:mask]
        cg.setFillColor(NSColor.blue.cgColor); cg.fill(CGRect(x:0,y:0,width:400,height:300))
        let blueImage = NSImage(cgImage:cg.makeImage()!,size:CGSize(width:400,height:300))
        overlayModel.copyBoard()
        _ = try overlayModel.overlays.setHidden(id:overlay.id,hidden:true,expectedRevision:overlay.revision)
        overlayModel.foregroundMasks = [:]
        overlayModel.camera.pending?(.success(blueImage)); overlayModel.camera.pending = nil
        let overlaySnapshot = overlayModel.library.snapshots[0]
        expect(overlaySnapshot.overlays == [overlay], "Whole-board copy must freeze overlay revision at click")
        expect(overlaySnapshot.overlayMasks?.count == 1, "Whole-board copy must freeze uniform automatic-opacity mask at click")
        func pixel(_ value: NSImage, _ x:Int, _ y:Int) -> NSColor {
            NSBitmapImageRep(cgImage:BoardLibrary.cgImage(value)!).colorAt(x:x,y:y)!.usingColorSpace(.deviceRGB)!
        }
        let overlayOutput = NSImage(contentsOf:BoardClipboard.copied.last!)!
        let fadedRed = pixel(overlayOutput,120,90).redComponent
        expect(pixel(overlayOutput,120,90).blueComponent > 0.9 && fadedRed > 0.1 && fadedRed < 0.85,
            "Copied overlay must retain both physical image and translucent AI")
        expect(abs(pixel(overlayOutput,280,210).redComponent - fadedRed) < 0.02,
            "Copied overlay must have uniform opacity, not spatial holes")
        expect(pixel(overlayModel.library.image(for:overlaySnapshot)!,280,210).redComponent < 0.1,
            "Raw snapshot must not bake AI into the physical image")

        overlayModel.select(overlaySnapshot)
        overlayModel.camera.isRunning = false
        overlayModel.copyRegion(region.id)
        let savedOverlayRegion = overlayModel.library.snapshots[0]
        expect(savedOverlayRegion.overlays?.first?.id == overlay.id && savedOverlayRegion.overlays?.first?.regionID == savedOverlayRegion.annotations[0].id,
            "Saved-region copy must remap selected overlay to its new crop annotation")
        expect(savedOverlayRegion.overlayMasks == overlaySnapshot.overlayMasks, "Saved-region crop must preserve uniform automatic opacity")
        expect(BoardLibrary.cgImage(overlayModel.library.image(for:savedOverlayRegion)!)!.width == 320,
            "Saved overlay region must crop the original pixel geometry")
        expect(pixel(overlayModel.library.image(for:savedOverlayRegion)!,240,180).redComponent < 0.1,
            "Saved-region original must come from physical source, not composited display")
        let savedOverlayOutput = NSImage(contentsOf:BoardClipboard.copied.last!)!
        expect(pixel(savedOverlayOutput,80,60).blueComponent > 0.9 && abs(pixel(savedOverlayOutput,80,60).redComponent - fadedRed) < 0.02,
            "Saved-region export must retain automatic opacity")
        expect(abs(pixel(savedOverlayOutput,240,180).redComponent - fadedRed) < 0.02,
            "Saved-region export must retain the whole uniformly faded AI panel")

        overlayModel.showLive(); overlayModel.camera.isRunning = true
        let hiddenOverlay = overlayModel.overlays.overlays[0]
        let restoredOverlay = try overlayModel.overlays.setHidden(id:hiddenOverlay.id,hidden:false,expectedRevision:hiddenOverlay.revision)
        let visibleOverlay = try overlayModel.overlays.setOpacity(id:restoredOverlay.id,opacity:0.6,expectedRevision:restoredOverlay.revision)
        overlayModel.foregroundMasks = [overlay.id:mask]
        overlayModel.copyRegion(region.id)
        _ = try overlayModel.overlays.setHidden(id:visibleOverlay.id,hidden:true,expectedRevision:visibleOverlay.revision)
        overlayModel.foregroundMasks = [:]
        overlayModel.camera.pending?(.success(blueImage)); overlayModel.camera.pending = nil
        let liveOverlayRegion = overlayModel.library.snapshots[0]
        expect(liveOverlayRegion.overlays?.first?.revision == visibleOverlay.revision && liveOverlayRegion.overlays?.first?.hidden == false,
            "Live-region copy must freeze overlay revision before asynchronous capture")
        expect(liveOverlayRegion.overlayMasks?.count == 1 && liveOverlayRegion.overlays?.first?.regionID == liveOverlayRegion.annotations[0].id,
            "Live-region copy must preserve mask and remap overlay identity")
        expect(liveOverlayRegion.overlays?.first?.opacity == 0.6,
            "Automatic opacity must not overwrite the user's stored manual opacity")
        let liveOverlayOutput = NSImage(contentsOf:BoardClipboard.copied.last!)!
        expect(pixel(liveOverlayOutput,80,60).redComponent > 0.05 && pixel(liveOverlayOutput,80,60).redComponent < fadedRed,
            "Copy must multiply automatic attenuation by manual opacity")
        let justHidden = overlayModel.overlays.overlays[0]
        _ = try overlayModel.overlays.setHidden(id:justHidden.id,hidden:false,expectedRevision:justHidden.revision)
        overlayModel.preservePhysicalWriting = false
        overlayModel.foregroundMasks = [overlay.id:mask]
        overlayModel.copyRegion(region.id)
        overlayModel.camera.pending?(.success(blueImage)); overlayModel.camera.pending = nil
        let automaticOff = overlayModel.library.snapshots[0]
        expect(automaticOff.overlayMasks == nil && automaticOff.overlays?.first?.opacity == 0.6,
            "Disabling automatic transparency must copy only the manual opacity, without a stale mask")

        let currentFull = overlayModel.overlays.overlays.first { $0.id == overlay.id }!
        _ = try overlayModel.overlays.setHidden(id:currentFull.id,hidden:true,expectedRevision:currentFull.revision)
        let noteFrame = BoardOverlayFrame(x:0.15,y:0.2,width:0.4,height:0.25)
        let note = try overlayModel.overlays.upsert(BoardOverlay(regionID:region.id,opacity:1,text:"",frame:noteFrame),expectedRevision:nil)
        overlayModel.foregroundMasks = [:]
        overlayModel.copyBoard()
        var movedNote = note
        movedNote.frame = BoardOverlayFrame(x:0.55,y:0.6,width:0.3,height:0.25)
        movedNote = try overlayModel.overlays.upsert(movedNote,expectedRevision:note.revision)
        overlayModel.camera.pending?(.success(blueImage)); overlayModel.camera.pending = nil
        let placedWhole = overlayModel.library.snapshots[0]
        expect(placedWhole.overlays?.first { $0.id == note.id }?.frame == noteFrame,
            "Whole-board copy freezes small-note placement before asynchronous capture")
        let placedOutput = NSImage(contentsOf:BoardClipboard.copied.last!)!
        expect(pixel(placedOutput,150,110).redComponent > 0.9 && pixel(placedOutput,280,110).redComponent < 0.1,
            "Whole-board export draws a small note only within its frozen frame")
        expect(pixel(overlayModel.library.image(for:placedWhole)!,150,110).redComponent < 0.1,
            "Small-note copy retains an unmodified physical original")
        overlayModel.select(placedWhole); overlayModel.camera.isRunning = false
        overlayModel.copyRegion(region.id)
        let placedSavedCrop = overlayModel.library.snapshots[0]
        let croppedNote = placedSavedCrop.overlays!.first { $0.id == note.id }!
        expect(croppedNote.frame == noteFrame && croppedNote.regionID == placedSavedCrop.annotations[0].id,
            "Saved-region copy remaps only the parent ID and preserves note-local placement")
        let placedCropOutput = NSImage(contentsOf:BoardClipboard.copied.last!)!
        expect(pixel(placedCropOutput,100,75).redComponent > 0.9 && pixel(placedCropOutput,240,180).redComponent < 0.1,
            "Saved-region note stays at the same position relative to the cropped parent")
        overlayModel.showLive(); overlayModel.camera.isRunning = true
        overlayModel.copyRegion(region.id)
        overlayModel.camera.pending?(.success(blueImage)); overlayModel.camera.pending = nil
        let placedLiveCrop = overlayModel.library.snapshots[0]
        expect(placedLiveCrop.overlays?.first { $0.id == note.id }?.frame == movedNote.frame,
            "Live-region copy preserves current note-local placement after an explicit move")
        let copiesBeforeFailures = BoardClipboard.copied.count

        let external = Data("{\"schemaVersion\":99,\"annotations\":[]}".utf8)
        try external.write(to:model.liveAnnotations.fileURL)
        model.markLive(CGRect(x:0.2,y:0.3,width:0.2,height:0.2))
        expect(model.errorMessage != nil && !model.liveAnnotations.canWrite, "External change must surface save failure")
        model.errorMessage = nil
        model.markLive(CGRect(x:0.2,y:0.3,width:0.2,height:0.2))
        expect(model.errorMessage != nil, "Repeated read-only edit must not fail silently")
        expect(try! Data(contentsOf:model.liveAnnotations.fileURL) == external, "External data must remain intact")
        expect(model.liveAnnotations.annotations.count == 1, "Failed edits must not appear committed")

        let broken = root.appendingPathComponent("broken-library")
        try FileManager.default.createDirectory(at:broken,withIntermediateDirectories:true)
        try Data("invalid".utf8).write(to:broken.appendingPathComponent("library.json"))
        setenv("BOARD_DATA_DIR",broken.path,1)
        let readonly = BoardModel(); readonly.copyBoard()
        expect(readonly.errorMessage != nil && readonly.camera.pending == nil, "Read-only library must report instead of silently attempting capture")
        expect(BoardClipboard.copied.count == copiesBeforeFailures, "Failed capture must not claim clipboard success")
        print("PASS: \(checks) inert model annotation/copy/error checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="BoardAnnotationModel-") as directory:
    work = pathlib.Path(directory)
    swift, binary = work / "ModelChecks.swift", work / "checks"
    swift.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx26.0", "-sdk", SDK,
                    str(ROOT / "Sources/BoardApp/BoardLibrary.swift"), str(ROOT / "Sources/BoardApp/LiveBoardAnnotations.swift"),
                    str(ROOT / "Sources/BoardApp/BoardRegionCopy.swift"), str(ROOT / "Sources/BoardApp/BoardOverlays.swift"),
                    str(ROOT / "Sources/BoardApp/BoardOverlayViews.swift"), str(ROOT / "tests/BoardGeometryStub.swift"),
                    str(ROOT / "Sources/BoardApp/BoardMCPSetup.swift"),
                    str(swift), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
