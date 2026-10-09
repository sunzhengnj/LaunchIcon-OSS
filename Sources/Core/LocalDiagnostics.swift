import Foundation

public enum LocalDiagnostics {
    private static let appendLock = NSLock()
    private static let maximumLogBytes = 1_048_576

    public static func fileURL(for bundleIdentifier: String) -> URL {
        if let overridePath = ProcessInfo.processInfo.environment["LAUNCHICON_DIAGNOSTICS_PATH"], !overridePath.isEmpty {
            return URL(fileURLWithPath: overridePath)
        }
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "LaunchIcon/Diagnostics", directoryHint: .isDirectory)
        return directory.appending(path: "\(bundleIdentifier).log")
    }

    public static func keepsUserEvidenceUntouched(_ environment: [String: String]) -> Bool {
        func isSet(_ key: String) -> Bool {
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return !value.isEmpty
        }
        return isSet("LAUNCHICON_TEST_LAYOUT_PATH") || isSet("LAUNCHICON_TEST_PREFERENCES_SUITE")
    }

    public static func appendEvidence(
        _ line: String,
        environment: [String: String],
        defaults: UserDefaults,
        bundleIdentifier: String
    ) {
        if keepsUserEvidenceUntouched(environment) {
            if let path = environment["LAUNCHICON_DIAGNOSTICS_PATH"], !path.isEmpty {
                append(line, to: URL(fileURLWithPath: path))
            }
            return
        }
        var evidence = defaults.stringArray(forKey: "M0SpikeEvidence") ?? []
        evidence.append(line)
        defaults.set(Array(evidence.suffix(50)), forKey: "M0SpikeEvidence")
        append(line, bundleIdentifier: bundleIdentifier)
    }

    public static func append(_ line: String, bundleIdentifier: String) {
        append(line, to: fileURL(for: bundleIdentifier))
    }

    private static func append(_ line: String, to url: URL) {
        appendLock.lock()
        defer { appendLock.unlock() }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let record = "\(ISO8601DateFormatter().string(from: .now)) \(line)\n"
            let fullRecordData = Data(record.utf8)
            let recordData: Data
            if fullRecordData.count > maximumLogBytes {
                let marker = Data("[truncated]\n".utf8)
                var prefixCount = maximumLogBytes - marker.count
                while prefixCount > 0,
                      prefixCount < fullRecordData.count,
                      (fullRecordData[prefixCount] & 0xC0) == 0x80 {
                    prefixCount -= 1
                }
                var boundedRecord = Data(fullRecordData.prefix(prefixCount))
                boundedRecord.append(marker)
                recordData = boundedRecord
            } else {
                recordData = fullRecordData
            }
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forUpdating: url)
                let existingSize = try handle.seekToEnd()
                let maximumSize = UInt64(maximumLogBytes)
                if existingSize + UInt64(recordData.count) <= maximumSize {
                    try handle.write(contentsOf: recordData)
                    try handle.close()
                    return
                }

                let retainedLimit = maximumSize / 2
                let bytesToKeep = retainedLimit - min(retainedLimit, UInt64(recordData.count))
                let startOffset = existingSize > bytesToKeep ? existingSize - bytesToKeep : 0
                try handle.seek(toOffset: startOffset)
                var retained = try handle.readToEnd() ?? Data()
                try handle.close()
                if startOffset > 0 {
                    if let firstLineBreak = retained.firstIndex(of: 0x0A) {
                        retained = Data(retained.suffix(from: retained.index(after: firstLineBreak)))
                    } else {
                        retained.removeAll()
                    }
                }
                retained.append(recordData)
                try retained.write(to: url, options: .atomic)
            } else {
                try recordData.write(to: url, options: .atomic)
            }
        } catch {
            NSLog("LaunchIcon diagnostics write failed: %@", error.localizedDescription)
        }
    }
}
