import Darwin
import Foundation
import Shared

/// Spawned in a new process group; only this owner can stop it. Pipes drain on a utility queue.
/// The lock protects output and the child-reaping state; no child PID is adopted from a model.
public final class OwnedWorkflowProcess: @unchecked Sendable {
    public let processID: pid_t
    public let processGroupID: pid_t
    private let lock = NSLock()
    private var output = Data()
    private var reaped = false
    private var exitCode: Int32?
    private let capture: FileHandle
    private let guardWriter: FileHandle
    private let guardProcessID: pid_t
    public init(workflow: ApprovedWorkflow, guardExecutable: URL) throws {
        // Reserve the owned group BEFORE starting any user-configured executable.
        // A parent crash at any subsequent point closes this guard's pipe and kills the group.
        let guardOwner = try Self.spawnGuard(executable: guardExecutable, group: 0)
        guardWriter = guardOwner.0; guardProcessID = guardOwner.1; processGroupID = guardOwner.1
        var spawned = false
        defer {
            if !spawned {
                _ = kill(-guardOwner.1, SIGKILL)
                try? guardOwner.0.close()
                var status: Int32 = 0; _ = waitpid(guardOwner.1, &status, 0)
            }
        }
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { throw ToolError.unavailable("Cannot create workflow capture pipe.") }
        for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes); close(descriptors[1]) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, processGroupID)
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, workflow.workingDirectory)
        let argv: [UnsafeMutablePointer<CChar>?] = ([workflow.executable] + workflow.arguments).map { $0.withCString { strdup($0) } } + [nil]
        // No inherited secrets or environment-controlled loader hooks; explicit fixed PATH.
        let environmentStrings: [String] = ["PATH=/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin", "HOME=" + NSHomeDirectory(), "LANG=en_US.UTF-8"]
        let variables: [UnsafeMutablePointer<CChar>?] = environmentStrings.map { $0.withCString { strdup($0) } } + [nil]
        defer { for p in argv + variables { if let p { free(p) } } }
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { args in variables.withUnsafeBufferPointer { environmentBuffer in
            posix_spawn(&pid, workflow.executable, &actions, &attributes, args.baseAddress!, environmentBuffer.baseAddress!)
        } }
        guard result == 0 else { close(descriptors[0]); throw ToolError.unavailable("Workflow could not start (\(result)).") }
        processID = pid; spawned = true
        capture = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
        let handle = capture
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let bytes = handle.availableData
                if bytes.isEmpty { break }
                guard let self else { break }
                self.lock.lock(); self.output.append(bytes)
                if self.output.count > 8192 { self.output.removeFirst(self.output.count - 8192) }
                self.lock.unlock()
            }
            try? handle.close()
        }
    }
    private static func spawnGuard(executable: URL, group: pid_t) throws -> (FileHandle, pid_t) {
        var channel: [Int32] = [0, 0]
        guard pipe(&channel) == 0 else { throw ToolError.unavailable("Cannot create workflow ownership channel.") }
        for descriptor in channel { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        var readiness: [Int32] = [0, 0]
        guard pipe(&readiness) == 0 else { close(channel[0]); close(channel[1]); throw ToolError.unavailable("Cannot create guard readiness channel.") }
        for descriptor in readiness { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
        defer { close(readiness[0]); close(readiness[1]) }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions); posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes); close(channel[0]) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        posix_spawnattr_setpgroup(&attributes, group)
        posix_spawn_file_actions_adddup2(&actions, channel[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, readiness[1], STDOUT_FILENO)
        posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0)
        let name = strdup(executable.path); defer { free(name) }
        let argv: [UnsafeMutablePointer<CChar>?] = [name, nil], env: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let result = argv.withUnsafeBufferPointer { a in env.withUnsafeBufferPointer { e in posix_spawn(&pid, executable.path, &actions, &attributes, a.baseAddress!, e.baseAddress!) } }
        guard result == 0 else { close(channel[1]); throw ToolError.unavailable("Workflow ownership guard could not start.") }
        // The guard acknowledges after installing its TERM policy, before any workflow starts.
        var descriptor = pollfd(fd: readiness[0], events: Int16(POLLIN), revents: 0)
        var byte: UInt8 = 0
        guard poll(&descriptor, 1, 1000) > 0, read(readiness[0], &byte, 1) == 1, byte == 1 else {
            _ = kill(-pid, SIGKILL); close(channel[1])
            var status: Int32 = 0; _ = waitpid(pid, &status, 0)
            throw ToolError.unavailable("Workflow ownership guard did not become ready.")
        }
        return (FileHandle(fileDescriptor: channel[1], closeOnDealloc: true), pid)
    }
    private func reapGuard() {
        try? guardWriter.close()
        var status: Int32 = 0; _ = waitpid(guardProcessID, &status, 0)
    }
    /// Test-owned process loss uses the same EOF signal as an app crash.
    #if DEBUG
    func relinquishOwnershipForTesting() { try? guardWriter.close() }
    #endif
    public var boundedOutput: Data { lock.lock(); defer { lock.unlock() }; return output }
    public var running: Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return false }
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT)
        // Keep the workflow PID unreaped until stop/deinit. The separate guard
        // reserves the process-group identity while descendants may still be alive.
        return result == 0 && info.si_pid == 0
    }
    public func stopImmediately() {
        lock.withLock {
            if !reaped { _ = kill(-processGroupID, SIGKILL); var status: Int32 = 0; _ = waitpid(processID, &status, 0); reaped = true; exitCode = status; reapGuard() }
        }
    }
    public func stop() async {
        // The guard ignores TERM and reserves the group until escalation and reaping.
        // Parent loss during graceful shutdown still delivers EOF to the live guard.
        lock.withLock { if !reaped { _ = kill(-processGroupID, SIGTERM) } }
        try? await Task.sleep(for: .milliseconds(300))
        lock.withLock {
            if !reaped {
                _ = kill(-processGroupID, SIGKILL)
                var status: Int32 = 0; _ = waitpid(processID, &status, 0); reaped = true; exitCode = status; reapGuard()
            }
        }
    }
    deinit {
        lock.lock()
        if !reaped { _ = kill(-processGroupID, SIGKILL); var status: Int32 = 0; _ = waitpid(processID, &status, 0); reapGuard() }
        lock.unlock()
    }
}
