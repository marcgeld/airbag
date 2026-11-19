import Foundation
import OSLog

/// User-managed project overrides, loaded before sandbox activation.
enum ProjectConfiguration {
    static let filename = ".airbag.json"

    private struct Overrides: Codable {
        var allowFileReads: Bool?
        var allowFileWrites: Bool?
        var allowNetwork: Bool?

        init(allowFileReads: Bool, allowFileWrites: Bool, allowNetwork: Bool) {
            self.allowFileReads = allowFileReads
            self.allowFileWrites = allowFileWrites
            self.allowNetwork = allowNetwork
        }

        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }

        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: Key.self)
            let known: Set<String> = ["allowFileReads", "allowFileWrites", "allowNetwork"]
            for key in values.allKeys where !known.contains(key.stringValue) {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: values, debugDescription: "Unknown project permission '\(key.stringValue)'."
                )
            }
            allowFileReads = try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "allowFileReads"))
            allowFileWrites = try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "allowFileWrites"))
            allowNetwork = try values.decodeIfPresent(Bool.self, forKey: Key(stringValue: "allowNetwork"))
        }
    }

    struct Prepared {
        let settings: AirbagSettings
        let workspace: String?
    }

    static func initialize(directory: String, defaults: AirbagSettings) throws -> URL {
        let file = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        let overrides = Overrides(
            allowFileReads: defaults.allowFileReads,
            allowFileWrites: defaults.allowFileWrites,
            allowNetwork: defaults.allowNetwork
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(overrides).write(to: file, options: .withoutOverwriting)
        AirbagLog.configuration.notice("Created project configuration")
        return file
    }

    static func prepare(global: AirbagSettings, directory: String, selectedWorkspace: String?) throws -> Prepared {
        let file = URL(fileURLWithPath: directory).appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: file.path) else {
            let legacy = URL(fileURLWithPath: directory).appendingPathComponent(".airbag.toml")
            guard !FileManager.default.fileExists(atPath: legacy.path) else {
                throw SettingsError("Found legacy .airbag.toml; convert it to .airbag.json before running commands.")
            }
            AirbagLog.configuration.debug("No project configuration at \(file.path, privacy: .public)")
            return Prepared(settings: global, workspace: selectedWorkspace)
        }
        AirbagLog.configuration.debug("Reading project overrides from \(file.path, privacy: .public)")
        let overrides = try JSONDecoder().decode(Overrides.self, from: Data(contentsOf: file))
        AirbagLog.configuration.debug("Project overrides loaded")
        let settings = AirbagSettings(
            allowFileReads: overrides.allowFileReads ?? global.allowFileReads,
            allowFileWrites: overrides.allowFileWrites ?? global.allowFileWrites,
            allowNetwork: overrides.allowNetwork ?? global.allowNetwork,
            workspace: directory
        )
        // A project file applies only to its own directory, never to an agent-selected parent.
        return Prepared(settings: settings, workspace: directory)
    }
}
