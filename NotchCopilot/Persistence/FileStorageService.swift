import Foundation

enum FileStorageError: LocalizedError {
    case missingApplicationSupport

    var errorDescription: String? {
        switch self {
        case .missingApplicationSupport: "Unable to locate Application Support."
        }
    }
}

struct FileStorageService {
    let root: URL
    private let cryptor: LocalDataCryptor
    private let transcriptDirectoryName = "transcripts"

    init(root: URL? = nil, cryptor: LocalDataCryptor = .defaultOrCrash()) throws {
        self.root = try root ?? Self.applicationSupportDirectory()
        self.cryptor = cryptor
        try prepareDirectories()
    }

    static func applicationSupportDirectory() throws -> URL {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw FileStorageError.missingApplicationSupport
        }
        let directory = base.appending(path: "Notch Copilot", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func prepareDirectories() throws {
        for name in ["recordings", "transcripts", "exports", "knowledge"] {
            try FileManager.default.createDirectory(at: root.appending(path: name, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
    }

    func recordingURL(for meetingId: UUID) -> URL {
        root.appending(path: "recordings", directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).caf")
    }

    func exportURL(fileName: String) -> URL {
        root.appending(path: "exports", directoryHint: .isDirectory).appending(path: fileName)
    }

    func writeTranscript(_ session: MeetingSession) throws {
        let url = transcriptURL(for: session.id)
        let legacyURL = legacyTranscriptURL(for: session.id)
        let data = try JSONEncoder().encode(session.transcriptSegments)
        let encrypted = try cryptor.encryptData(data, context: transcriptEncryptionContext(for: session.id))
        try encrypted.write(to: url, options: [.atomic])
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            try FileManager.default.removeItem(at: legacyURL)
        }
    }

    func readTranscript(for meetingId: UUID) throws -> [TranscriptSegment] {
        let encryptedURL = transcriptURL(for: meetingId)
        let legacyURL = legacyTranscriptURL(for: meetingId)
        let url = FileManager.default.fileExists(atPath: encryptedURL.path) ? encryptedURL : legacyURL
        let storedData = try Data(contentsOf: url)
        let data = try cryptor.decryptData(storedData, context: transcriptEncryptionContext(for: meetingId))
        return try JSONDecoder().decode([TranscriptSegment].self, from: data)
    }

    func migrateLegacyTranscriptFiles() throws {
        let directory = root.appending(path: transcriptDirectoryName, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for legacyURL in files where legacyURL.pathExtension == "json" {
            let idString = legacyURL.deletingPathExtension().lastPathComponent
            guard let meetingId = UUID(uuidString: idString) else { continue }
            let encryptedURL = transcriptURL(for: meetingId)
            let storedData = try Data(contentsOf: legacyURL)
            let plaintextData = try cryptor.decryptData(storedData, context: transcriptEncryptionContext(for: meetingId))
            let encryptedData = try cryptor.encryptData(plaintextData, context: transcriptEncryptionContext(for: meetingId))
            try encryptedData.write(to: encryptedURL, options: [.atomic])
            try FileManager.default.removeItem(at: legacyURL)
        }
    }

    func deleteAllLocalData() throws {
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
        try prepareDirectories()
    }

    private func transcriptURL(for meetingId: UUID) -> URL {
        root.appending(path: transcriptDirectoryName, directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).json.ncenc")
    }

    private func legacyTranscriptURL(for meetingId: UUID) -> URL {
        root.appending(path: transcriptDirectoryName, directoryHint: .isDirectory).appending(path: "\(meetingId.uuidString).json")
    }

    private func transcriptEncryptionContext(for meetingId: UUID) -> String {
        "FileStorageService.transcript.\(meetingId.uuidString).v1"
    }
}
