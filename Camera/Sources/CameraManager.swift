import AVFoundation
import AppKit
import Photos
import Vision

/// Manages AVCaptureSession, photo/video capture, mirror, Center Stage,
/// timelapse, slow-motion, night mode, and Photos library integration.
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published State

    @Published var isSessionRunning = false
    @Published var capturedImage: NSImage?
    @Published var thumbnailImage: NSImage?
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var activeCamera: AVCaptureDevice?
    @Published var errorMessage: String?
    @Published var isCapturing = false
    @Published var isMirrored = false
    @Published var centerStageAvailable = false
    @Published var centerStageActive = false
    @Published var photosAuthorized = false

    // Mode & recording
    @Published var currentMode: CaptureMode = .photo
    @Published var isRecording = false
    @Published var recordingDuration: TimeInterval = 0
    @Published var isProcessingTimelapse = false

    // QR code scanning
    @Published var detectedQRString: String?
    @Published var isQRScanning = false

    // MARK: - Internals

    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private var videoInput: AVCaptureDeviceInput?
    private var audioInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "com.camera.session", qos: .userInitiated)
    private let qrProcessingQueue = DispatchQueue(label: "com.camera.qr", qos: .userInitiated)
    private var captureCompletion: (() -> Void)?
    private var mirrorAtCapture = false
    private var latestAssetID: String?
    private var recordingTimer: Timer?
    private var recordingStartTime: Date?
    private var modeAtRecordingStart: CaptureMode = .video

    // MARK: - Lifecycle

    override init() {
        super.init()
        discoverCameras()
        PHPhotoLibrary.shared().register(self)
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceWasConnected),
            name: .AVCaptureDeviceWasConnected, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(deviceWasDisconnected),
            name: .AVCaptureDeviceWasDisconnected, object: nil
        )
        requestPhotosAccess()
    }

    deinit {
        stopSession()
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    // MARK: - Photos Authorization

    private func requestPhotosAccess() {
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { [weak self] status in
            DispatchQueue.main.async {
                self?.photosAuthorized = (status == .authorized || status == .limited)
            }
            if status == .authorized || status == .limited {
                self?.fetchMostRecentAsset()
            }
        }
    }

    // MARK: - Device Discovery

    private var discoveryTypes: [AVCaptureDevice.DeviceType] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) { types.append(.external) }
        return types
    }

    func isExternal(_ device: AVCaptureDevice) -> Bool {
        if #available(macOS 14.0, *) { return device.deviceType == .external }
        return false
    }

    func discoverCameras() {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes, mediaType: .video, position: .unspecified
        ).devices
        DispatchQueue.main.async {
            self.availableCameras = found.sorted { lhs, _ in self.isExternal(lhs) }
        }
    }

    private func preferredCamera() -> AVCaptureDevice? {
        let found = AVCaptureDevice.DiscoverySession(
            deviceTypes: discoveryTypes, mediaType: .video, position: .unspecified
        ).devices
        return found.first(where: { isExternal($0) }) ?? AVCaptureDevice.default(for: .video)
    }

    // MARK: - Session

    func startSession() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            guard let camera = self.preferredCamera() else {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = "No camera found. Connect a camera and try again."
                }
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: camera)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoInput = input
                }
                self.session.commitConfiguration()

                // Configure outputs for current mode
                self.configureSession(for: self.currentMode)

                self.session.startRunning()

                DispatchQueue.main.async {
                    self.isSessionRunning = true
                    self.activeCamera = camera
                    self.refreshCenterStage()
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = "Camera error: \(error.localizedDescription)"
                }
            }
        }
    }

    func stopSession() {
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
            DispatchQueue.main.async { self.isSessionRunning = false }
        }
    }

    func switchCamera(to device: AVCaptureDevice) {
        guard !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            if let old = self.videoInput { self.session.removeInput(old) }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                    self.videoInput = input
                }
                self.session.commitConfiguration()

                // Re-apply mode-specific configuration (frame rate, exposure)
                self.applyModeSettings(for: self.currentMode, device: device)

                DispatchQueue.main.async {
                    self.activeCamera = device
                    self.refreshCenterStage()
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = "Switch failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Mode Management

    func setMode(_ mode: CaptureMode) {
        guard mode != currentMode else { return }
        if isRecording { stopRecording() }

        // Reset device settings when leaving special modes
        if currentMode == .hdr, let device = videoInput?.device {
            sessionQueue.async { self.configureHDR(device: device, enabled: false) }
        }
        if currentMode == .qrCode {
            DispatchQueue.main.async {
                self.isQRScanning = false
                self.detectedQRString = nil
            }
        }

        DispatchQueue.main.async { self.currentMode = mode }
        configureSession(for: mode)
    }

    private func configureSession(for mode: CaptureMode) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            // Remove all outputs
            for output in self.session.outputs {
                self.session.removeOutput(output)
            }

            switch mode {
            case .photo, .hdr:
                self.session.sessionPreset = .photo
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
            case .video, .timelapse, .slowMotion:
                self.session.sessionPreset = .high
                if self.session.canAddOutput(self.movieOutput) {
                    self.session.addOutput(self.movieOutput)
                }
                // Also add photo output for potential stills during video
                if self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                }
            case .qrCode:
                self.session.sessionPreset = .high
                self.videoDataOutput.setSampleBufferDelegate(self, queue: self.qrProcessingQueue)
                self.videoDataOutput.alwaysDiscardsLateVideoFrames = true
                if self.session.canAddOutput(self.videoDataOutput) {
                    self.session.addOutput(self.videoDataOutput)
                }
                DispatchQueue.main.async {
                    self.detectedQRString = nil
                    self.isQRScanning = true
                }
            }

            self.session.commitConfiguration()

            // Apply device-level settings (frame rate, exposure)
            if let device = self.videoInput?.device {
                self.applyModeSettings(for: mode, device: device)
            }
        }
    }

    private func applyModeSettings(for mode: CaptureMode, device: AVCaptureDevice) {
        switch mode {
        case .slowMotion:
            let maxFPS = maxAvailableFrameRate(for: device)
            configureFrameRate(device: device, targetFPS: maxFPS)
            configureHDR(device: device, enabled: false)
        case .hdr:
            resetFrameRate(device: device)
            configureHDR(device: device, enabled: true)
        default:
            resetFrameRate(device: device)
            configureHDR(device: device, enabled: false)
        }
    }

    // MARK: - Mirror

    func toggleMirror() {
        DispatchQueue.main.async { self.isMirrored.toggle() }
    }

    private func mirrorImage(_ image: NSImage) -> NSImage {
        let size = image.size
        let flipped = NSImage(size: size)
        flipped.lockFocus()
        let transform = NSAffineTransform()
        transform.translateX(by: size.width, yBy: 0)
        transform.scaleX(by: -1, yBy: 1)
        transform.concat()
        image.draw(in: NSRect(origin: .zero, size: size))
        flipped.unlockFocus()
        return flipped
    }

    // MARK: - Center Stage

    private func refreshCenterStage() {
        guard #available(macOS 12.3, *),
              let cam = activeCamera, isExternal(cam) else {
            centerStageAvailable = false
            centerStageActive = false
            return
        }
        centerStageAvailable = true
        centerStageActive = AVCaptureDevice.isCenterStageEnabled
    }

    func toggleCenterStage() {
        guard #available(macOS 12.3, *), centerStageAvailable else { return }
        let newState = !centerStageActive
        AVCaptureDevice.centerStageControlMode = .cooperative
        AVCaptureDevice.isCenterStageEnabled = newState
        DispatchQueue.main.async {
            self.centerStageActive = AVCaptureDevice.isCenterStageEnabled
        }
    }

    // MARK: - Photo Capture

    func capturePhoto(completion: @escaping () -> Void) {
        guard session.isRunning else {
            completion()
            return
        }
        DispatchQueue.main.async { self.isCapturing = true }
        captureCompletion = completion
        mirrorAtCapture = isMirrored

        let settings = AVCapturePhotoSettings()

        // HDR mode: maximize photo quality for best tone mapping and dynamic range
        if currentMode == .hdr {
            if #available(macOS 13.0, *) {
                settings.photoQualityPrioritization = .quality
                // Use maximum photo dimensions for highest detail
                settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
            }
        }

        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Video Recording

    func startRecording() {
        guard session.isRunning, !isRecording else { return }

        modeAtRecordingStart = currentMode

        // Add audio input if not present
        addAudioInputIfNeeded()

        let tempDir = FileManager.default.temporaryDirectory
        let ext = "mov"
        let url = tempDir.appendingPathComponent(UUID().uuidString + "." + ext)

        // For timelapse, remove audio from the movie output connection
        if currentMode == .timelapse {
            if let audioConnection = movieOutput.connection(with: .audio) {
                audioConnection.isEnabled = false
            }
        } else {
            if let audioConnection = movieOutput.connection(with: .audio) {
                audioConnection.isEnabled = true
            }
        }

        movieOutput.startRecording(to: url, recordingDelegate: self)

        DispatchQueue.main.async {
            self.isRecording = true
            self.recordingStartTime = Date()
            self.startRecordingTimer()
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        movieOutput.stopRecording()
    }

    private func addAudioInputIfNeeded() {
        guard audioInput == nil else { return }
        guard let mic = AVCaptureDevice.default(for: .audio) else { return }

        do {
            let input = try AVCaptureDeviceInput(device: mic)
            session.beginConfiguration()
            if session.canAddInput(input) {
                session.addInput(input)
                audioInput = input
            }
            session.commitConfiguration()
        } catch {
            // Audio is optional
        }
    }

    private func removeAudioInput() {
        guard let input = audioInput else { return }
        session.beginConfiguration()
        session.removeInput(input)
        session.commitConfiguration()
        audioInput = nil
    }

    private func startRecordingTimer() {
        recordingTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.recordingDuration = Date().timeIntervalSince(start)
        }
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    // MARK: - Save to Photos Library (Photo - HEIC)

    private func savePhotoToPhotosLibrary(_ image: NSImage) {
        guard photosAuthorized else { return }
        guard let cgImage = image.cgImage(
            forProposedRect: nil, context: nil, hints: nil
        ) else { return }

        let data = NSMutableData()
        let heicType = "public.heic" as CFString
        let jpegType = "public.jpeg" as CFString
        let uti = CGImageDestinationCreateWithData(data, heicType, 1, nil) != nil
            ? heicType : jpegType

        guard let dest = CGImageDestinationCreateWithData(data, uti, 1, nil) else { return }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return }

        PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.uniformTypeIdentifier = uti as String
            request.addResource(with: .photo, data: data as Data, options: options)
        } completionHandler: { [weak self] success, error in
            if success {
                self?.fetchMostRecentAsset()
            } else if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Save to Photos Library (Video)

    private func saveVideoToPhotosLibrary(_ url: URL) {
        guard photosAuthorized else { return }

        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        } completionHandler: { [weak self] success, error in
            // Clean up temp file
            try? FileManager.default.removeItem(at: url)

            if success {
                self?.fetchMostRecentAsset()
            } else if let error {
                DispatchQueue.main.async {
                    self?.errorMessage = "Save failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Timelapse Post-Processing

    private func speedUpVideo(at url: URL, factor: Double, completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: url)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }

        let composition = AVMutableComposition()
        guard let compTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(nil)
            return
        }

        let duration = asset.duration
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        do {
            try compTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            compTrack.preferredTransform = videoTrack.preferredTransform

            let scaledDuration = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / factor)
            compTrack.scaleTimeRange(timeRange, toDuration: scaledDuration)

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_timelapse.mov")

            guard let exporter = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality
            ) else {
                completion(nil)
                return
            }

            exporter.outputURL = outputURL
            exporter.outputFileType = .mov
            exporter.exportAsynchronously { [weak self] in
                // Clean original
                try? FileManager.default.removeItem(at: url)

                DispatchQueue.main.async {
                    self?.isProcessingTimelapse = false
                }

                if exporter.status == .completed {
                    completion(outputURL)
                } else {
                    completion(nil)
                }
            }
        } catch {
            completion(nil)
        }
    }

    // MARK: - Slow Motion Helpers

    private func maxAvailableFrameRate(for device: AVCaptureDevice) -> Double {
        var maxFPS: Double = 30
        for format in device.formats {
            for range in format.videoSupportedFrameRateRanges {
                if range.maxFrameRate > maxFPS {
                    maxFPS = range.maxFrameRate
                }
            }
        }
        return maxFPS
    }

    /// Stretch a video's timeline so it plays back in slow motion.
    /// factor > 1 means slower: 2.0 = half speed, 4.0 = quarter speed.
    private func slowDownVideo(at url: URL, factor: Double, completion: @escaping (URL?) -> Void) {
        let asset = AVAsset(url: url)

        guard let videoTrack = asset.tracks(withMediaType: .video).first else {
            completion(nil)
            return
        }

        let composition = AVMutableComposition()

        guard let compVideoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            completion(nil)
            return
        }

        let duration = asset.duration
        let timeRange = CMTimeRange(start: .zero, duration: duration)

        do {
            try compVideoTrack.insertTimeRange(timeRange, of: videoTrack, at: .zero)
            compVideoTrack.preferredTransform = videoTrack.preferredTransform

            // Stretch video to play slower
            let stretchedDuration = CMTimeMultiplyByFloat64(duration, multiplier: factor)
            compVideoTrack.scaleTimeRange(timeRange, toDuration: stretchedDuration)

            // Also slow down audio if present
            if let audioTrack = asset.tracks(withMediaType: .audio).first,
               let compAudioTrack = composition.addMutableTrack(
                   withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid
               ) {
                try compAudioTrack.insertTimeRange(timeRange, of: audioTrack, at: .zero)
                compAudioTrack.scaleTimeRange(timeRange, toDuration: stretchedDuration)
            }

            let outputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + "_slowmo.mov")

            guard let exporter = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetHighestQuality
            ) else {
                completion(nil)
                return
            }

            exporter.outputURL = outputURL
            exporter.outputFileType = .mov
            exporter.exportAsynchronously { [weak self] in
                try? FileManager.default.removeItem(at: url)

                DispatchQueue.main.async {
                    self?.isProcessingTimelapse = false
                }

                if exporter.status == .completed {
                    completion(outputURL)
                } else {
                    completion(nil)
                }
            }
        } catch {
            completion(nil)
        }
    }

    private func configureFrameRate(device: AVCaptureDevice, targetFPS: Double) {
        do {
            try device.lockForConfiguration()

            var bestFormat: AVCaptureDevice.Format?
            var bestRange: AVFrameRateRange?

            for format in device.formats {
                for range in format.videoSupportedFrameRateRanges {
                    if range.maxFrameRate >= targetFPS {
                        if bestRange == nil || range.maxFrameRate < bestRange!.maxFrameRate {
                            // Pick the format closest to our target (not wildly over)
                            bestFormat = format
                            bestRange = range
                        }
                    }
                }
            }

            if let format = bestFormat, let range = bestRange {
                device.activeFormat = format
                let clampedFPS = min(targetFPS, range.maxFrameRate)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(clampedFPS))
            }

            device.unlockForConfiguration()
        } catch {
            // Fall back to default
        }
    }

    private func resetFrameRate(device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            device.activeVideoMinFrameDuration = .invalid
            device.activeVideoMaxFrameDuration = .invalid
            device.unlockForConfiguration()
        } catch {}
    }

    // MARK: - HDR Helpers

    private func configureHDR(device: AVCaptureDevice, enabled: Bool) {
        // macOS does not expose automaticallyAdjustsVideoHDREnabled or isVideoHDREnabled.
        // HDR on macOS is achieved through the photo output pipeline:
        //   - maxPhotoQualityPrioritization = .quality for best tone mapping
        //   - High-resolution capture for maximum detail
        // The actual HDR capture settings are applied per-shot in capturePhoto().
        if enabled {
            if #available(macOS 13.0, *) {
                photoOutput.maxPhotoQualityPrioritization = .quality
            }
        }
    }

    // MARK: - Fetch Most Recent Asset (Photo or Video)

    func fetchMostRecentAsset() {
        guard photosAuthorized else { return }

        let opts = PHFetchOptions()
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        opts.fetchLimit = 1

        // No media type filter - fetches most recent photo OR video
        let result = PHAsset.fetchAssets(with: opts)
        guard let asset = result.firstObject else {
            DispatchQueue.main.async {
                self.thumbnailImage = nil
                self.latestAssetID = nil
            }
            return
        }

        let assetID = asset.localIdentifier

        let imgOpts = PHImageRequestOptions()
        imgOpts.deliveryMode = .highQualityFormat
        imgOpts.resizeMode = .exact
        imgOpts.isSynchronous = false

        let size = CGSize(width: 120, height: 120)
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: size,
            contentMode: .aspectFill,
            options: imgOpts
        ) { [weak self] platformImage, _ in
            guard let self else { return }
            let nsImage: NSImage? = platformImage
            DispatchQueue.main.async {
                self.thumbnailImage = nsImage
                self.latestAssetID = assetID
            }
        }
    }

    // MARK: - Open in Photos

    func openInPhotos() {
        guard let id = latestAssetID else { return }
        let url = URL(string: "photos://photo?id=\(id)")
            ?? URL(string: "photos://")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - Notifications

    @objc private func deviceWasConnected(_ note: Notification) {
        discoverCameras()
        if let dev = note.object as? AVCaptureDevice, isExternal(dev) {
            switchCamera(to: dev)
        }
    }

    @objc private func deviceWasDisconnected(_ note: Notification) {
        discoverCameras()
        if let dev = note.object as? AVCaptureDevice,
           dev.uniqueID == activeCamera?.uniqueID,
           let fallback = preferredCamera() {
            switchCamera(to: fallback)
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let shouldMirror = mirrorAtCapture

        defer {
            DispatchQueue.main.async {
                self.isCapturing = false
                self.captureCompletion?()
                self.captureCompletion = nil
            }
        }

        if let error {
            DispatchQueue.main.async {
                self.errorMessage = "Capture failed: \(error.localizedDescription)"
            }
            return
        }

        guard let data = photo.fileDataRepresentation(),
              let raw = NSImage(data: data) else {
            DispatchQueue.main.async {
                self.errorMessage = "Could not process image data."
            }
            return
        }

        var finalImage = raw
        if shouldMirror {
            finalImage = mirrorImage(finalImage)
        }

        DispatchQueue.main.async {
            self.capturedImage = finalImage
            self.errorMessage = nil
        }

        savePhotoToPhotosLibrary(finalImage)
    }
}

// MARK: - AVCaptureFileOutputRecordingDelegate

extension CameraManager: AVCaptureFileOutputRecordingDelegate {
    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        // Remove mic input immediately so macOS restores full audio quality
        // for other apps (YouTube, Music, etc.). The mic being attached forces
        // the audio hardware into a low-quality input/output mode.
        removeAudioInput()

        DispatchQueue.main.async {
            self.isRecording = false
            self.recordingDuration = 0
            self.stopRecordingTimer()
        }

        if let error {
            DispatchQueue.main.async {
                self.errorMessage = "Recording failed: \(error.localizedDescription)"
            }
            try? FileManager.default.removeItem(at: outputFileURL)
            return
        }

        let mode = modeAtRecordingStart

        switch mode {
        case .timelapse:
            DispatchQueue.main.async { self.isProcessingTimelapse = true }
            speedUpVideo(at: outputFileURL, factor: 8.0) { [weak self] resultURL in
                if let resultURL {
                    self?.saveVideoToPhotosLibrary(resultURL)
                } else {
                    DispatchQueue.main.async {
                        self?.isProcessingTimelapse = false
                        self?.errorMessage = "Timelapse processing failed."
                    }
                }
            }
        case .slowMotion:
            // Slow down the video so it plays at half speed (or more if fps > 60)
            let captureFPS: Double
            if let device = videoInput?.device {
                captureFPS = maxAvailableFrameRate(for: device)
            } else {
                captureFPS = 30
            }
            let slowFactor = max(captureFPS / 30.0, 2.0) // at least 2x slow
            DispatchQueue.main.async { self.isProcessingTimelapse = true }
            slowDownVideo(at: outputFileURL, factor: slowFactor) { [weak self] resultURL in
                if let resultURL {
                    self?.saveVideoToPhotosLibrary(resultURL)
                } else {
                    DispatchQueue.main.async {
                        self?.isProcessingTimelapse = false
                        self?.errorMessage = "Slo-Mo processing failed."
                    }
                }
            }
        case .video:
            saveVideoToPhotosLibrary(outputFileURL)
        default:
            saveVideoToPhotosLibrary(outputFileURL)
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate (QR via Vision)

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard currentMode == .qrCode, detectedQRString == nil else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let request = VNDetectBarcodesRequest { [weak self] request, error in
            guard error == nil,
                  let results = request.results as? [VNBarcodeObservation] else { return }

            for barcode in results {
                if barcode.symbology == .qr, let value = barcode.payloadStringValue, !value.isEmpty {
                    DispatchQueue.main.async {
                        self?.detectedQRString = value
                    }
                    return
                }
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    func clearDetectedQR() {
        detectedQRString = nil
    }
}

// MARK: - PHPhotoLibraryChangeObserver

extension CameraManager: PHPhotoLibraryChangeObserver {
    func photoLibraryDidChange(_ changeInstance: PHChange) {
        fetchMostRecentAsset()
    }
}
