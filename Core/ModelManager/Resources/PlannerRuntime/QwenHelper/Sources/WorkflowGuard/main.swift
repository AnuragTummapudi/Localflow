import Darwin
import Foundation

// Host-only lifetime guard. No model, arguments, paths, commands, network or permissions.
// posix_spawn places this guard INSIDE the owned workflow's group. Its membership
// reserves the PGID, preventing PID/group reuse from targeting an unrelated process.
let group = getpgrp()
guard group > 1, group != getpgid(getppid()), CommandLine.arguments.count == 1 else { exit(2) }
// Remain alive through graceful workflow shutdown so parent loss still kills descendants.
signal(SIGTERM, SIG_IGN)
FileHandle.standardOutput.write(Data([1]))
while !FileHandle.standardInput.availableData.isEmpty {}
_ = kill(-group, SIGKILL)
exit(0)
