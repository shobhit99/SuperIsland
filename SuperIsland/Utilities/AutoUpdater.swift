import AppKit
import Foundation

@MainActor
final class AutoUpdater: ObservableObject {
    static let shared = AutoUpdater()

    enum State: Equatable {
        case idle
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private var progressObservation: NSKeyValueObservation?
    private init() {}

    func start(downloadURL: URL, releaseURL: URL) {
        guard case .idle = state else { return }
        let appPath = Bundle.main.bundlePath
        Task { await perform(downloadURL: downloadURL, releaseURL: releaseURL, appPath: appPath) }
    }

    private func perform(downloadURL: URL, releaseURL: URL, appPath: String) async {
        do {
            state = .downloading(progress: 0)
            let dmgPath = try await downloadDMG(from: downloadURL)

            state = .installing
            let mountPoint = try await mountDMG(at: dmgPath)

            let appName = URL(fileURLWithPath: appPath).lastPathComponent
            let appInMount = "\(mountPoint)/\(appName)"
            guard FileManager.default.fileExists(atPath: appInMount) else {
                throw UpdateError.appNotFoundInDMG
            }

            try launchReplacementScript(
                src: appInMount,
                dst: appPath,
                mountPoint: mountPoint,
                fallbackURL: releaseURL
            )

            NSApp.terminate(nil)

        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: - Download

    private func downloadDMG(from url: URL) async throws -> String {
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".dmg")

        return try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { [weak self] tempURL, _, error in
                self?.progressObservation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let tempURL else {
                    continuation.resume(throwing: URLError(.badServerResponse))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: dest)
                    continuation.resume(returning: dest.path)
                } catch {
                    continuation.resume(throwing: error)
                }
            }

            progressObservation = task.progress.observe(\.fractionCompleted) { [weak self] p, _ in
                Task { @MainActor [weak self] in
                    self?.state = .downloading(progress: p.fractionCompleted)
                }
            }

            task.resume()
        }
    }

    // MARK: - Mount

    private func mountDMG(at path: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = ["attach", path, "-nobrowse", "-noautoopen"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.terminationHandler = { p in
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                guard p.terminationStatus == 0 else {
                    continuation.resume(throwing: UpdateError.mountFailed)
                    return
                }
                // hdiutil output: "/dev/diskX  HFS+  /Volumes/Name"
                let mountPoint = output
                    .components(separatedBy: "\n")
                    .last(where: { $0.contains("/Volumes/") })?
                    .components(separatedBy: "\t")
                    .last?
                    .trimmingCharacters(in: .whitespaces)

                if let mountPoint, !mountPoint.isEmpty {
                    continuation.resume(returning: mountPoint)
                } else {
                    continuation.resume(throwing: UpdateError.mountFailed)
                }
            }
            try? process.run()
        }
    }

    // MARK: - Replace & Relaunch

    private func launchReplacementScript(src: String, dst: String, mountPoint: String, fallbackURL: URL) throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = """
        #!/bin/bash
        while kill -0 \(pid) 2>/dev/null; do sleep 0.3; done
        if /usr/bin/ditto \"\(src)\" \"\(dst)\"; then
            /usr/bin/hdiutil detach \"\(mountPoint)\" -quiet 2>/dev/null
            sleep 0.3
            open \"\(dst)\"
        else
            /usr/bin/hdiutil detach \"\(mountPoint)\" -quiet 2>/dev/null
            open \"\(fallbackURL.absoluteString)\"
        fi
        rm -- \"$0\"
        """

        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("si-update-\(UUID().uuidString).sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path]
        try process.run()
    }

    // MARK: - Errors

    enum UpdateError: LocalizedError {
        case appNotFoundInDMG
        case mountFailed

        var errorDescription: String? {
            switch self {
            case .appNotFoundInDMG: return "Could not find app in update package."
            case .mountFailed: return "Could not open update package."
            }
        }
    }
}
