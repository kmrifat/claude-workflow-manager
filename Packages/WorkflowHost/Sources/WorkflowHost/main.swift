import Foundation
import WorkflowHostKit

// stdout is block-buffered when it isn't a terminal, so a daemon started with
// its output redirected would never flush its banner — including the dashboard
// token, which is printed exactly once. Line buffering costs nothing here.
setvbuf(stdout, nil, _IOLBF, 0)

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("WorkflowHost: \(message)\n".utf8))
    exit(code)
}

do {
    exit(try await HostBoot.run())
} catch let error as ConfigError {
    fail(error.description, code: error.exitCode)
} catch let error as HostCommand.ParseError {
    fail(error.description, code: 64)  // EX_USAGE
} catch let error as GitHubToken.LookupError {
    fail(error.description, code: 78)  // EX_CONFIG — a missing token is configuration
} catch {
    fail(String(describing: error), code: 1)
}
