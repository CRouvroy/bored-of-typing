#!/usr/bin/env python3
"""Render actual Board SwiftUI fragments with inert fixtures, never the camera/user app.
Expanded Copy choices render actual menu content in a VStack, not a native open menu.
"""
from pathlib import Path
import subprocess
import sys
ROOT=Path(__file__).resolve().parents[1]
SDK = subprocess.check_output([str(ROOT / "scripts/macos-sdk")], text=True).strip()
OUT=Path(sys.argv[1] if len(sys.argv)>1 else ROOT/'.build/overlay-visual-check').resolve()
OUT.mkdir(parents=True,exist_ok=True)
camera=(ROOT/'Sources/BoardApp/BoardCameraViews.swift').read_text()
controls=camera[camera.index('struct BoardCameraControls:'):camera.index('struct BoardLiveView:')]
annotations=camera[camera.index('private struct LiveBoardAnnotationOverlay:'):]
calibration=(ROOT/'Sources/BoardApp/CalibrationCanvas.swift').read_text()
layout=calibration[calibration.index('enum BoardCameraLayout'):calibration.index('struct BoardCalibrationEditor')]
outline=calibration[calibration.index('struct BoardTrackedOutline:'):]
menu=controls[controls.index('        Menu {',controls.index('private var copyMenu'))+len('        Menu {'):controls.index('        } label:',controls.index('private var copyMenu'))]
source=(ROOT/'tests/OverlayWorkspaceVisual.swift').read_text()
source=source.replace('// PRODUCTION FRAGMENTS',layout+outline+controls+annotations).replace('// PRODUCTION COPY CHOICES',menu)
path=OUT/'OverlayVisual.swift';path.write_text(source)
files=['BoardLibrary','BoardOverlays','BoardOverlayViews','LiveBoardAnnotations','BoardRegionCopy','Theme','Controls','BoardProximityDock','BoardPointerMonitor','BoardDockProximityRegion']
subprocess.run(['xcrun','swiftc','-swift-version','5','-target','arm64-apple-macosx26.0','-sdk',SDK,str(ROOT/'tests/BoardGeometryStub.swift')]+[str(ROOT/'Sources/BoardApp'/(name+'.swift')) for name in files]+[str(path),'-o',str(OUT/'visual')],check=True)
subprocess.run([str(OUT/'visual'),str(OUT)],check=True)
print(OUT)
