import os

/// Structured logging. The human-facing boot summary goes to stdout via `print`
/// instead — it is the checkpoint output, not a log line.
public enum Log {
    private static let subsystem = "dev.workflowhost"

    public static let boot = Logger(subsystem: subsystem, category: "boot")
    public static let config = Logger(subsystem: subsystem, category: "config")
    public static let database = Logger(subsystem: subsystem, category: "database")
    public static let poller = Logger(subsystem: subsystem, category: "poller")
    public static let dispatcher = Logger(subsystem: subsystem, category: "dispatcher")
}
