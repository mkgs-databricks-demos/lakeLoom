import SwiftUI

#if DEBUG
/// Debug-only screen for poking the capture endpoints against the
/// currently-paired workspace. Each button calls a real
/// ``CaptureAPIClient`` method against dev; the response (or typed
/// error) lands in the scrollable log below.
///
/// Never compiled into Release builds. Mounted as a sheet from
/// ``HomeContainerView`` via a `#if DEBUG` button.
struct EndpointSmokeTestView: View {

    let captureAPI: any CaptureAPIClient
    let uploadCoordinator: (any UploadCoordinator)?
    let photoCapture: (any PhotoCapture)?
    let workspaceID: String
    let projectID: String
    let onDismiss: () -> Void

    @State private var lines: [LogLine] = []
    @State private var lastCaptureID: String?
    /// Tracks which terminal PATCH (cancel / complete) the user has
    /// already issued for `lastCaptureID`. Once set, both PATCH
    /// buttons are disabled — prevents the
    /// `Cannot transition from 'cancelled' to 'completed'` 400 the
    /// server (correctly) returns on the second tap.
    @State private var lastCaptureTerminalState: CaptureSession.EndState?
    @State private var inFlight: String?

    // Audio-upload sub-flow state. The recorder is held by reference
    // so a stop call always sees the start call's instance even if
    // SwiftUI re-renders the view mid-recording.
    @State private var audioRecorder: LiveAudioRecorder?
    @State private var isRecording: Bool = false
    @State private var uploadObserverTask: Task<Void, Never>?

    /// Document-upload sub-flow: toggled when the user taps the
    /// "Pick + upload document" button. The sheet uses
    /// ``DocumentPicker`` which bridges to
    /// `UIDocumentPickerViewController`.
    @State private var showingDocumentPicker: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                contextHeader

                ScrollView {
                    VStack(spacing: 8) {
                        actionButton(
                            "POST /api/projects/:id/captures",
                            systemImage: "plus.circle",
                            tag: "create",
                            action: createCaptureSession
                        )
                        actionButton(
                            "GET /api/projects/:id/captures",
                            systemImage: "list.bullet",
                            tag: "list",
                            action: listCaptures
                        )
                        actionButton(
                            "GET /api/captures/:id",
                            systemImage: "doc.text.magnifyingglass",
                            tag: "get",
                            action: getLastCapture,
                            disabled: lastCaptureID == nil
                        )
                        actionButton(
                            "PATCH /api/captures/:id (cancelled)",
                            systemImage: "xmark.octagon",
                            tag: "cancel",
                            action: cancelLastCapture,
                            disabled: lastCaptureID == nil || lastCaptureTerminalState != nil
                        )
                        actionButton(
                            "PATCH /api/captures/:id (completed)",
                            systemImage: "checkmark.circle",
                            tag: "complete",
                            action: completeLastCapture,
                            disabled: lastCaptureID == nil || lastCaptureTerminalState != nil
                        )

                        Divider()
                            .padding(.vertical, 4)

                        if uploadCoordinator == nil {
                            Text("UploadCoordinator not wired — audio + photo upload disabled.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            actionButton(
                                isRecording ? "Stop + upload audio" : "Start recording audio",
                                systemImage: isRecording ? "stop.circle.fill" : "mic.circle.fill",
                                tag: isRecording ? "audio.stop" : "audio.start",
                                action: isRecording ? stopAndUploadAudio : startRecordingAudio,
                                disabled: lastCaptureID == nil
                            )

                            if photoCapture != nil {
                                actionButton(
                                    "Capture photo + upload",
                                    systemImage: "camera.fill",
                                    tag: "photo",
                                    action: capturePhotoAndUpload,
                                    disabled: lastCaptureID == nil || isRecording
                                )
                            } else {
                                Text("PhotoCapture not wired — photo capture disabled.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            // Documents are project-level — they don't
                            // hang off a capture session. Always
                            // available once UploadCoordinator is wired.
                            actionButton(
                                "Pick + upload document",
                                systemImage: "doc.fill.badge.plus",
                                tag: "document",
                                action: { showingDocumentPicker = true }
                            )

                            actionButton(
                                "Clear failed uploads",
                                systemImage: "trash.slash",
                                tag: "clearfailed",
                                action: clearFailedUploads
                            )

                            if lastCaptureID == nil {
                                Text("Create a capture first to enable audio + photo upload.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Divider()
                            .padding(.vertical, 4)

                        Button(role: .destructive) {
                            lines.removeAll()
                            lastCaptureID = nil
                        } label: {
                            Label("Clear log", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 12)
                }
                .frame(maxHeight: 320)

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(lines.reversed()) { line in
                            LogLineView(line: line)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
            .navigationTitle("DEBUG: Endpoint smoke test")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                }
            }
            .sheet(isPresented: $showingDocumentPicker) {
                DocumentPicker(
                    onPick: { url in
                        showingDocumentPicker = false
                        Task { await uploadDocument(at: url) }
                    },
                    onCancel: {
                        showingDocumentPicker = false
                        append(.start("DOC", "picker.cancelled", ""))
                    }
                )
            }
        }
    }

    private var contextHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Workspace: \(workspaceID)")
                .font(.caption.monospaced())
            Text("Project: \(projectID)")
                .font(.caption.monospaced())
            if let lastCaptureID {
                Text("Last capture: \(lastCaptureID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(uiColor: .secondarySystemBackground))
    }

    @ViewBuilder
    private func actionButton(
        _ title: String,
        systemImage: String,
        tag: String,
        action: @escaping () async -> Void,
        disabled: Bool = false
    ) -> some View {
        Button {
            Task {
                inFlight = tag
                await action()
                inFlight = nil
            }
        } label: {
            HStack {
                if inFlight == tag {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: systemImage)
                }
                Text(title)
                    .font(.system(.callout, design: .monospaced))
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderedProminent)
        .disabled(disabled || inFlight != nil)
    }

    // MARK: - Endpoint actions

    private func createCaptureSession() async {
        let label = "smoke test \(shortTimestamp())"
        append(.start("POST", "/api/projects/\(projectID)/captures", "label=\(label)"))
        do {
            let session = try await captureAPI.createCaptureSession(
                workspaceID: workspaceID,
                projectID: projectID,
                label: label,
                clientTimestamp: Date()
            )
            lastCaptureID = session.id
            // Fresh capture session resets the cancel/complete mutex
            // so the next PATCH can fire.
            lastCaptureTerminalState = nil
            append(.ok("POST", session.id, "state=\(session.state.rawValue)"))
        } catch let error as CaptureAPIError {
            append(.fail("POST", String(describing: error)))
        } catch {
            append(.fail("POST", error.localizedDescription))
        }
    }

    private func listCaptures() async {
        append(.start("GET", "/api/projects/\(projectID)/captures", "limit=20"))
        do {
            let captures = try await captureAPI.listProjectCaptureSessions(
                workspaceID: workspaceID,
                projectID: projectID,
                state: nil,
                limit: 20,
                before: nil
            )
            let summary = captures
                .prefix(5)
                .map { "  - \($0.id.prefix(8)) \($0.state.rawValue)" }
                .joined(separator: "\n")
            append(.ok("GET", "\(captures.count) captures", summary.isEmpty ? "(none)" : summary))
        } catch let error as CaptureAPIError {
            append(.fail("GET", String(describing: error)))
        } catch {
            append(.fail("GET", error.localizedDescription))
        }
    }

    private func getLastCapture() async {
        guard let id = lastCaptureID else { return }
        append(.start("GET", "/api/captures/\(id)", "include=uploads"))
        do {
            let session = try await captureAPI.getCaptureSession(
                workspaceID: workspaceID,
                captureSessionID: id,
                includeUploads: true
            )
            let uploadInfo = session.uploads
                .map { "uploads=\($0.count)" } ?? "uploads=nil"
            append(.ok("GET", session.id, "state=\(session.state.rawValue) \(uploadInfo)"))
        } catch let error as CaptureAPIError {
            append(.fail("GET", String(describing: error)))
        } catch {
            append(.fail("GET", error.localizedDescription))
        }
    }

    private func cancelLastCapture() async {
        await patchLastCapture(to: .cancelled)
    }

    private func completeLastCapture() async {
        await patchLastCapture(to: .completed)
    }

    private func patchLastCapture(to state: CaptureSession.EndState) async {
        guard let id = lastCaptureID else { return }
        append(.start("PATCH", "/api/captures/\(id)", "state=\(state.rawValue)"))
        do {
            let session = try await captureAPI.updateCaptureSession(
                workspaceID: workspaceID,
                captureSessionID: id,
                state: state,
                endedAt: Date()
            )
            lastCaptureTerminalState = state
            append(.ok("PATCH", session.id, "state=\(session.state.rawValue)"))
        } catch let error as CaptureAPIError {
            append(.fail("PATCH", String(describing: error)))
        } catch {
            append(.fail("PATCH", error.localizedDescription))
        }
    }

    // MARK: - Photo capture + upload

    private func capturePhotoAndUpload() async {
        guard let captureID = lastCaptureID,
              let photoCapture,
              let uploads = uploadCoordinator else { return }

        append(.start("PHOTO", "capture.attempt", "capture=\(captureID.prefix(8))…"))
        let photo: CapturedPhoto
        do {
            photo = try await photoCapture.capturePhoto(captureSessionID: captureID)
        } catch let error as PhotoCaptureError {
            append(.fail("PHOTO", "capture: \(String(describing: error))"))
            return
        } catch {
            append(.fail("PHOTO", "capture: \(error.localizedDescription)"))
            return
        }
        append(.ok("PHOTO", "captured", "bytes=\(photo.sizeBytes) url=\(photo.fileURL.lastPathComponent)"))

        let sha: String
        do {
            sha = try FileSHA256.hex(of: photo.fileURL)
        } catch {
            append(.fail("PHOTO", "sha256: \(error.localizedDescription)"))
            return
        }
        let uploadID = UUID().uuidString
        let pending = PendingUpload(
            id: uploadID,
            workspaceID: workspaceID,
            captureSessionID: captureID,
            kind: .photo,
            localFileURL: photo.fileURL,
            mimeType: photo.mimeType,
            sizeBytes: photo.sizeBytes,
            sha256Hex: sha,
            clientTimestamp: photo.capturedAt,
            originalFilename: photo.fileURL.lastPathComponent,
            createdAt: Date()
        )
        append(.start("PHOTO", "upload.enqueue", "id=\(uploadID.prefix(8))… sha=\(sha.prefix(8))…"))
        do {
            try await uploads.enqueue(pending)
        } catch let error as UploadCoordinatorError {
            append(.fail("PHOTO", "enqueue: \(String(describing: error))"))
            return
        } catch {
            append(.fail("PHOTO", "enqueue: \(error.localizedDescription)"))
            return
        }
        // Reuse the same upload observer pattern as audio.
        observeUpload(uploadID: uploadID, tag: "PHOTO", coordinator: uploads)
    }

    // MARK: - Document upload

    /// Picked-file URL is security-scoped; copy bytes into a stable
    /// Application Support location before enqueueing so the upload
    /// coordinator's worker (which runs later, asynchronously) can
    /// read the file without the scoped lifetime constraint.
    private func uploadDocument(at sourceURL: URL) async {
        guard let uploads = uploadCoordinator else { return }

        append(.start("DOC", "picker.picked", sourceURL.lastPathComponent))

        // Start scoped access just long enough to copy the bytes.
        let granted = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if granted {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let localURL: URL
        do {
            localURL = try copyPickedDocumentToAppSupport(sourceURL: sourceURL)
        } catch {
            append(.fail("DOC", "copy: \(error.localizedDescription)"))
            return
        }

        // Hash the copied bytes (the picked URL might be gone by the
        // time the upload worker actually reads it, so always hash
        // from the local copy).
        let sha: String
        let sizeBytes: Int64
        do {
            sha = try FileSHA256.hex(of: localURL)
            let attrs = try FileManager.default.attributesOfItem(atPath: localURL.path)
            sizeBytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        } catch {
            append(.fail("DOC", "sha256: \(error.localizedDescription)"))
            return
        }

        let mimeType = mimeType(forExtension: localURL.pathExtension)
        let uploadID = UUID().uuidString
        let pending = PendingUpload(
            id: uploadID,
            workspaceID: workspaceID,
            // For documents we tag captureSessionID = projectID so
            // logs and queue persistence stay homogeneous. The wire
            // path is computed from `projectID` directly inside
            // `PendingUpload.endpointPath()`.
            captureSessionID: projectID,
            projectID: projectID,
            kind: .document,
            localFileURL: localURL,
            mimeType: mimeType,
            sizeBytes: sizeBytes,
            sha256Hex: sha,
            clientTimestamp: Date(),
            originalFilename: sourceURL.lastPathComponent,
            createdAt: Date()
        )

        append(.start(
            "DOC",
            "upload.enqueue",
            "id=\(uploadID.prefix(8))… mime=\(mimeType) bytes=\(sizeBytes) sha=\(sha.prefix(8))…"
        ))
        do {
            try await uploads.enqueue(pending)
        } catch let error as UploadCoordinatorError {
            append(.fail("DOC", "enqueue: \(String(describing: error))"))
            return
        } catch {
            append(.fail("DOC", "enqueue: \(error.localizedDescription)"))
            return
        }

        observeUpload(uploadID: uploadID, tag: "DOC", coordinator: uploads)
    }

    /// Copies the picked file into `<Application Support>/Documents/`
    /// so the file is available after the picker's security-scoped
    /// access ends. Uses the original filename + a UUID suffix to
    /// avoid collisions across multiple uploads of the same file.
    private func copyPickedDocumentToAppSupport(sourceURL: URL) throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let ext = sourceURL.pathExtension.isEmpty ? "pdf" : sourceURL.pathExtension
        let target = dir.appendingPathComponent(
            "\(baseName)-\(UUID().uuidString.prefix(8)).\(ext)",
            isDirectory: false
        )
        // `replaceItemAt` would be nicer for atomicity but we don't
        // have an existing target file by construction. `copyItem` is
        // safer than `moveItem` because the source may be a
        // sandboxed URL we don't own.
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.copyItem(at: sourceURL, to: target)
        return target
    }

    /// Server allowlist: PDF + DOCX. Map iOS extensions to the right
    /// MIME types so the multipart `Content-Type` part header is
    /// accepted by `parseMultipart` on the server.
    private func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "pdf":  return "application/pdf"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        default:     return "application/octet-stream"
        }
    }

    // MARK: - Clear failed uploads

    private func clearFailedUploads() async {
        guard let uploads = uploadCoordinator else { return }
        let snapshot = await uploads.currentUploads()
        let failed = snapshot.filter {
            if case .failed = $0.state { return true }
            return false
        }
        guard !failed.isEmpty else {
            append(.ok("QUEUE", "clear", "no failed uploads"))
            return
        }
        append(.start("QUEUE", "clear", "count=\(failed.count)"))
        for upload in failed {
            await uploads.discard(uploadID: upload.id)
        }
        append(.ok("QUEUE", "cleared", "discarded=\(failed.count)"))
    }

    // MARK: - Audio record + upload

    private func startRecordingAudio() async {
        guard let captureID = lastCaptureID else { return }
        let recorder = LiveAudioRecorder()
        audioRecorder = recorder
        append(.start("AUDIO", "recorder.start", "capture=\(captureID.prefix(8))…"))
        do {
            let url = try await recorder.start(captureSessionID: captureID)
            isRecording = true
            append(.ok("AUDIO", "recording", url.lastPathComponent))
        } catch let error as AudioRecorderError {
            audioRecorder = nil
            append(.fail("AUDIO", "recorder.start: \(String(describing: error))"))
        } catch {
            audioRecorder = nil
            append(.fail("AUDIO", "recorder.start: \(error.localizedDescription)"))
        }
    }

    private func stopAndUploadAudio() async {
        guard let recorder = audioRecorder, let captureID = lastCaptureID,
              let uploads = uploadCoordinator else { return }

        // Stop the recorder.
        let recording: AudioRecording
        do {
            recording = try await recorder.stop()
        } catch let error as AudioRecorderError {
            isRecording = false
            audioRecorder = nil
            append(.fail("AUDIO", "recorder.stop: \(String(describing: error))"))
            return
        } catch {
            isRecording = false
            audioRecorder = nil
            append(.fail("AUDIO", "recorder.stop: \(error.localizedDescription)"))
            return
        }
        isRecording = false
        audioRecorder = nil
        append(.ok(
            "AUDIO",
            "stopped",
            "duration=\(String(format: "%.2f", recording.durationSeconds))s bytes=\(recording.sizeBytes)"
        ))

        // Hash + enqueue.
        let sha: String
        do {
            sha = try FileSHA256.hex(of: recording.fileURL)
        } catch {
            append(.fail("AUDIO", "sha256: \(error.localizedDescription)"))
            return
        }
        let uploadID = UUID().uuidString
        let pending = PendingUpload(
            id: uploadID,
            workspaceID: workspaceID,
            captureSessionID: captureID,
            kind: .audio,
            localFileURL: recording.fileURL,
            mimeType: recording.mimeType,
            sizeBytes: recording.sizeBytes,
            sha256Hex: sha,
            clientTimestamp: recording.startedAt,
            originalFilename: recording.fileURL.lastPathComponent,
            createdAt: Date()
        )
        append(.start("AUDIO", "upload.enqueue", "id=\(uploadID.prefix(8))… sha=\(sha.prefix(8))…"))
        do {
            try await uploads.enqueue(pending)
        } catch let error as UploadCoordinatorError {
            append(.fail("AUDIO", "enqueue: \(String(describing: error))"))
            return
        } catch {
            append(.fail("AUDIO", "enqueue: \(error.localizedDescription)"))
            return
        }

        observeUpload(uploadID: uploadID, tag: "AUDIO", coordinator: uploads)
    }

    // MARK: - Upload observer (shared by audio + photo)

    /// Spawns a Task that watches the upload coordinator's stream
    /// for this upload's terminal state. Cancels any previously-
    /// running observer; the smoke-test sheet only observes one
    /// upload at a time.
    private func observeUpload(
        uploadID: String,
        tag: String,
        coordinator: any UploadCoordinator
    ) {
        uploadObserverTask?.cancel()
        uploadObserverTask = Task {
            let stream = await coordinator.stateUpdates()
            for await change in stream {
                if Task.isCancelled { return }
                guard change.uploadID == uploadID else { continue }
                await MainActor.run {
                    switch change.state {
                    case .queued:
                        append(.start(tag, "upload.queued", "id=\(uploadID.prefix(8))…"))
                    case .uploading:
                        append(.start(tag, "upload.uploading", "id=\(uploadID.prefix(8))…"))
                    case .succeeded:
                        append(.ok(tag, "upload.succeeded", "id=\(uploadID.prefix(8))…"))
                    case .failed(let reason, let permanent):
                        append(.fail(tag, "upload.failed permanent=\(permanent) reason=\(reason)"))
                    }
                }
                if change.state == .succeeded { return }
                if case .failed(_, true) = change.state { return }
            }
        }
    }

    // MARK: - Log helpers

    private func append(_ line: LogLine) {
        lines.append(line)
    }

    private func shortTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}

// MARK: - Log model

private struct LogLine: Identifiable, Equatable {
    let id = UUID()
    let timestamp = Date()
    let level: Level
    let header: String
    let detail: String

    enum Level {
        case start, ok, fail

        var color: Color {
            switch self {
            case .start: return .secondary
            case .ok:    return .green
            case .fail:  return .red
            }
        }

        var icon: String {
            switch self {
            case .start: return "arrow.up.right"
            case .ok:    return "checkmark"
            case .fail:  return "xmark"
            }
        }
    }

    static func start(_ method: String, _ path: String, _ detail: String) -> LogLine {
        LogLine(level: .start, header: "\(method) \(path)", detail: detail)
    }

    static func ok(_ method: String, _ header: String, _ detail: String) -> LogLine {
        LogLine(level: .ok, header: "\(method) → \(header)", detail: detail)
    }

    static func fail(_ method: String, _ detail: String) -> LogLine {
        LogLine(level: .fail, header: "\(method) failed", detail: detail)
    }
}

private struct LogLineView: View {
    let line: LogLine

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: line.level.icon)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(line.level.color)
                Text(timestampString)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                Text(line.header)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(line.level.color)
                Spacer()
            }
            if !line.detail.isEmpty {
                Text(line.detail)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.leading, 18)
            }
        }
        .padding(8)
        .background(Color(uiColor: .systemBackground), in: RoundedRectangle(cornerRadius: 6))
    }

    private var timestampString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: line.timestamp)
    }
}
#endif
