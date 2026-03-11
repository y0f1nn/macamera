import SwiftUI
import AVFoundation

// MARK: - Root

struct ContentView: View {
    @StateObject private var camera = CameraManager()
    @State private var showFlash = false
    @State private var countdown: Int? = nil
    @State private var isCountingDown = false
    @State private var timerSeconds = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if camera.isSessionRunning {
                cameraLayer
                controlsOverlay
            } else if let msg = camera.errorMessage {
                errorView(msg)
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .onAppear { camera.startSession() }
        .onDisappear { camera.stopSession() }
    }

    // MARK: - Camera Feed

    private var cameraLayer: some View {
        ZStack {
            CameraPreview(
                session: camera.session,
                isMirrored: camera.isMirrored
            )
            .ignoresSafeArea()
            .clipped()

            if showFlash {
                Color.white.ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            if let n = countdown {
                Text("\(n)")
                    .font(.system(size: 140, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.6), radius: 30)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
                    .id(n)
            }

            if camera.isProcessingTimelapse {
                VStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                    Text("Processing Timelapse…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.8))
                }
                .padding(24)
                .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.7)))
            }

            // QR scanning overlay
            if camera.currentMode == .qrCode {
                qrScanOverlay
            }
        }
        .animation(.easeOut(duration: 0.25), value: countdown)
    }

    // MARK: - Controls Overlay

    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if camera.isRecording {
                recordingIndicator
                    .padding(.bottom, 12)
            }
            modeSelector
                .padding(.bottom, 24)
            bottomBar
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Flash toggle — hidden when no flash is possible (e.g. phone front camera)
            if camera.flashCapability != .none {
                Button { camera.flashEnabled.toggle() } label: {
                    ToolbarPill(
                        icon: camera.flashEnabled ? "bolt.fill" : "bolt.slash",
                        text: "Flash",
                        active: camera.flashEnabled
                    )
                }
                .buttonStyle(.plain)
            }

            // Mirror / flip button
            Button { camera.toggleMirror() } label: {
                ToolbarPill(
                    icon: "arrow.left.and.right.righttriangle.left.righttriangle.right",
                    text: "Flip",
                    active: camera.isMirrored
                )
            }
            .buttonStyle(.plain)

            // Camera switcher (multiple cameras)
            if camera.availableCameras.count > 1 {
                Menu {
                    ForEach(camera.availableCameras, id: \.uniqueID) { dev in
                        Button {
                            camera.switchCamera(to: dev)
                        } label: {
                            Label(
                                dev.localizedName,
                                systemImage: dev.uniqueID == camera.activeCamera?.uniqueID
                                    ? "checkmark.circle.fill" : "camera"
                            )
                        }
                    }
                } label: {
                    ToolbarPill(icon: "camera.rotate")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(camera.isRecording)
                .opacity(camera.isRecording ? 0.4 : 1)
            }

            Spacer()

            // Center Stage
            if camera.centerStageAvailable {
                Button { camera.toggleCenterStage() } label: {
                    ToolbarPill(
                        icon: "person.and.background.dotted",
                        text: "Center Stage",
                        active: camera.centerStageActive
                    )
                }
                .buttonStyle(.plain)
            }

            // Timer
            Menu {
                Button { timerSeconds = 0 } label: {
                    Label("Off", systemImage: timerSeconds == 0 ? "checkmark" : "")
                }
                Button { timerSeconds = 3 } label: {
                    Label("3 seconds", systemImage: timerSeconds == 3 ? "checkmark" : "")
                }
                Button { timerSeconds = 10 } label: {
                    Label("10 seconds", systemImage: timerSeconds == 10 ? "checkmark" : "")
                }
            } label: {
                ToolbarPill(
                    icon: "timer",
                    text: timerSeconds > 0 ? "\(timerSeconds)s" : nil,
                    active: timerSeconds > 0
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    // MARK: - Mode Selector

    private var modeSelector: some View {
        HStack(spacing: 20) {
            ForEach(CaptureMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        camera.setMode(mode)
                    }
                } label: {
                    Text(mode.rawValue.uppercased())
                        .font(.system(
                            size: 13,
                            weight: camera.currentMode == mode ? .bold : .medium
                        ))
                        .foregroundStyle(
                            camera.currentMode == mode ? .yellow : .white.opacity(0.5)
                        )
                }
                .buttonStyle(.plain)
                .disabled(camera.isRecording)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Capsule().fill(.black.opacity(0.35)))
    }

    // MARK: - Recording Indicator

    private var recordingIndicator: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 10, height: 10)

            Text(formattedDuration(camera.recordingDuration))
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Capsule().fill(Color.black.opacity(0.5)))
        .transition(.opacity)
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let totalSecs = Int(interval)
        let mins = totalSecs / 60
        let secs = totalSecs % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(alignment: .center) {
            if camera.currentMode == .qrCode {
                Spacer()
            } else {
                // Thumbnail — shows most recent photo or video from Photos library
                Button {
                    camera.openInPhotos()
                } label: {
                    Group {
                        if let img = camera.thumbnailImage {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            Color.white.opacity(0.08)
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.system(size: 18))
                                        .foregroundStyle(.white.opacity(0.3))
                                )
                        }
                    }
                    .frame(width: 54, height: 54)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)

                Spacer()

                // Shutter / Record button
                Button(action: shutter) {
                    ZStack {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 4)
                            .frame(width: 74, height: 74)

                        if camera.currentMode.isVideoMode {
                            Group {
                                if camera.isRecording {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(Color.red)
                                        .frame(width: 30, height: 30)
                                } else {
                                    Circle()
                                        .fill(Color.red)
                                        .frame(width: 62, height: 62)
                                }
                            }
                            .animation(.easeInOut(duration: 0.15), value: camera.isRecording)
                        } else {
                            Circle()
                                .fill(Color.white)
                                .frame(width: 62, height: 62)
                                .scaleEffect(camera.isCapturing ? 0.82 : 1)
                                .animation(.easeInOut(duration: 0.08), value: camera.isCapturing)
                        }
                    }
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(isCountingDown || camera.isProcessingTimelapse)

                Spacer()

                // Invisible spacer to balance the thumbnail on the left
                Color.clear
                    .frame(width: 54, height: 54)
            }
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 28)
    }

    // MARK: - QR Scan Overlay

    private var qrScanOverlay: some View {
        VStack {
            // Viewfinder graphic
            Spacer()
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color.yellow, lineWidth: 3)
                .frame(width: 220, height: 220)
                .overlay(
                    Image(systemName: "qrcode.viewfinder")
                        .font(.system(size: 48))
                        .foregroundStyle(.yellow.opacity(camera.detectedQRString == nil ? 0.4 : 0))
                )
            Spacer()

            // Result card
            if let qr = camera.detectedQRString {
                VStack(spacing: 12) {
                    Text(qr)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(5)
                        .textSelection(.enabled)

                    HStack(spacing: 16) {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(qr, forType: .string)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)

                        if let url = URL(string: qr),
                           url.scheme == "http" || url.scheme == "https" {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Label("Open", systemImage: "safari")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .buttonStyle(.bordered)
                            .tint(.blue)
                        }

                        Button {
                            camera.clearDetectedQR()
                        } label: {
                            Label("Scan Again", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.yellow)
                    }
                }
                .padding(20)
                .background(RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.8)))
                .padding(.bottom, 100)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.3), value: camera.detectedQRString)
    }

    // MARK: - Error

    private func errorView(_ msg: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "video.slash.fill")
                .font(.system(size: 44))
                .foregroundStyle(.white.opacity(0.4))
            Text(msg)
                .foregroundStyle(.white.opacity(0.6))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button("Retry") { camera.startSession() }
                .buttonStyle(.bordered)
                .tint(.white)
        }
    }

    // MARK: - Shutter Logic

    private func shutter() {
        guard !isCountingDown else { return }

        if camera.currentMode.isVideoMode {
            // Video modes: toggle recording
            if camera.isRecording {
                camera.stopRecording()
            } else {
                if timerSeconds > 0 {
                    runCountdown(timerSeconds)
                } else {
                    camera.startRecording()
                }
            }
        } else {
            // Photo / Night mode
            if timerSeconds > 0 {
                runCountdown(timerSeconds)
            } else {
                fire()
            }
        }
    }

    private func runCountdown(_ secs: Int) {
        isCountingDown = true
        countdown = secs
        func tick(_ n: Int) {
            if n <= 0 {
                countdown = nil
                isCountingDown = false
                fire()
                return
            }
            countdown = n
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { tick(n - 1) }
        }
        tick(secs)
    }

    private func fire() {
        if camera.currentMode.isVideoMode {
            camera.startRecording()
        } else if camera.flashEnabled && camera.flashCapability == .torch {
            // Hardware torch flash (e.g. iPhone back camera via Continuity Camera)
            camera.activateTorch()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                self.camera.capturePhoto {
                    self.camera.deactivateTorch()
                }
            }
        } else if camera.flashEnabled && camera.flashCapability == .screen {
            // Screen flash: turn screen white to illuminate face (webcam)
            withAnimation(.easeIn(duration: 0.05)) { showFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.camera.capturePhoto {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        withAnimation(.easeOut(duration: 0.2)) { self.showFlash = false }
                    }
                }
            }
        } else {
            // No flash — quick visual feedback only
            withAnimation(.easeIn(duration: 0.04)) { showFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                withAnimation(.easeOut(duration: 0.15)) { showFlash = false }
            }
            camera.capturePhoto { }
        }
    }
}

// MARK: - Toolbar Pill

private struct ToolbarPill: View {
    var icon: String
    var text: String? = nil
    var active: Bool = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
            if let text {
                Text(text)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(active ? .yellow : .white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            Capsule()
                .fill(active ? Color.yellow.opacity(0.2) : Color.white.opacity(0.1))
        )
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .environment(\.colorScheme, .dark)
        )
    }
}
