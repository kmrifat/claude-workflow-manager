import Foundation

/// The command line. Hand-rolled rather than pulling in a parser dependency —
/// there are three subcommands and no options worth a library.
public enum HostCommand: Equatable, Sendable {
    /// No arguments: load config, open the database, print what it found.
    case boot
    /// Poll GitHub into the cache. `once` runs a single tick and exits.
    case poll(once: Bool)
    /// Print each repo's Ready column, strictly from cache.
    case ready
    /// Poll and serve the dashboard. `tunnel` also exposes it through
    /// cloudflared; `dispatch` additionally starts runs.
    ///
    /// Dispatching is opt-in and off by default. It assigns issues, pushes
    /// branches and opens PRs — none of which should start because someone ran
    /// the dashboard.
    case serve(port: Int, tunnel: Bool, dispatch: Bool)
    case help

    public enum ParseError: Error, CustomStringConvertible, Equatable {
        case unknownCommand(String)
        case unknownOption(String, command: String)
        case invalidOption(String)

        public var description: String {
            switch self {
            case .unknownCommand(let name):
                return "unknown command \"\(name)\"\n\n\(HostCommand.usage)"
            case .unknownOption(let option, let command):
                return "unknown option \"\(option)\" for \(command)\n\n\(HostCommand.usage)"
            case .invalidOption(let message):
                return "\(message)\n\n\(HostCommand.usage)"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> HostCommand {
        // arguments[0] is the executable path.
        let arguments = Array(arguments.dropFirst())
        guard let command = arguments.first else { return .boot }

        switch command {
        case "-h", "--help", "help":
            return .help

        case "poll":
            var once = false
            for option in arguments.dropFirst() {
                switch option {
                case "--once": once = true
                default: throw ParseError.unknownOption(option, command: "poll")
                }
            }
            return .poll(once: once)

        case "ready":
            if let option = arguments.dropFirst().first {
                throw ParseError.unknownOption(option, command: "ready")
            }
            return .ready

        case "serve":
            var port = 8420
            var tunnel = false
            var dispatch = false
            var rest = Array(arguments.dropFirst())
            while let option = rest.first {
                rest.removeFirst()
                switch option {
                case "--tunnel":
                    tunnel = true
                case "--dispatch":
                    dispatch = true
                case "--port":
                    guard let value = rest.first, let parsed = Int(value), (1...65535).contains(parsed)
                    else { throw ParseError.invalidOption("--port needs a port number between 1 and 65535") }
                    port = parsed
                    rest.removeFirst()
                default:
                    throw ParseError.unknownOption(option, command: "serve")
                }
            }
            return .serve(port: port, tunnel: tunnel, dispatch: dispatch)

        default:
            throw ParseError.unknownCommand(command)
        }
    }

    public static let usage = """
        Usage: WorkflowHost [command]

          (none)          load config, open the database, print what it found
          poll [--once]   poll GitHub into the cache; --once runs a single tick
          ready           print each repo's Ready column, from cache
          serve [--port N] [--tunnel] [--dispatch]
                          poll continuously and serve the dashboard on
                          127.0.0.1:8420; --tunnel also exposes it via
                          cloudflared; --dispatch starts runs (assigns issues,
                          pushes branches, opens PRs — never merges)
          help            this message

        Environment:
          WORKFLOWHOST_HOME              override ~/Library/Application Support/WorkflowHost
          WORKFLOWHOST_GITHUB_TOKEN      use this token instead of the Keychain
          WORKFLOWHOST_DASHBOARD_TOKEN   use this dashboard token instead of the Keychain
        """
}
