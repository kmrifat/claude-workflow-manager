import Foundation

/// A config problem, always reported against the offending field.
///
/// Every case renders as `config.json:<field.path>: <reason>` so the operator can
/// go straight to the line. Decoding failures and semantic validation failures
/// use the identical notation — which layer rejected the value is our problem,
/// not theirs.
public enum ConfigError: Error, CustomStringConvertible, Equatable, Sendable {
    case fileMissing(URL)
    case unreadable(URL, reason: String)
    case malformedJSON(URL, reason: String)
    case missingField(URL, path: String)
    case wrongType(URL, path: String, expected: String)
    case nullField(URL, path: String)
    case invalidValue(URL, path: String, reason: String)

    /// `EX_CONFIG`. Distinguishes "misconfigured" from "crashed" for launchd and CI.
    public var exitCode: Int32 { 78 }

    public var url: URL {
        switch self {
        case .fileMissing(let url),
             .unreadable(let url, _),
             .malformedJSON(let url, _),
             .missingField(let url, _),
             .wrongType(let url, _, _),
             .nullField(let url, _),
             .invalidValue(let url, _, _):
            return url
        }
    }

    public var description: String {
        let file = url.lastPathComponent
        switch self {
        case .fileMissing:
            return """
                no config file at
                  \(url.path(percentEncoded: false))

                Create it with:

                \(Self.template)
                """
        case .unreadable(_, let reason):
            return "\(file): could not be read — \(reason)"
        case .malformedJSON(_, let reason):
            return "\(file): not valid JSON — \(reason)"
        case .missingField(_, let path):
            return "\(file):\(path): required field is missing"
        case .wrongType(_, let path, let expected):
            return "\(file):\(path): expected \(expected)"
        case .nullField(_, let path):
            return "\(file):\(path): value is null"
        case .invalidValue(_, let path, let reason):
            return "\(file):\(path): \(reason)"
        }
    }

    /// Printed when the config file is absent, so the fix is a copy-paste away.
    static let template = """
          {
            "maxConcurrentPerRepo": 2,
            "pollIntervalSec": 60,
            "repos": [
              {
                "owner": "me",
                "name": "product-a",
                "path": "/Users/me/code/product-a",
                "projectNumber": 3,
                "readyColumn": "Ready",
                "activeColumn": "In progress",
                "reviewColumn": "Review"
              }
            ]
          }
        """
}

extension ConfigError {
    /// Renders a coding path the way it reads in the JSON file: integer keys as
    /// `[0]`, string keys as `.name`, so the first repo's owner is `repos[0].owner`.
    static func fieldPath(_ codingPath: [any CodingKey]) -> String {
        var rendered = ""
        for key in codingPath {
            if let index = key.intValue {
                rendered += "[\(index)]"
            } else if rendered.isEmpty {
                rendered += key.stringValue
            } else {
                rendered += ".\(key.stringValue)"
            }
        }
        return rendered.isEmpty ? "<root>" : rendered
    }

    init(decodingError: DecodingError, url: URL) {
        switch decodingError {
        case .keyNotFound(let key, let context):
            // The missing key is NOT part of context.codingPath — without
            // appending it we would report `repos[0]` instead of `repos[0].owner`.
            self = .missingField(url, path: Self.fieldPath(context.codingPath + [key]))

        case .typeMismatch(let type, let context):
            self = .wrongType(
                url,
                path: Self.fieldPath(context.codingPath),
                expected: String(describing: type)
            )

        case .valueNotFound(_, let context):
            self = .nullField(url, path: Self.fieldPath(context.codingPath))

        case .dataCorrupted(let context):
            // An empty coding path means the document itself failed to parse;
            // anything else is a specific value the decoder rejected.
            if context.codingPath.isEmpty {
                self = .malformedJSON(url, reason: context.debugDescription)
            } else {
                self = .invalidValue(
                    url,
                    path: Self.fieldPath(context.codingPath),
                    reason: context.debugDescription
                )
            }

        @unknown default:
            self = .malformedJSON(url, reason: String(describing: decodingError))
        }
    }
}
