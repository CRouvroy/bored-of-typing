#!/usr/bin/env python3
"""Render the production SwiftUI overlay offscreen using synthetic geometry only.

No application launch, camera, clipboard, provider, or saved board data is used.
The overlay and aspect-fit implementation are extracted unchanged from source;
the geometry carrier replaces only BoardQuad's unrelated tracking dependencies.
"""
import pathlib
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
SDK = subprocess.check_output([str(ROOT / "scripts/macos-sdk")], text=True).strip()
OUTPUT = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/board-live-annotations.png").resolve()
camera_source = (ROOT / "Sources/BoardApp/BoardCameraViews.swift").read_text()
overlay = camera_source[camera_source.index("private struct LiveBoardAnnotationOverlay:"):]
calibration_source = (ROOT / "Sources/BoardApp/CalibrationCanvas.swift").read_text()
layout = calibration_source[calibration_source.index("enum BoardCameraLayout"):calibration_source.index("struct BoardCalibrationEditor")]
fixture = r'''
import SwiftUI
import AppKit
struct BoardQuad { let points: [CGPoint] }
'''+layout+overlay+r'''
struct Fixture: View {
    let corners: [CGPoint]
    let lost: Bool
    let title: String
    private var marks: [BoardAnnotation] { [
        BoardAnnotation(rect: CGRect(x: 0.12, y: 0.18, width: 0.46, height: 0.29), label: "Current Architecture"),
        BoardAnnotation(rect: CGRect(x: 0.62, y: 0.55, width: 0.29, height: 0.27), label: "Next experiment"),
        BoardAnnotation(rect: CGRect(x: 0.02, y: 0.015, width: 0.23, height: 0.08), label: "Top edge label")
    ] }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .medium)).foregroundStyle(BoardTheme.ink)
            ZStack {
                Color(nsColor: .darkGray)
                Canvas { context, size in
                    let imageRect = BoardCameraLayout.aspectFit(CGSize(width: 640, height: 360), in: size)
                    let map = BoardProjectiveMap(corners: corners)!
                    func point(_ p: CGPoint) -> CGPoint {
                        let q = map.imagePoint(p)!
                        return CGPoint(x: imageRect.minX + q.x * imageRect.width, y: imageRect.minY + q.y * imageRect.height)
                    }
                    var border = Path()
                    for (i,p) in [CGPoint(x:0,y:0),CGPoint(x:1,y:0),CGPoint(x:1,y:1),CGPoint(x:0,y:1)].enumerated() {
                        if i == 0 { border.move(to: point(p)) } else { border.addLine(to: point(p)) }
                    }
                    border.closeSubpath()
                    context.fill(border, with: .color(Color(white: 0.96)))
                    context.stroke(border, with: .color(.gray), lineWidth: 7)
                    for row in 1..<10 {
                        var line = Path(); line.move(to: point(CGPoint(x:0,y:Double(row)/10)))
                        line.addLine(to: point(CGPoint(x:1,y:Double(row)/10)))
                        context.stroke(line, with: .color(.blue.opacity(0.12)), lineWidth: 1)
                    }
                    for column in 1..<10 {
                        var line = Path(); line.move(to: point(CGPoint(x:Double(column)/10,y:0)))
                        line.addLine(to: point(CGPoint(x:Double(column)/10,y:1)))
                        context.stroke(line, with: .color(.blue.opacity(0.12)), lineWidth: 1)
                    }
                    for (text,p) in [("input → encoder",CGPoint(x:0.2,y:0.28)),("h = f(x)",CGPoint(x:0.2,y:0.38)),("A / B",CGPoint(x:0.7,y:0.67))] {
                        context.draw(Text(text).font(.system(size:15,design:.monospaced)).foregroundColor(.black), at:point(p),anchor:.topLeading)
                    }
                }
                LiveBoardAnnotationOverlay(annotations: marks, quad: BoardQuad(points: corners),
                    imageSize: CGSize(width:640,height:360), isEditing:false, isLost:lost, label:"", onMark:{_ in})
            }.frame(width:640,height:360).clipped()
        }
    }
}
@main struct RenderAnnotations {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        NSApp.appearance = NSAppearance(named:.aqua)
        let flat = [CGPoint(x:0.06,y:0.025),CGPoint(x:0.94,y:0.025),CGPoint(x:0.94,y:0.94),CGPoint(x:0.06,y:0.94)]
        let skew = [CGPoint(x:0.18,y:0.12),CGPoint(x:0.92,y:0.28),CGPoint(x:0.80,y:0.91),CGPoint(x:0.05,y:0.70)]
        let view = VStack(spacing:20) {
            Fixture(corners:flat,lost:false,title:"Tracked board · editing off, markings retained")
            Fixture(corners:skew,lost:false,title:"Camera moved · same board coordinates")
            Fixture(corners:skew,lost:true,title:"Tracking lost · stale markings shown red and dashed")
        }.padding(24).background(BoardTheme.paper).environment(\.colorScheme,.light)
        let renderer = ImageRenderer(content:view)
        renderer.scale = 1
        guard let image = renderer.cgImage else { fatalError("Native SwiftUI render failed") }
        let data = NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])!
        try data.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
        print("Rendered synthetic native overlay: \(image.width)×\(image.height)")
    }
}
'''
with tempfile.TemporaryDirectory(prefix="BoardAnnotationVisual-") as directory:
    work = pathlib.Path(directory)
    source, binary = work / "Visual.swift", work / "visual"
    source.write_text(fixture)
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-target", "arm64-apple-macosx26.0", "-sdk", SDK,
                    str(ROOT / "Sources/BoardApp/BoardLibrary.swift"), str(ROOT / "Sources/BoardApp/LiveBoardAnnotations.swift"),
                    str(ROOT / "Sources/BoardApp/BoardOverlays.swift"), str(ROOT / "Sources/BoardApp/BoardOverlayViews.swift"),
                    str(ROOT / "Sources/BoardApp/Theme.swift"),
                    str(ROOT / "Sources/BoardApp/BoardProximityDock.swift"),
                    str(ROOT / "Sources/BoardApp/BoardPointerMonitor.swift"),
                    str(ROOT / "Sources/BoardApp/BoardDockProximityRegion.swift"), str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary), str(OUTPUT)], check=True)
print(OUTPUT)
