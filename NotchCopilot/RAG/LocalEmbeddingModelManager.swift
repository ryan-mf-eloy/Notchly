import Foundation

#if canImport(CoreML)
import CoreML
#endif

#if canImport(HuggingFace)
import HuggingFace
#endif

#if canImport(Metal)
import Metal
#endif

#if canImport(MLXEmbedders) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLX) && canImport(Tokenizers)
import MLX
import MLXEmbedders
import MLXHuggingFace
import MLXLMCommon
import Tokenizers
#endif

struct LocalEmbeddingModelDescriptor: Codable, Hashable, Sendable {
    var tier: LocalEmbeddingTier
    var runtime: LocalEmbeddingRuntimeKind
    var displayName: String
    var modelIdentifier: String
    var directoryName: String
    var minimumBytes: Int64
    var dimensions: Int
    var contextTokens: Int
    var quantization: String
}

struct LocalCoreMLEmbeddingManifest: Codable, Hashable, Sendable {
    static let fileName = "notchly-coreml-embedding.json"

    var modelFileName: String
    var inputName: String
    var outputName: String
    var dimensions: Int
    var maxCharacters: Int
    var normalizeOutput: Bool

    init(
        modelFileName: String = "Embedding.mlmodelc",
        inputName: String = "text",
        outputName: String = "embedding",
        dimensions: Int,
        maxCharacters: Int = 4_096,
        normalizeOutput: Bool = true
    ) {
        self.modelFileName = modelFileName
        self.inputName = inputName
        self.outputName = outputName
        self.dimensions = dimensions
        self.maxCharacters = maxCharacters
        self.normalizeOutput = normalizeOutput
    }
}

struct LocalCoreMLEmbeddingPackage: Hashable, Sendable {
    var descriptor: LocalEmbeddingModelDescriptor
    var directoryURL: URL
    var modelURL: URL
    var manifest: LocalCoreMLEmbeddingManifest
}

struct LocalEmbeddingModelManager {
    var fileManager: FileManager = .default
    var modelsRootOverride: URL?

    func descriptor(tier: LocalEmbeddingTier, runtime: LocalEmbeddingRuntimeKind) -> LocalEmbeddingModelDescriptor? {
        let profile = tier.modelProfile
        switch runtime {
        case .coreML:
            switch tier {
            case .fast:
                return LocalEmbeddingModelDescriptor(
                    tier: tier,
                    runtime: runtime,
                    displayName: "Qwen3 Embedding 0.6B Core ML",
                    modelIdentifier: "notchly-coreml-qwen3-embedding-0_6b",
                    directoryName: "qwen3-embedding-0_6b-coreml-mlprogram",
                    minimumBytes: 1,
                    dimensions: profile.dimensions,
                    contextTokens: profile.contextTokens,
                    quantization: profile.defaultQuantization
                )
            case .balanced:
                return LocalEmbeddingModelDescriptor(
                    tier: tier,
                    runtime: runtime,
                    displayName: "BGE-M3 Core ML",
                    modelIdentifier: "notchly-coreml-bge-m3",
                    directoryName: "bge-m3-coreml-mlprogram",
                    minimumBytes: 1,
                    dimensions: profile.dimensions,
                    contextTokens: profile.contextTokens,
                    quantization: profile.defaultQuantization
                )
            case .advanced:
                return LocalEmbeddingModelDescriptor(
                    tier: tier,
                    runtime: runtime,
                    displayName: "Qwen3 Embedding 4B Core ML",
                    modelIdentifier: "notchly-coreml-qwen3-embedding-4b",
                    directoryName: "qwen3-embedding-4b-coreml-mlprogram",
                    minimumBytes: 1,
                    dimensions: profile.dimensions,
                    contextTokens: profile.contextTokens,
                    quantization: profile.defaultQuantization
                )
            }
        case .mlx:
            switch tier {
            case .fast:
                return LocalEmbeddingModelDescriptor(
                    tier: tier,
                    runtime: runtime,
                    displayName: "Qwen3 Embedding 0.6B MLX 4-bit",
                    modelIdentifier: "mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ",
                    directoryName: "qwen3-embedding-0_6b-mlx-4bit-dwq",
                    minimumBytes: 280 * 1024 * 1024,
                    dimensions: profile.dimensions,
                    contextTokens: profile.contextTokens,
                    quantization: "4bit-dwq"
                )
            case .balanced:
                return LocalEmbeddingModelDescriptor(
                    tier: tier,
                    runtime: runtime,
                    displayName: "BGE-M3 MLX",
                    modelIdentifier: "BAAI/bge-m3",
                    directoryName: "bge-m3-mlx",
                    minimumBytes: 450 * 1024 * 1024,
                    dimensions: profile.dimensions,
                    contextTokens: profile.contextTokens,
                    quantization: profile.defaultQuantization
                )
            case .advanced:
                return LocalEmbeddingModelDescriptor(
                    tier: tier,
                    runtime: runtime,
                    displayName: "Qwen3 Embedding 4B MLX",
                    modelIdentifier: "Qwen/Qwen3-Embedding-4B",
                    directoryName: "qwen3-embedding-4b-mlx",
                    minimumBytes: 2_500 * 1024 * 1024,
                    dimensions: profile.dimensions,
                    contextTokens: profile.contextTokens,
                    quantization: profile.defaultQuantization
                )
            }
        default:
            return nil
        }
    }

    func resolvedRuntime(
        tier: LocalEmbeddingTier,
        requested: LocalEmbeddingRuntimeKind,
        allowDownloads: Bool,
        allowMetalAcceleration: Bool = true
    ) -> LocalEmbeddingRuntimeKind {
        switch requested {
        case .automatic:
            let preferred = tier.modelProfile.preferredRuntime
            for runtime in [preferred, .coreML, .mlx] where isUsable(
                tier: tier,
                runtime: runtime,
                allowDownloads: allowDownloads,
                allowMetalAcceleration: allowMetalAcceleration
            ) {
                return runtime
            }
            return .naturalLanguageHybrid
        case .coreML:
            return isUsable(
                tier: tier,
                runtime: .coreML,
                allowDownloads: allowDownloads,
                allowMetalAcceleration: allowMetalAcceleration
            )
                ? .coreML
                : .naturalLanguageHybrid
        case .mlx:
            return isUsable(
                tier: tier,
                runtime: .mlx,
                allowDownloads: allowDownloads,
                allowMetalAcceleration: allowMetalAcceleration
            )
                ? .mlx
                : .naturalLanguageHybrid
        case .localServer:
            return .localServer
        case .naturalLanguageHybrid:
            return .naturalLanguageHybrid
        case .featureHash:
            return .featureHash
        }
    }

    func isUsable(
        tier: LocalEmbeddingTier,
        runtime: LocalEmbeddingRuntimeKind,
        allowDownloads: Bool,
        allowMetalAcceleration: Bool = true
    ) -> Bool {
        guard let descriptor = descriptor(tier: tier, runtime: runtime) else { return false }
        switch runtime {
        case .coreML:
            guard Self.isCoreMLRuntimeLinked,
                  let package = coreMLPackage(for: descriptor) else { return false }
            return isCoreMLPackageLoadable(package)
        case .mlx:
            guard allowMetalAcceleration,
                  Self.supportsMetalAcceleration,
                  Self.isMLXEmbeddingRuntimeLinked else { return false }
            return allowDownloads || availableLocalDirectory(for: descriptor) != nil
        default:
            return false
        }
    }

    func availableLocalDirectory(for descriptor: LocalEmbeddingModelDescriptor) -> URL? {
        if descriptor.runtime == .coreML {
            return coreMLPackage(for: descriptor)?.directoryURL
        }
        if let url = try? localModelDirectory(for: descriptor, create: false),
           hasEnoughModelFiles(at: url, minimumBytes: descriptor.minimumBytes) {
            return url
        }

        #if canImport(HuggingFace)
        if let repo = Repo.ID(rawValue: descriptor.modelIdentifier) {
            let cacheDirectory = HubCache.default.repoDirectory(repo: repo, kind: .model)
            if hasEnoughModelFiles(at: cacheDirectory, minimumBytes: descriptor.minimumBytes) {
                return cacheDirectory
            }
        }
        #endif

        return nil
    }

    func coreMLPackage(tier: LocalEmbeddingTier) -> LocalCoreMLEmbeddingPackage? {
        guard let descriptor = descriptor(tier: tier, runtime: .coreML) else { return nil }
        return coreMLPackage(for: descriptor)
    }

    func coreMLPackage(for descriptor: LocalEmbeddingModelDescriptor) -> LocalCoreMLEmbeddingPackage? {
        guard descriptor.runtime == .coreML,
              let directory = try? localModelDirectory(for: descriptor, create: false) else { return nil }
        let manifestURL = directory.appendingPathComponent(LocalCoreMLEmbeddingManifest.fileName)
        guard let data = try? Data(contentsOf: manifestURL),
              var manifest = try? JSONDecoder().decode(LocalCoreMLEmbeddingManifest.self, from: data) else { return nil }
        manifest.dimensions = min(max(manifest.dimensions, 1), 8_192)
        let modelURL = directory.appendingPathComponent(manifest.modelFileName, isDirectory: true)
        guard fileManager.fileExists(atPath: modelURL.path) else { return nil }
        return LocalCoreMLEmbeddingPackage(
            descriptor: descriptor,
            directoryURL: directory,
            modelURL: modelURL,
            manifest: manifest
        )
    }

    func modelDirectory(for descriptor: LocalEmbeddingModelDescriptor) throws -> URL {
        try localModelDirectory(for: descriptor, create: true)
    }

    private func localModelDirectory(for descriptor: LocalEmbeddingModelDescriptor, create: Bool) throws -> URL {
        let directory = try modelsRoot(create: create)
            .appendingPathComponent(descriptor.runtime.storageSuffix, isDirectory: true)
            .appendingPathComponent(descriptor.directoryName, isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    func statusText(
        tier: LocalEmbeddingTier,
        runtime: LocalEmbeddingRuntimeKind,
        allowDownloads: Bool,
        allowMetalAcceleration: Bool = true
    ) -> String {
        guard let descriptor = descriptor(tier: tier, runtime: runtime),
              runtime == .mlx || runtime == .coreML else {
            return "\(runtime.displayName) fallback ready"
        }
        if runtime == .mlx, !allowMetalAcceleration {
            return "\(descriptor.displayName) disabled by Apple Metal setting"
        }
        if runtime == .mlx, !Self.supportsMetalAcceleration {
            return "\(descriptor.displayName) requires Apple Metal"
        }
        if runtime == .coreML,
           let package = coreMLPackage(for: descriptor) {
            return isCoreMLPackageLoadable(package)
                ? "\(descriptor.displayName) ready"
                : "\(descriptor.displayName) installed but cannot load"
        }
        if runtime == .mlx, availableLocalDirectory(for: descriptor) != nil {
            return "\(descriptor.displayName) ready"
        }
        if runtime == .mlx, allowDownloads {
            return "\(descriptor.displayName) can download on first use"
        }
        return "\(descriptor.displayName) not installed"
    }

    private func modelsRoot(create: Bool) throws -> URL {
        let directory: URL
        if let modelsRootOverride {
            directory = modelsRootOverride
        } else {
            directory = try FileStorageService.applicationSupportDirectory()
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("embeddings", isDirectory: true)
        }
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    private func hasEnoughModelFiles(at url: URL, minimumBytes: Int64) -> Bool {
        guard let size = directorySize(url) else { return false }
        return size >= minimumBytes
    }

    private func directorySize(_ url: URL) -> Int64? {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return nil
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        return total
    }

    static var isMLXEmbeddingRuntimeLinked: Bool {
        #if canImport(MLXEmbedders) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLX) && canImport(Tokenizers)
        true
        #else
        false
        #endif
    }

    static var isCoreMLRuntimeLinked: Bool {
        #if canImport(CoreML)
        true
        #else
        false
        #endif
    }

    static var supportsMetalAcceleration: Bool {
        #if canImport(Metal)
        MTLCreateSystemDefaultDevice() != nil
        #else
        false
        #endif
    }

    private func isCoreMLPackageLoadable(_ package: LocalCoreMLEmbeddingPackage) -> Bool {
        #if canImport(CoreML)
        let cacheKey = [
            package.modelURL.path,
            coreMLPackageFingerprint(package.modelURL),
            package.manifest.inputName,
            package.manifest.outputName,
            "\(package.manifest.dimensions)"
        ].joined(separator: "|")
        Self.coreMLLoadabilityLock.lock()
        if let cached = Self.coreMLLoadabilityCache[cacheKey] {
            Self.coreMLLoadabilityLock.unlock()
            return cached
        }
        Self.coreMLLoadabilityLock.unlock()

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        let isLoadable = (try? MLModel(contentsOf: package.modelURL, configuration: configuration)) != nil

        Self.coreMLLoadabilityLock.lock()
        Self.coreMLLoadabilityCache[cacheKey] = isLoadable
        Self.coreMLLoadabilityLock.unlock()
        return isLoadable
        #else
        return false
        #endif
    }

    private func coreMLPackageFingerprint(_ url: URL) -> String {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else {
            return "missing"
        }
        var latestModification: TimeInterval = 0
        var totalSize: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            latestModification = max(latestModification, values?.contentModificationDate?.timeIntervalSince1970 ?? 0)
            totalSize += Int64(values?.fileSize ?? 0)
        }
        return "\(Int(latestModification))-\(totalSize)"
    }

    private static let coreMLLoadabilityLock = NSLock()
    nonisolated(unsafe) private static var coreMLLoadabilityCache: [String: Bool] = [:]
}

#if canImport(MLXEmbedders) && canImport(MLXHuggingFace) && canImport(MLXLMCommon) && canImport(MLX) && canImport(Tokenizers)
actor LocalMLXEmbeddingRuntime {
    static let shared = LocalMLXEmbeddingRuntime()

    private var cachedModelIdentifier: String?
    private var cachedContainer: EmbedderModelContainer?

    func embed(
        texts: [String],
        descriptor: LocalEmbeddingModelDescriptor,
        localDirectory: URL?,
        allowDownloads: Bool
    ) async throws -> [[Double]] {
        let container = try await container(
            descriptor: descriptor,
            localDirectory: localDirectory,
            allowDownloads: allowDownloads
        )
        return try await container.perform { context in
            let padId = context.tokenizer.eosTokenId ?? 0
            let encoded = texts.map { context.tokenizer.encode(text: $0, addSpecialTokens: true) }
            let maxLength = max(8, encoded.map(\.count).max() ?? 8)
            let padded = stacked(encoded.map { tokens in
                MLXArray(tokens + Array(repeating: padId, count: maxLength - tokens.count))
            })
            let mask = (padded .!= padId)
            let tokenTypes = MLXArray.zeros(like: padded)
            let output = context.model(
                padded,
                positionIds: nil,
                tokenTypeIds: tokenTypes,
                attentionMask: mask
            )
            let pooled = context.pooling(
                output,
                mask: mask,
                normalize: true,
                applyLayerNorm: true
            )
            pooled.eval()
            return pooled.map { row in
                row.asArray(Float.self).map(Double.init)
            }
        }
    }

    private func container(
        descriptor: LocalEmbeddingModelDescriptor,
        localDirectory: URL?,
        allowDownloads: Bool
    ) async throws -> EmbedderModelContainer {
        if let cachedContainer, cachedModelIdentifier == descriptor.modelIdentifier {
            return cachedContainer
        }

        let container: EmbedderModelContainer
        if let localDirectory {
            container = try await EmbedderModelFactory.shared.loadContainer(
                from: localDirectory,
                using: #huggingFaceTokenizerLoader()
            )
        } else if allowDownloads {
            container = try await EmbedderModelFactory.shared.loadContainer(
                from: #hubDownloader(),
                using: #huggingFaceTokenizerLoader(),
                configuration: ModelConfiguration(id: descriptor.modelIdentifier)
            )
        } else {
            throw CocoaError(.fileNoSuchFile)
        }

        cachedModelIdentifier = descriptor.modelIdentifier
        cachedContainer = container
        return container
    }
}
#endif
