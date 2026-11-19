import Foundation
import Testing
@testable import airbag

private struct ProjectFixture {
    let root: URL
    let project: String
    let global: AirbagSettings
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        project = try SandboxPolicy.canonicalPath(directory.path)
        global = try AirbagSettings.load(environment: ["HOME": root.appendingPathComponent("home").path])
    }
    var file: URL { URL(fileURLWithPath: project).appendingPathComponent(".airbag.json") }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}

@Test func projectOverridesInheritGlobalDefaultsAndStayScoped() throws {
    let fixture = try ProjectFixture()
    defer { fixture.cleanup() }
    try #"{"allowNetwork": true}"#.write(to: fixture.file, atomically: true, encoding: .utf8)
    let prepared = try ProjectConfiguration.prepare(global: fixture.global, directory: fixture.project, selectedWorkspace: nil)
    #expect(prepared.settings.allowFileReads)
    #expect(!prepared.settings.allowFileWrites)
    #expect(prepared.settings.allowNetwork)
    #expect(prepared.workspace == fixture.project)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("home/.config/airbag/approvals.json").path))
}

@Test func projectInitializerUsesJSONEncoderWithoutOverwriting() throws {
    let fixture = try ProjectFixture()
    defer { fixture.cleanup() }
    _ = try ProjectConfiguration.initialize(directory: fixture.project, defaults: fixture.global)
    let original = try Data(contentsOf: fixture.file)
    let prepared = try ProjectConfiguration.prepare(global: fixture.global, directory: fixture.project, selectedWorkspace: nil)
    #expect(prepared.settings.allowFileReads)
    #expect(!prepared.settings.allowFileWrites)
    #expect(!prepared.settings.allowNetwork)
    #expect(throws: (any Error).self) {
        try ProjectConfiguration.initialize(directory: fixture.project, defaults: fixture.global)
    }
    #expect(try Data(contentsOf: fixture.file) == original)
}

@Test func invalidProjectPermissionsFailClosed() throws {
    let fixture = try ProjectFixture()
    defer { fixture.cleanup() }
    for invalid in [#"{"allowNetwrok": true}"#, #"{"allowNetwork": 1}"#, #"{"workspace": "/"}"#, #"{"allowNetwork":"#] {
        try invalid.write(to: fixture.file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) {
            try ProjectConfiguration.prepare(global: fixture.global, directory: fixture.project, selectedWorkspace: nil)
        }
    }
}

@Test func legacyProjectConfigurationIsNotSilentlyIgnored() throws {
    let fixture = try ProjectFixture()
    defer { fixture.cleanup() }
    let legacy = URL(fileURLWithPath: fixture.project).appendingPathComponent(".airbag.toml")
    try "allowNetwork = false".write(to: legacy, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) {
        try ProjectConfiguration.prepare(global: fixture.global, directory: fixture.project, selectedWorkspace: nil)
    }
}
