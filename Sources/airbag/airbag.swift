import ArgumentParser
import OSLog
import Darwin
import Foundation
import CSandbox

func fail(_ message: String, _ status: Int32) -> Never {
    AirbagLog.command.error("Launcher aborted; exit status=\(status, privacy: .public)")
    let bytes = Array(message.utf8)
    bytes.withUnsafeBytes { buffer in
        if let base = buffer.baseAddress {
            _ = Darwin.write(STDERR_FILENO, base, buffer.count)
        }
    }
    exit(status)
}

@main
struct Airbag: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "airbag",
        abstract: "Run a command using the sandbox settings in ~/.config/airbag/config.json."
    )

    enum NetworkAccess: String, CaseIterable, ExpressibleByArgument {
        case all
    }

    @Option(name: .long, help: "Allow all network traffic for this command, overriding configuration. Supported value: all.")
    var network: NetworkAccess?

    @Option(name: .long, help: "Restrict user-file access to this directory and start the command there.")
    var workspace: String?

    @Flag(name: .long, help: "Create this project's .airbag.json without overwriting an existing file.")
    var initProjectConfig = false

    @Argument(help: "The command to run.")
    var executable: String?

    @Argument(parsing: .captureForPassthrough, help: "Arguments passed unchanged to the command.")
    var arguments: [String] = []

    mutating func validate() throws {
        if initProjectConfig {
            guard network == nil else {
                throw ValidationError("--network cannot be combined with --init-project-config.")
            }
            guard executable == nil && arguments.isEmpty else {
                throw ValidationError("--init-project-config cannot be combined with a command.")
            }
        } else if executable == nil {
            throw ValidationError("A command is required.")
        }
    }

    mutating func run() throws {
        AirbagLog.command.info("Invocation started")
        AirbagLog.debugInvocation(CommandLine.arguments)
        let settings: AirbagSettings
        let workspacePath: String?
        do {
            let global = try AirbagSettings.load()
            let selected = try SandboxPolicy.resolveWorkspace(configured: global.workspace, override: workspace)
            let project = try selected ?? SandboxPolicy.canonicalPath(FileManager.default.currentDirectoryPath)
            let configDirectory = try SandboxPolicy.canonicalPath(AirbagSettings.configurationDirectory().path)
            guard project != configDirectory else {
                throw SettingsError("The Airbag configuration directory cannot be used as a project.")
            }
            if initProjectConfig {
                let file = try ProjectConfiguration.initialize(directory: project, defaults: global)
                print("Created \(file.path)")
                return
            }
            let prepared = try ProjectConfiguration.prepare(
                global: global, directory: project, selectedWorkspace: selected
            )
            settings = AirbagSettings(
                allowFileReads: prepared.settings.allowFileReads,
                allowFileWrites: prepared.settings.allowFileWrites,
                allowNetwork: network == .all || prepared.settings.allowNetwork,
                workspace: prepared.settings.workspace
            )
            workspacePath = prepared.workspace
            AirbagLog.debugConfiguration(settings, workspace: workspacePath)
            AirbagLog.sandbox.info("Effective policy: reads=\(settings.allowFileReads, privacy: .public) writes=\(settings.allowFileWrites, privacy: .public) network=\(settings.allowNetwork, privacy: .public) workspace=\(workspacePath != nil, privacy: .public)")
            if network == .all {
                AirbagLog.command.notice("Per-command network override enabled: all")
            }
            if let workspacePath, chdir(workspacePath) != 0 {
                throw SettingsError("Cannot enter workspace: \(String(cString: strerror(errno)))")
            }
        } catch {
            AirbagLog.configuration.error("Configuration setup failed")
            fail("airbag: configuration error: \(error)\n", 78)
        }
        guard let executable else { fail("airbag: a command is required\n", 64) }

        // Prepare argv before entering the sandbox. No shell parsing or interpolation.
        var argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) }
        guard argv.allSatisfy({ $0 != nil }) else {
            AirbagLog.command.fault("Cannot allocate command arguments")
            fail("airbag: cannot allocate argv\n", 71)
        }
        argv.append(nil)
        
        // Configuration is evaluated before sandbox activation; failures never run the command.
        // Runtime read exceptions and inherited standard streams remain available.
#if AIRBAG_INVALID_POLICY
        let profile = "(version 1) (this-is-not-a-valid-operation)"
#else
        let profile: String
        do {
            profile = try SandboxPolicy.make(settings: settings, workspace: workspacePath, executable: executable)
        } catch {
            AirbagLog.sandbox.error("Policy preparation failed")
            fail("airbag: policy error: \(error)\n", 78)
        }
#endif
        
        // Do not pass extra inherited file/socket descriptors to the command.
        // Standard input/output/error remain available deliberately.
        let argumentCount = arguments.count
        AirbagLog.command.info("Command prepared; argument count=\(argumentCount, privacy: .public)")
        AirbagLog.sandbox.info("Applying sandbox to current process")
        for descriptor in 3..<getdtablesize() { _ = close(descriptor) }
        var errorBuffer: UnsafeMutablePointer<CChar>?
        let result = profile.withCString { airbag_sandbox_init($0, 0, &errorBuffer) }
        if result != 0 {
            let sandboxErrno = errno
            AirbagLog.sandbox.error("Sandbox activation failed; errno=\(sandboxErrno, privacy: .public)")
            let detail = errorBuffer.map { String(cString: $0) } ?? "unknown error"
            if let errorBuffer { airbag_sandbox_free_error(errorBuffer) }
            fail("airbag: sandbox_init failed: \(detail)\n", 70)
        }
        if let errorBuffer { airbag_sandbox_free_error(errorBuffer) }
        
        AirbagLog.sandbox.notice("Sandbox active")
        AirbagLog.command.notice("Handing off to command with execvp")
        argv.withUnsafeMutableBufferPointer { buffer in
            _ = execvp(buffer[0]!, buffer.baseAddress!)
        }
        let savedErrno = errno
        AirbagLog.command.error("execvp failed; errno=\(savedErrno, privacy: .public)")
        fail("airbag: execvp: \(String(cString: strerror(savedErrno)))\n",
             savedErrno == ENOENT ? 127 : 126)
    }
}
