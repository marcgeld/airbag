import Foundation
import Testing
@testable import airbag

@Test func linkVerificationRejectsExistingHardLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside")
    try Data("outside".utf8).write(to: outside)
    try FileManager.default.linkItem(at: outside, to: workspace.appendingPathComponent("alias"))
    #expect(throws: SettingsError.self) {
        try LinkSafety.validateDirectory(workspace.path)
    }
}

@Test func linkVerificationDoesNotFollowDirectorySymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = root.appendingPathComponent("workspace")
    let outside = root.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let data = outside.appendingPathComponent("data")
    try Data("outside".utf8).write(to: data)
    try FileManager.default.linkItem(at: data, to: outside.appendingPathComponent("hardlink"))
    try FileManager.default.createSymbolicLink(at: workspace.appendingPathComponent("symlink"), withDestinationURL: outside)
    // Outside hard links are not walked; the kernel must deny following the symlink during execution.
    try LinkSafety.validateDirectory(workspace.path)
}
