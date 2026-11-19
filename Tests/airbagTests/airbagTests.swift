import Foundation
import Testing
@testable import airbag

private func runAirbag(_ arguments: [String], home: URL? = nil) throws -> (status: Int32, output: String) {
    let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { if home == nil { try? FileManager.default.removeItem(at: temporaryHome) } }
    let process = Process()
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = (home ?? temporaryHome).path
    process.environment = environment
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    process.executableURL = root.appendingPathComponent(".build/debug/airbag")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Test func missingCommandShowsUsage() throws {
    #expect(try runAirbag([]).status == 64)
}

@Test func forwardsExitStatus() throws {
    #expect(try runAirbag(["/bin/bash", "--noprofile", "--norc", "-c", "exit 37"]).status == 37)
}

@Test func preservesArgumentsWithoutShellExpansion() throws {
    let literal = "a b; $(echo expanded) *"
    let result = try runAirbag(["--", "/usr/bin/printf", "%s", literal])
    #expect(result.status == 0)
    #expect(result.output == literal)
}

@Test func showsHelpWithoutLaunchingCommand() throws {
    let result = try runAirbag(["--help"])
    #expect(result.status == 0)
    #expect(result.output.contains("USAGE:"))
    #expect(result.output.contains("airbag"))
}

@Test func forwardsHelpAndTerminatorToChild() throws {
    let result = try runAirbag(["/usr/bin/printf", "%s|", "--help", "--", "-x", ""])
    #expect(result.status == 0)
    #expect(result.output == "--help|--|-x||")
}

@Test func createsDefaultConfiguration() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let result = try runAirbag(["/bin/echo", "configured"], home: home)
    #expect(result.status == 0)
    let file = home.appendingPathComponent(".config/airbag/config.json")
    let settings = try JSONDecoder().decode(AirbagSettings.self, from: Data(contentsOf: file))
    #expect(settings.allowFileReads)
    #expect(!settings.allowFileWrites)
    #expect(!settings.allowNetwork)
}

@Test func invalidConfigurationDoesNotRunCommandOrOverwriteFile() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".config/airbag")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let file = directory.appendingPathComponent("config.json")
    let invalid = #"{"allowNetwork":"#
    try invalid.write(to: file, atomically: true, encoding: .utf8)
    let result = try runAirbag(["/bin/echo", "SHOULD_NOT_RUN"], home: home)
    #expect(result.status == 78)
    #expect(result.output.isEmpty)
    #expect(try String(contentsOf: file, encoding: .utf8) == invalid)
}

@Test func helpDoesNotCreateConfiguration() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(try runAirbag(["--help"], home: home).status == 0)
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(".config/airbag/config.json").path))
}

@Test func rejectsStringInsteadOfBoolean() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".config/airbag")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #"{"allowFileWrites": false, "allowNetwork": "false"}"#.write(
        to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8
    )
    #expect(try runAirbag(["/bin/echo", "SHOULD_NOT_RUN"], home: home).status == 78)
}

@Test func rejectsInvalidReadPermission() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".config/airbag")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let configuration = #"{"allowFileReads": 1, "allowFileWrites": false, "allowNetwork": false}"#
    try configuration.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    let result = try runAirbag(["/bin/echo", "SHOULD_NOT_RUN"], home: home)
    #expect(result.status == 78)
    #expect(result.output.isEmpty)
}

@Test func legacyGlobalConfigurationIsNotSilentlyIgnored() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    let directory = home.appendingPathComponent(".config/airbag")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try "allowFileReads = false\nallowFileWrites = false\nallowNetwork = false\n".write(
        to: directory.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
    )
    let result = try runAirbag(["/bin/echo", "SHOULD_NOT_RUN"], home: home)
    #expect(result.status == 78)
    #expect(result.output.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path))
}

@Test func networkAllIsAcceptedWithoutChangingConfiguration() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(try runAirbag(["--network=all", "/bin/echo", "network enabled"], home: home).status == 0)
    let file = home.appendingPathComponent(".config/airbag/config.json")
    #expect(try !JSONDecoder().decode(AirbagSettings.self, from: Data(contentsOf: file)).allowNetwork)
}

@Test func unsupportedNetworkValuesNeverRunTheCommand() throws {
    for value in ["dn.se", "192.168.0.0/24", "none", ""] {
        let result = try runAirbag(["--network=\(value)", "/bin/echo", "SHOULD_NOT_RUN"])
        #expect(result.status == 64)
        #expect(result.output.isEmpty)
    }
}

@Test func networkCannotBeCombinedWithProjectInitialization() throws {
    #expect(try runAirbag(["--network=all", "--init-project-config"]).status == 64)
}

@Test func childNetworkArgumentIsPassedThroughLiterally() throws {
    let result = try runAirbag(["/usr/bin/printf", "%s", "--network=all"])
    #expect(result.status == 0)
    #expect(result.output == "--network=all")
}
