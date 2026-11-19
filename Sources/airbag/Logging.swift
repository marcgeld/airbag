import Foundation
import OSLog

/// Unified logging for the launcher. Debug events intentionally include arguments, paths, and effective settings.
enum AirbagLog {
    static let configuration = Logger(subsystem: "se.redseven.airbag", category: "configuration")
    static let sandbox = Logger(subsystem: "se.redseven.airbag", category: "sandbox")
    static let command = Logger(subsystem: "se.redseven.airbag", category: "command")

    static func debugInvocation(_ arguments: [String]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        if let data = try? encoder.encode(arguments) {
            let text = String(decoding: data, as: UTF8.self)
            command.debug("Invocation arguments: \(text, privacy: .public)")
        }
    }

    static func debugConfiguration(_ settings: AirbagSettings, workspace: String?) {
        let effective = AirbagSettings(
            allowFileReads: settings.allowFileReads,
            allowFileWrites: settings.allowFileWrites,
            allowNetwork: settings.allowNetwork,
            workspace: workspace
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? encoder.encode(effective) {
            let text = String(decoding: data, as: UTF8.self)
            configuration.debug("Effective configuration: \(text, privacy: .public)")
        }
        sandbox.debug("Active workspace: \(workspace ?? "<unrestricted>", privacy: .public)")
    }
}
