import Foundation
import OSLog

struct AirbagSettings: Codable {
    let allowFileReads: Bool
    let workspace: String?
    let allowFileWrites: Bool
    let allowNetwork: Bool

    init(allowFileReads: Bool, allowFileWrites: Bool, allowNetwork: Bool, workspace: String?) {
        self.allowFileReads = allowFileReads
        self.allowFileWrites = allowFileWrites
        self.allowNetwork = allowNetwork
        self.workspace = workspace
    }

    static let defaults = AirbagSettings(
        allowFileReads: true, allowFileWrites: false, allowNetwork: false, workspace: nil
    )

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let knownKeys: Set<String> = ["allowFileReads", "allowFileWrites", "allowNetwork", "workspace"]
        for key in values.allKeys where !knownKeys.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: values, debugDescription: "Unknown setting '\(key.stringValue)'."
            )
        }
        // Older configuration files keep their existing read behavior.
        allowFileReads = try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "allowFileReads")) ?? true
        workspace = try values.decodeIfPresent(String.self, forKey: Key(stringValue: "workspace"))
        allowFileWrites = try values.decode(Bool.self, forKey: Key(stringValue: "allowFileWrites"))
        allowNetwork = try values.decode(Bool.self, forKey: Key(stringValue: "allowNetwork"))
    }

    /// Loads settings before sandbox activation, creating defaults only when the file is absent.
    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        AirbagLog.configuration.debug("Loading global settings")
        let directory = try configurationDirectory(environment: environment)
        let file = directory.appendingPathComponent("config.json")
        if !FileManager.default.fileExists(atPath: file.path) {
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.toml").path) else {
                throw SettingsError("Found legacy config.toml; convert it to config.json before running commands.")
            }
            try createDefaults(at: file, directory: directory)
        }
        AirbagLog.configuration.debug("Reading global configuration from \(file.path, privacy: .public)")
        do {
            let settings = try JSONDecoder().decode(Self.self, from: Data(contentsOf: file))
            AirbagLog.configuration.debug("Global settings loaded")
            return settings
        } catch {
            throw SettingsError("Cannot read \(file.path): \(error)")
        }
    }

    static func configurationDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> URL {
        guard let home = environment["HOME"], home.hasPrefix("/") else {
            throw SettingsError("HOME must be an absolute path.")
        }
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent(".config/airbag", isDirectory: true)
    }

    private static func createDefaults(at file: URL, directory: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let temporary = directory.appendingPathComponent(".config-\(UUID().uuidString).tmp")
        defer { try? manager.removeItem(at: temporary) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(defaults).write(to: temporary, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        do {
            // A hard link publishes the complete file atomically and never replaces an existing file.
            try manager.linkItem(at: temporary, to: file)
            AirbagLog.configuration.notice("Created default global configuration")
        } catch let error as CocoaError where error.code == .fileWriteFileExists {
            // Another launcher created the configuration first. Read its file instead.
        }
    }
}

struct SettingsError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
