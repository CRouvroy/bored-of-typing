import AppKit
import AVFoundation
import Combine
import CoreImage
import OSLog
import SwiftUI

struct CameraOption: Identifiable, Hashable {
    let id: String
    let name: String
}

/// Display continuity is independent of permission to rectify or capture a board.
/// A lost tracker keeps the last accepted boundary for a clearly marked stale outline.
struct BoardTrackingPresentation {
    private(set) var state: BoardTrackingState = .off
    private(set) var trackedQuad: BoardQuad?
    private(set) var displayQuad: BoardQuad?

    mutating func apply(_ update: BoardTrackingUpdate) {
        switch update.state {
        case .off:
            reset()
        case .tracking:
            guard let quad = update.quad else {
                state = .lost
                trackedQuad = nil
                return
            }
            state = .tracking
            trackedQuad = quad
            displayQuad = quad
        case .lost:
            state = .lost
            trackedQuad = nil
        }
    }

    mutating func reset() {
        state = .off
        trackedQuad = nil
        displayQuad = nil
    }

    var permitsCapture: Bool { state == .off || (state == .tracking && trackedQuad?.isFullyVisible == true) }
}

/// A rejected frame is different from a camera/calibration boundary. The former may
/// retry the retained board anchor; the latter must never resume an old calibration.
struct BoardTrackingRecoveryGate {
    private(set) var isLost = false
    private(set) var hardInvalid = false
    var mayProcess: Bool { !hardInvalid }

    mutating func reset() { isLost = false; hardInvalid = false }

    @discardableResult
    mutating func lose(allowRecovery: Bool, canRecover: Bool) -> Bool {
        let changed = !isLost
        isLost = true
        hardInvalid = hardInvalid || !(allowRecovery && canRecover)
        return changed
    }

    /// Returns true only for a transition from temporary loss to a fresh valid result.
    @discardableResult
    mutating func acceptTracking() -> Bool {
        guard !hardInvalid else { return false }
        let recovered = isLost
        isLost = false
        return recovered
    }
}

/// Only these fixed codes enter unified logs; Vision error descriptions and pixels do not.
enum BoardTrackingLossReason: String {
    case centerStageChanged = "center_stage_changed"
    case sessionInterrupted = "session_interrupted"
    case staleFrame = "stale_frame"
    case resolutionChanged = "resolution_changed"
    case exactFrameUnavailable = "exact_frame_unavailable"
    case visionConfidenceCorners = "vision_confidence_corners"
    case geometryRejected = "geometry_rejected"
    case appearanceUnavailable = "appearance_unavailable"
    case appearanceMismatch = "appearance_mismatch"
    case frameContinuity = "frame_continuity"
    case homographyRejected = "homography_rejected"
    case patchConsensus = "patch_consensus"
    case featureSupport = "feature_support"
    case visionError = "vision_error"

    static func fromCore(_ rejection: String?) -> BoardTrackingLossReason {
        guard let reason = rejection?.lowercased() else { return .visionError }
        if reason.hasPrefix("vision confidence/corners") { return .visionConfidenceCorners }
        if reason.hasPrefix("geometry") { return .geometryRejected }
        if reason.hasPrefix("appearance unavailable") { return .appearanceUnavailable }
        if reason.hasPrefix("appearance") { return .appearanceMismatch }
        if reason.hasPrefix("frame continuity") { return .frameContinuity }
        if reason.hasPrefix("homography") { return .homographyRejected }
        if reason.hasPrefix("patch_consensus") { return .patchConsensus }
        if reason.hasPrefix("features") { return .featureSupport }
        return .visionError
    }
}

private enum BoardCameraError: LocalizedError {
    case unavailable, configuration, noFrame, stopped, calibrating, trackingLost, noCalibrationFrame, calibrationTimeout, boardOutsideFrame
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected camera is disconnected. Choose a camera and turn it on."
        case .configuration: return "This camera could not provide a video image. Try another camera."
        case .noFrame: return "The camera has not delivered a fresh frame yet. Wait a moment and capture again."
        case .stopped: return "Turn the camera on before capturing."
        case .calibrating: return "Finish or cancel board calibration before capturing."
        case .trackingLost: return "The board is not ready to copy. Keep it in view and wait for a valid outline, or recalibrate."
        case .noCalibrationFrame: return "The calibration image is no longer available. Start calibration again."
        case .calibrationTimeout: return "The camera framing did not settle. Check that Center Stage is off, then calibrate again."
        case .boardOutsideFrame: return "The board is partly outside the camera frame. Move the camera to include all four corners before copying."
        }
    }
}

/// Camera frames stay in memory. Only an explicit capture returns an image to the library.
@MainActor
final class CameraController: ObservableObject {
    @Published private(set) var devices: [CameraOption] = []
    @Published var selectedDeviceID: String {
        didSet {
            guard oldValue != selectedDeviceID else { return }
            invalidateCalibration()
            frameSize = .zero
            UserDefaults.standard.set(selectedDeviceID, forKey: "board.cameraID")
            refreshCenterStage()
            if wantsRunning { configureAndStart() }
        }
    }
    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var status = "Camera off"
    @Published private(set) var centerStageSupported = false
    @Published private(set) var centerStageEnabled = false
    @Published private(set) var centerStageActive = false
    @Published private(set) var calibrationImage: NSImage?
    @Published private(set) var trackingState: BoardTrackingState = .off
    @Published private(set) var trackedQuad: BoardQuad?
    @Published private(set) var displayQuad: BoardQuad?
    @Published private(set) var frameSize: CGSize = .zero
    @Published private(set) var isCalibrating = false
    @Published var calibrationError: String?

    var captureAllowed: Bool { isRunning && !isCalibrating && trackingPresentation.permitsCapture }
    var centerStageLocked: Bool { isCalibrating || trackingState != .off }

    let session: AVCaptureSession
    /// Reduced, verified board samples for local overlay change detection only.
    var onBoardSample: ((CGImage, UUID) -> Void)?
    func setBoardSamplingEnabled(_ enabled: Bool) { worker.setBoardSamplingEnabled(enabled) }
    private let worker: BoardCameraWorker
    private var captureDevices: [AVCaptureDevice] = []
    private var wantsRunning = false
    private var generation = UUID()
    private var notifications: [NSObjectProtocol] = []
    private var effectsTimer: Timer?
    private var trackingGeneration = UUID()
    private var centerStageChangedByBoard = false
    private var centerStageRestoreEligible = false
    private var centerStageInvalidated = false
    private var trackingPresentation = BoardTrackingPresentation()

    init() {
        let worker = BoardCameraWorker()
        self.worker = worker
        session = worker.session
        selectedDeviceID = UserDefaults.standard.string(forKey: "board.cameraID") ?? ""
        worker.onBoardSample = { [weak self] image, epoch in
            DispatchQueue.main.async {
                guard let self, self.wantsRunning, self.trackingGeneration == epoch,
                      self.trackingState == .tracking, !self.isCalibrating else { return }
                self.onBoardSample?(image, epoch)
            }
        }
        worker.onTrackingUpdate = { [weak self] update, size, epoch in
            DispatchQueue.main.async {
                guard let self, self.wantsRunning, self.trackingGeneration == epoch else { return }
                if self.frameSize != size { self.frameSize = size }
                guard let update, !self.isCalibrating else { return }
                if update.state == .tracking && AVCaptureDevice.isCenterStageEnabled {
                    self.refreshCenterStage()
                    return
                }
                self.applyTrackingUpdate(update)
            }
        }
        worker.resetTracking(epoch: trackingGeneration)
        refreshDevices()
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshDevices() }
            })
        }
        notifications.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "Camera stopped unexpectedly."
            Task { @MainActor in
                self?.stop()
                self?.status = message
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsRunning else { return }
                if self.isCalibrating {
                    self.invalidateCalibration()
                } else if self.trackingState != .off {
                    // A transient interruption invalidates capture geometry, not the user's
                    // last visible selection. Keep it as a lost outline after video resumes.
                    self.trackingGeneration = UUID()
                    self.applyTrackingUpdate(BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: CACurrentMediaTime()))
                    self.worker.loseTracking(epoch: self.trackingGeneration, reason: .sessionInterrupted)
                }
                self.worker.clearFrame()
                self.isRunning = false
                self.status = "Camera interrupted — check its connection or another app using it"
            }
        })
        notifications.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.wantsRunning else { return }
                self.isRunning = self.session.isRunning
                self.status = self.isRunning ? "Camera on" : "Camera interrupted — turn it on again"
            }
        })
    }

    deinit {
        notifications.forEach(NotificationCenter.default.removeObserver)
        effectsTimer?.invalidate()
        worker.stop()
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        captureDevices = discovery.devices.sorted { a, b in
            if (a.deviceType == .builtInWideAngleCamera) != (b.deviceType == .builtInWideAngleCamera) {
                return a.deviceType == .builtInWideAngleCamera
            }
            return a.localizedName.localizedStandardCompare(b.localizedName) == .orderedAscending
        }
        devices = captureDevices.map { CameraOption(id: $0.uniqueID, name: $0.localizedName) }
        if selectedDeviceID.isEmpty { selectedDeviceID = devices.first?.id ?? "" }
        if wantsRunning && !devices.contains(where: { $0.id == selectedDeviceID }) {
            stop()
            status = BoardCameraError.unavailable.localizedDescription
        }
        refreshCenterStage()
    }

    func start() {
        guard !wantsRunning else { return }
        wantsRunning = true
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndStart()
        case .notDetermined:
            isStarting = true
            status = "Allow camera access in the macOS prompt"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    guard let self, self.wantsRunning else { return }
                    if granted { self.configureAndStart() }
                    else { self.permissionDenied() }
                }
            }
        default:
            permissionDenied()
        }
    }

    func stop() {
        wantsRunning = false
        generation = UUID()
        isStarting = false
        isRunning = false
        status = "Camera off"
        invalidateCalibration()
        frameSize = .zero
        centerStageActive = false
        effectsTimer?.invalidate()
        effectsTimer = nil
        worker.stop()
    }

    func capture(completion: @escaping (Result<NSImage, Error>) -> Void) {
        refreshCenterStage()
        guard isRunning, wantsRunning else {
            completion(.failure(BoardCameraError.stopped))
            return
        }
        guard captureAllowed else {
            let error: BoardCameraError = isCalibrating ? .calibrating :
                (trackingState == .tracking && trackedQuad?.isFullyVisible == false ? .boardOutsideFrame : .trackingLost)
            completion(.failure(error))
            return
        }
        let requestedGeneration = generation
        let requestedTrackingGeneration = trackingGeneration
        worker.capture { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.wantsRunning, self.generation == requestedGeneration,
                      self.trackingGeneration == requestedTrackingGeneration else {
                    completion(.failure(BoardCameraError.stopped))
                    return
                }
                completion(result.map { NSImage(cgImage: $0, size: NSSize(width: $0.width, height: $0.height)) })
            }
        }
    }

    func setCenterStage(_ enabled: Bool) {
        guard isRunning, centerStageSupported, !centerStageLocked else { return }
        // Cooperative control preserves the user's ability to change this in macOS Video Effects.
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = enabled
        refreshCenterStage()
    }

    func beginCalibration() {
        guard isRunning, wantsRunning else {
            calibrationError = BoardCameraError.stopped.localizedDescription
            return
        }
        // Disabling Center Stage preserves the physical board's framing while points are chosen.
        // It follows people; it is not the board tracker.
        let framingWasMoving = AVCaptureDevice.isCenterStageEnabled || centerStageActive
        if !centerStageLocked || AVCaptureDevice.isCenterStageEnabled { suspendCenterStage() }
        let epoch = UUID()
        trackingGeneration = epoch
        isCalibrating = true
        centerStageInvalidated = false
        calibrationImage = nil
        resetTrackingPresentation()
        calibrationError = nil
        worker.beginCalibration(epoch: epoch, notBefore: CACurrentMediaTime() + (framingWasMoving ? 0.5 : 0)) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.trackingGeneration == epoch, self.isCalibrating else { return }
                switch result {
                case .success(let image):
                    self.calibrationImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
                    self.frameSize = CGSize(width: image.width, height: image.height)
                case .failure(let error):
                    self.invalidateCalibration()
                    self.calibrationError = error.localizedDescription
                }
            }
        }
    }

    /// Points use normalized top-left coordinates in the frozen raw camera photograph.
    func commitCalibration(points: [CGPoint]) {
        refreshCenterStage()
        guard isCalibrating, calibrationImage != nil, isRunning else {
            calibrationError = BoardCameraError.noCalibrationFrame.localizedDescription
            return
        }
        let quad: BoardQuad
        do { quad = try BoardQuad(points: points) }
        catch { calibrationError = error.localizedDescription; return }
        let epoch = trackingGeneration
        worker.commitCalibration(quad: quad, epoch: epoch) { [weak self] result in
            DispatchQueue.main.async {
                guard let self, self.trackingGeneration == epoch, self.isCalibrating else { return }
                switch result {
                case .success(let update):
                    self.calibrationImage = nil
                    self.isCalibrating = false
                    self.applyTrackingUpdate(update)
                    self.calibrationError = nil
                case .failure(let error):
                    self.calibrationError = error.localizedDescription
                }
            }
        }
    }

    func cancelCalibration() { invalidateCalibration() }
    func clearCalibration() { invalidateCalibration() }

    private func invalidateCalibration() {
        trackingGeneration = UUID()
        calibrationImage = nil
        isCalibrating = false
        resetTrackingPresentation()
        calibrationError = nil
        centerStageInvalidated = false
        worker.resetTracking(epoch: trackingGeneration)
        restoreCenterStageIfUnchanged()
    }

    private func applyTrackingUpdate(_ update: BoardTrackingUpdate) {
        trackingPresentation.apply(update)
        publishTrackingPresentation()
    }

    private func resetTrackingPresentation() {
        trackingPresentation.reset()
        publishTrackingPresentation()
    }

    private func publishTrackingPresentation() {
        if trackingState != trackingPresentation.state { trackingState = trackingPresentation.state }
        if trackedQuad != trackingPresentation.trackedQuad { trackedQuad = trackingPresentation.trackedQuad }
        if displayQuad != trackingPresentation.displayQuad { displayQuad = trackingPresentation.displayQuad }
    }

    private func suspendCenterStage() {
        centerStageChangedByBoard = AVCaptureDevice.isCenterStageEnabled
        centerStageRestoreEligible = centerStageChangedByBoard
        if centerStageChangedByBoard {
            AVCaptureDevice.centerStageControlMode = .cooperative
            AVCaptureDevice.isCenterStageEnabled = false
            centerStageEnabled = false
        }
    }

    private func restoreCenterStageIfUnchanged() {
        if centerStageChangedByBoard && centerStageRestoreEligible,
           AVCaptureDevice.centerStageControlMode == .cooperative,
           !AVCaptureDevice.isCenterStageEnabled {
            AVCaptureDevice.isCenterStageEnabled = true
        }
        centerStageChangedByBoard = false
        centerStageRestoreEligible = false
        centerStageEnabled = AVCaptureDevice.isCenterStageEnabled
    }

    func openCameraSettings() {
        if AVCaptureDevice.authorizationStatus(for: .video) == .denied || AVCaptureDevice.authorizationStatus(for: .video) == .restricted {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                NSWorkspace.shared.open(url)
            }
        } else {
            AVCaptureDevice.showSystemUserInterface(.videoEffects)
        }
    }

    private func permissionDenied() {
        wantsRunning = false
        isStarting = false
        status = "Camera permission is off. Enable Board in System Settings → Privacy & Security → Camera."
    }

    private func configureAndStart() {
        guard wantsRunning else { return }
        invalidateCalibration()
        frameSize = .zero
        guard let device = captureDevices.first(where: { $0.uniqueID == selectedDeviceID }) else {
            stop()
            status = BoardCameraError.unavailable.localizedDescription
            return
        }
        let requestedGeneration = UUID()
        generation = requestedGeneration
        isStarting = true
        isRunning = false
        status = "Starting \(device.localizedName)…"
        worker.start(device: device) { [weak self] result in
            Task { @MainActor in
                guard let self, self.wantsRunning, self.generation == requestedGeneration else { return }
                self.isStarting = false
                switch result {
                case .success:
                    self.isRunning = true
                    self.status = "Camera on · \(device.localizedName)"
                    self.refreshCenterStage()
                    self.effectsTimer?.invalidate()
                    self.effectsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        Task { @MainActor in
                            self?.refreshCenterStage()
                            self?.worker.checkFreshness()
                        }
                    }
                case .failure(let error):
                    self.stop()
                    self.status = error.localizedDescription
                }
            }
        }
    }

    private func refreshCenterStage() {
        let device = captureDevices.first(where: { $0.uniqueID == selectedDeviceID })
        centerStageSupported = device?.activeFormat.isCenterStageSupported ?? false
        centerStageEnabled = AVCaptureDevice.isCenterStageEnabled
        centerStageActive = isRunning && (device?.isCenterStageActive ?? false)
        if centerStageLocked && centerStageEnabled {
            // A change in macOS Video Effects is user intent. Do not toggle it back behind their back.
            centerStageRestoreEligible = false
            if isCalibrating {
                invalidateCalibration()
                calibrationError = "Center Stage changed while calibrating. Turn it off before selecting the board again."
            } else if !centerStageInvalidated {
                centerStageInvalidated = true
                trackingGeneration = UUID()
                applyTrackingUpdate(BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: CACurrentMediaTime()))
                worker.loseTracking(epoch: trackingGeneration, reason: .centerStageChanged)
                calibrationError = "Center Stage changed the camera framing. Recalibrate the board before capturing."
            }
        }
    }
}

/// All capture-session mutations and frame access use this one queue.
private final class BoardCameraWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onTrackingUpdate: ((BoardTrackingUpdate?, CGSize, UUID) -> Void)?
    var onBoardSample: ((CGImage, UUID) -> Void)?
    private var boardSamplingEnabled = false
    private var lastBoardSampleTime: CFTimeInterval = 0
    func setBoardSamplingEnabled(_ enabled: Bool) {
        queue.async { self.boardSamplingEnabled = enabled }
    }
    private let queue = DispatchQueue(label: "research.board.camera", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let intentLock = NSLock()
    private var intent = UUID()
    private var frame: CVPixelBuffer?
    private var currentDevice: AVCaptureDevice?
    private var frameTime: CFTimeInterval = 0
    private let tracker = BoardTracker()
    private let trackingLogger = Logger(subsystem: "research.board.app", category: "tracking")
    private var trackingEpoch = UUID()
    private var trackingConfigured = false
    private var recoveryGate = BoardTrackingRecoveryGate()
    private var calibrationPending = false
    private var frozenFrame: CVPixelBuffer?
    private var frozenFrameTime: CFTimeInterval = 0
    private var calibratedFrameSize: CGSize = .zero
    private var lastInfoTime: CFTimeInterval = 0
    private var pendingCalibrationCompletion: ((Result<CGImage, Error>) -> Void)?
    private var calibrationNotBefore: CFTimeInterval = 0
    private var settledFrameCount = 0

    func start(device: AVCaptureDevice, completion: @escaping (Result<Void, Error>) -> Void) {
        let requestedIntent = replaceIntent()
        queue.async {
            guard self.isCurrent(requestedIntent) else { completion(.failure(BoardCameraError.stopped)); return }
            self.session.stopRunning()
            self.frame = nil
            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input), self.session.canAddOutput(self.output) else {
                    throw BoardCameraError.configuration
                }
                self.session.addInput(input)
                self.currentDevice = device
                self.output.alwaysDiscardsLateVideoFrames = true
                self.output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                self.output.setSampleBufferDelegate(self, queue: self.queue)
                self.session.addOutput(self.output)
                if self.session.canSetSessionPreset(.hd1920x1080) {
                    self.session.sessionPreset = .hd1920x1080
                } else if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                }
                if let connection = self.output.connection(with: .video), connection.isVideoMirroringSupported {
                    connection.automaticallyAdjustsVideoMirroring = false
                    connection.isVideoMirrored = false
                }
                self.session.commitConfiguration()
                guard self.isCurrent(requestedIntent) else { completion(.failure(BoardCameraError.stopped)); return }
                self.session.startRunning()
                if self.session.isRunning { completion(.success(())) }
                else { completion(.failure(BoardCameraError.configuration)) }
            } catch {
                self.session.commitConfiguration()
                completion(.failure(error))
            }
        }
    }

    func stop() {
        _ = replaceIntent()
        queue.async {
            self.session.stopRunning()
            self.frame = nil
            self.frameTime = 0
            self.currentDevice = nil
        }
    }

    private func replaceIntent() -> UUID {
        intentLock.lock()
        defer { intentLock.unlock() }
        intent = UUID()
        return intent
    }

    private func isCurrent(_ expected: UUID) -> Bool {
        intentLock.lock()
        defer { intentLock.unlock() }
        return intent == expected
    }

    func clearFrame() {
        queue.async { self.frame = nil; self.frameTime = 0 }
    }

    func resetTracking(epoch: UUID) {
        queue.async {
            self.trackingEpoch = epoch
            self.tracker.reset()
            self.trackingConfigured = false
            self.recoveryGate.reset()
            self.calibrationPending = false
            self.frozenFrame = nil
            self.frozenFrameTime = 0
            self.pendingCalibrationCompletion = nil
            self.settledFrameCount = 0
            self.calibratedFrameSize = .zero
            self.lastInfoTime = 0
        }
    }

    func loseTracking(epoch: UUID, reason: BoardTrackingLossReason) {
        queue.async {
            self.trackingEpoch = epoch
            self.markTrackingLost(reason: reason)
        }
    }

    func checkFreshness() {
        queue.async {
            guard self.trackingConfigured, self.recoveryGate.mayProcess, self.frameTime > 0,
                  CACurrentMediaTime() - self.frameTime > 2 else { return }
            self.markTrackingLost(reason: .staleFrame, allowRecovery: true)
        }
    }

    func beginCalibration(epoch: UUID, notBefore: CFTimeInterval, completion: @escaping (Result<CGImage, Error>) -> Void) {
        queue.async {
            self.trackingEpoch = epoch
            self.tracker.reset()
            self.trackingConfigured = false
            self.recoveryGate.reset()
            self.calibrationPending = true
            self.frozenFrame = nil
            self.pendingCalibrationCompletion = nil
            self.settledFrameCount = 0
            guard self.session.isRunning else { completion(.failure(BoardCameraError.stopped)); return }
            self.calibrationNotBefore = notBefore
            self.pendingCalibrationCompletion = completion
            // Await new uncropped frames asynchronously. Never freeze a cached Center Stage frame.
            self.queue.asyncAfter(deadline: .now() + 3) {
                guard self.trackingEpoch == epoch, self.frozenFrame == nil,
                      let callback = self.pendingCalibrationCompletion else { return }
                self.pendingCalibrationCompletion = nil
                callback(.failure(BoardCameraError.calibrationTimeout))
            }
        }
    }

    func commitCalibration(quad: BoardQuad, epoch: UUID, completion: @escaping (Result<BoardTrackingUpdate, Error>) -> Void) {
        queue.async {
            guard self.trackingEpoch == epoch, self.calibrationPending, let frozen = self.frozenFrame else {
                completion(.failure(BoardCameraError.noCalibrationFrame)); return
            }
            do {
                // Seeding against a later frame would attach the four clicks to the wrong geometry.
                try self.tracker.start(buffer: frozen, quad: quad, time: self.frozenFrameTime)
                guard let update = self.tracker.latest, update.state == .tracking else {
                    throw BoardCameraError.configuration
                }
                self.calibratedFrameSize = self.size(of: frozen)
                self.trackingConfigured = true
                self.recoveryGate.reset()
                self.calibrationPending = false
                self.frozenFrame = nil
                completion(.success(update))
            } catch {
                self.trackingConfigured = false
                completion(.failure(error))
            }
        }
    }

    func capture(completion: @escaping (Result<CGImage, Error>) -> Void) {
        queue.async {
            guard self.session.isRunning else { completion(.failure(BoardCameraError.stopped)); return }
            guard !self.calibrationPending else { completion(.failure(BoardCameraError.calibrating)); return }
            guard let frame = self.frame, CACurrentMediaTime() - self.frameTime < 2 else {
                if self.trackingConfigured {
                    self.markTrackingLost(reason: .staleFrame, allowRecovery: true)
                    completion(.failure(BoardCameraError.trackingLost))
                } else {
                    completion(.failure(BoardCameraError.noFrame))
                }
                return
            }
            let image = CIImage(cvPixelBuffer: frame)
            if self.trackingConfigured {
                guard self.recoveryGate.mayProcess else {
                    completion(.failure(BoardCameraError.trackingLost)); return
                }
                guard !AVCaptureDevice.isCenterStageEnabled else {
                    self.markTrackingLost(reason: .centerStageChanged)
                    completion(.failure(BoardCameraError.trackingLost)); return
                }
                guard self.size(of: frame) == self.calibratedFrameSize else {
                    self.markTrackingLost(reason: .resolutionChanged)
                    completion(.failure(BoardCameraError.trackingLost)); return
                }
                // This result and the full-resolution perspective correction use the same frame.
                let update = self.tracker.process(buffer: frame, time: self.frameTime, force: true) ?? self.tracker.latest
                guard let update, update.time == self.frameTime, update.state == .tracking, let quad = update.quad else {
                    let reason = self.tracker.lastRejection.map { BoardTrackingLossReason.fromCore($0) } ?? .exactFrameUnavailable
                    self.markTrackingLost(reason: reason, allowRecovery: true)
                    completion(.failure(BoardCameraError.trackingLost)); return
                }
                self.publishFreshTracking(update, size: self.size(of: frame))
                guard quad.isFullyVisible else {
                    completion(.failure(BoardCameraError.boardOutsideFrame)); return
                }
                guard let corrected = BoardTracker.rectify(image: image, quad: quad, context: self.context) else {
                    completion(.failure(BoardCameraError.configuration)); return
                }
                completion(.success(corrected))
                return
            }
            guard let cgImage = self.context.createCGImage(image, from: image.extent) else {
                completion(.failure(BoardCameraError.configuration)); return
            }
            completion(.success(cgImage))
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        autoreleasepool { acceptFrame(sampleBuffer) }
    }

    private func acceptFrame(_ sampleBuffer: CMSampleBuffer) {
        frame = CMSampleBufferGetImageBuffer(sampleBuffer)
        frameTime = CACurrentMediaTime()
        guard let frame else { return }
        let size = size(of: frame)
        if calibrationPending, frozenFrame == nil, let completion = pendingCalibrationCompletion {
            if frameTime >= calibrationNotBefore && !AVCaptureDevice.isCenterStageEnabled && currentDevice?.isCenterStageActive != true {
                settledFrameCount += 1
            } else {
                settledFrameCount = 0
            }
            if settledFrameCount >= 3 {
                pendingCalibrationCompletion = nil
                let image = CIImage(cvPixelBuffer: frame)
                if let cgImage = context.createCGImage(image, from: image.extent) {
                    // Retain exactly the frame shown to the user, independently of the live frame.
                    frozenFrame = frame
                    frozenFrameTime = frameTime
                    completion(.success(cgImage))
                } else {
                    completion(.failure(BoardCameraError.configuration))
                }
            }
        }
        if trackingConfigured && recoveryGate.mayProcess {
            if size != calibratedFrameSize {
                markTrackingLost(reason: .resolutionChanged)
                return
            }
            if AVCaptureDevice.isCenterStageEnabled {
                markTrackingLost(reason: .centerStageChanged)
                return
            }
            // Native tracking executes serially here. Late camera frames are dropped;
            // analysis stays bounded to 960 pixels at 8/15 Hz, or 4 Hz after loss.
            if let update = tracker.process(buffer: frame, time: frameTime) {
                if update.state == .lost {
                    markTrackingLost(reason: .fromCore(tracker.lastRejection), allowRecovery: true)
                    return
                }
                lastInfoTime = frameTime
                publishFreshTracking(update, size: size)
                return
            }
        }
        if frameTime - lastInfoTime >= 0.5 {
            lastInfoTime = frameTime
            onTrackingUpdate?(nil, size, trackingEpoch)
        }
    }

    private func size(of buffer: CVPixelBuffer) -> CGSize {
        CGSize(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))
    }

    private func publishFreshTracking(_ update: BoardTrackingUpdate, size: CGSize) {
        guard recoveryGate.mayProcess, update.state == .tracking, update.quad != nil, update.time == frameTime else { return }
        if recoveryGate.acceptTracking() { trackingLogger.notice("tracking_recovered") }
        onTrackingUpdate?(update, size, trackingEpoch)
        if boardSamplingEnabled, frameTime - lastBoardSampleTime >= 0.5,
           let frame, let quad = update.quad, quad.isFullyVisible {
            lastBoardSampleTime = frameTime
            let image = CIImage(cvPixelBuffer: frame)
            let scale = min(1, 640 / max(image.extent.width, image.extent.height))
            let reduced = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            if let board = BoardTracker.rectify(image: reduced, quad: quad, context: context) {
                onBoardSample?(board, trackingEpoch)
            }
        }
    }

    private func markTrackingLost(reason: BoardTrackingLossReason, allowRecovery: Bool = false) {
        let wasHardInvalid = recoveryGate.hardInvalid
        let wasLost = recoveryGate.isLost
        let changed = recoveryGate.lose(allowRecovery: allowRecovery, canRecover: tracker.canRecover)
        if trackingConfigured && changed {
            trackingLogger.notice("tracking_lost reason=\(reason.rawValue, privacy: .public)")
        } else if trackingConfigured && wasLost && !wasHardInvalid && recoveryGate.hardInvalid {
            trackingLogger.notice("tracking_recovery_stopped reason=\(reason.rawValue, privacy: .public)")
        }
        if recoveryGate.hardInvalid { tracker.reset() }
        let size = frame.map { self.size(of: $0) } ?? .zero
        onTrackingUpdate?(BoardTrackingUpdate(quad: nil, state: .lost, confidence: 0, time: frameTime), size, trackingEpoch)
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> BoardCameraPreviewView { BoardCameraPreviewView(session: session) }
    func updateNSView(_ nsView: BoardCameraPreviewView, context: Context) {
        // Tracking redraws must not repeatedly replace the native preview connection.
        if nsView.preview.session !== session { nsView.preview.session = session }
    }
}

final class BoardCameraPreviewView: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    init(session: AVCaptureSession) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        preview.session = session
        preview.videoGravity = .resizeAspect
        layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        CATransaction.commit()
    }
}
