import Foundation
import WorkflowCore

/// Reads and validates `config.json`.
public enum ConfigLoader {
    public static func load(at url: URL) throws -> HostConfig {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw ConfigError.fileMissing(url)
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ConfigError.unreadable(url, reason: error.localizedDescription)
        }

        let decoded: HostConfig
        do {
            // No key strategy: the JSON is camelCase and so are the properties.
            // Adding `.convertFromSnakeCase` here silently breaks every field.
            decoded = try JSONDecoder().decode(HostConfig.self, from: data)
        } catch let error as DecodingError {
            throw ConfigError(decodingError: error, url: url)
        } catch {
            throw ConfigError.malformedJSON(url, reason: error.localizedDescription)
        }

        return try decoded.validated(source: url)
    }
}
