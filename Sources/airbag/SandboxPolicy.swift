import Darwin
import Foundation

/// Builds filesystem rules from canonical paths captured before sandbox activation.
enum SandboxPolicy {
    static func resolveWorkspace(configured: String?, override: String?) throws -> String? {
        guard let path = override ?? configured else { return nil }
        guard !path.isEmpty else { throw SettingsError("Workspace must not be empty.") }
        if override == nil && !path.hasPrefix("/") {
            throw SettingsError("The configured workspace must be an absolute path.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &directory), directory.boolValue else {
            throw SettingsError("Workspace does not exist or is not a directory: \(path)")
        }
        return try canonicalPath(path)
    }

    static func make(settings: AirbagSettings, workspace: String?, executable: String) throws -> String {
        if let workspace { try LinkSafety.validateDirectory(workspace) }
        let configurationDirectory = try canonicalPath(AirbagSettings.configurationDirectory().path)
        try LinkSafety.validateDirectory(configurationDirectory)
        let globalConfiguration = try canonicalPath(configurationDirectory + "/config.json")
        try LinkSafety.validateFile(globalConfiguration)
        // Link creation is a distinct Seatbelt operation; do not rely only on destination write rules.
        var rules = ["(version 1)", "(allow default)", "(deny file-link)"]
        if workspace != nil || !settings.allowFileReads {
            // Keep only system runtime reads plus the selected executable outside the workspace.
            // Do not allow /System as a subtree: /System/Volumes/Data contains user files.
            let runtime = [
                "/System/Library", "/usr/lib", "/bin", "/sbin", "/usr/bin", "/usr/sbin",
                "/System/Volumes/Preboot/Cryptexes/OS", "/private/preboot/Cryptexes/OS",
                "/System/Cryptexes/OS", "/private/var/db/dyld",
            ]
            var reads = try runtime.map { "(subpath \(try quote($0)))" }
            // dyld opens the root directory while locating its shared cache.
            reads += try ["/", "/dev/null", "/dev/zero", "/dev/random", "/dev/urandom"]
                .map { "(literal \(try quote($0)))" }
            if let path = resolveExecutable(executable) { reads.append("(literal \(try quote(path)))") }
            if settings.allowFileReads, let workspace { reads.append("(subpath \(try quote(workspace)))") }
            rules.append("(deny file-read-data (require-not (require-any \(reads.joined(separator: " ")))))")
            // Block broker services that could launch unsandboxed processes or read files on our behalf.
            rules.append("(deny mach-lookup)")
        }
        if !settings.allowFileWrites {
            rules.append("(deny file-write*)")
        } else if let workspace {
            rules.append("(deny file-write* (require-not (subpath \(try quote(workspace)))))")
        }
        // Deny project policy files by name, including case aliases on case-insensitive volumes.
        rules.append(#"(deny file-read* file-write* (regex #"(^|/)\.[aA][iI][rR][bB][aA][gG]\.([tT][oO][mM][lL]|[jJ][sS][oO][nN])$"))"#)
        let projectFile = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(ProjectConfiguration.filename).path
        if let target = try? canonicalPath(projectFile) {
            // Also protect a symlink target whose filename differs from the project policy name.
            rules.append("(deny file-read* file-write* (literal \(try quote(target))))")
        }
        // Commands must not rewrite the global policy or grant themselves future approvals.
        rules.append("(deny file-write* (subpath \(try quote(configurationDirectory))))")
        // A global configuration symlink may point outside the configuration directory.
        rules.append("(deny file-write* (literal \(try quote(globalConfiguration))))")
        if !settings.allowNetwork { rules.append("(deny network*)") }
        return rules.joined(separator: "\n")
    }

    private static func resolveExecutable(_ command: String) -> String? {
        let candidates: [String]
        if command.contains("/") {
            candidates = [command]
        } else {
            let path = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
            candidates = path.split(separator: ":", omittingEmptySubsequences: false).map {
                URL(fileURLWithPath: String($0)).appendingPathComponent(command).path
            }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }.flatMap { try? canonicalPath($0) }
    }

    static func canonicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else {
            throw SettingsError("Cannot resolve path \(path): \(String(cString: strerror(errno)))")
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Quotes paths as SBPL string literals; control characters are rejected rather than interpreted.
    private static func quote(_ path: String) throws -> String {
        guard !path.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw SettingsError("Sandbox paths must not contain control characters.")
        }
        return "\"" + path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
