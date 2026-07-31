import Foundation

/// GraphQL documents.
///
/// Projects v2 is the one thing REST cannot do: the board's Status field has no
/// REST equivalent, so column membership has to come from here.
enum GitHubGraphQL {
    /// The board's column field is conventionally named `Status`. Config names
    /// the *options* (`readyColumn` and friends), not the field.
    static let statusFieldName = "Status"

    static let boardSnapshot = """
        query BoardSnapshot($owner: String!, $name: String!, $number: Int!, $cursor: String) {
          repository(owner: $owner, name: $name) {
            projectV2(number: $number) {
              id
              number
              title
              field(name: "\(statusFieldName)") {
                ... on ProjectV2SingleSelectField {
                  id
                  name
                  options { id name }
                }
              }
              items(first: 100, after: $cursor) {
                pageInfo { hasNextPage endCursor }
                nodes {
                  id
                  fieldValueByName(name: "\(statusFieldName)") {
                    ... on ProjectV2ItemFieldSingleSelectValue { name }
                  }
                  content {
                    __typename
                    ... on Issue {
                      number title url state
                      assignees(first: 10) { nodes { login } }
                    }
                    ... on PullRequest {
                      number title url state
                      assignees(first: 10) { nodes { login } }
                    }
                  }
                }
              }
            }
          }
        }
        """
}

// MARK: - Wire types

struct GraphQLRequest: Encodable {
    let query: String
    let variables: [String: GraphQLValue]
}

/// Just enough of a JSON value to express GraphQL variables without reaching for
/// `Any`, which would not be `Sendable`.
enum GraphQLValue: Encodable, Sendable, Equatable {
    case string(String)
    case int(Int)
    case null

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct GraphQLResponse<Payload: Decodable>: Decodable {
    struct Failure: Decodable { let message: String }
    let data: Payload?
    let errors: [Failure]?
}

struct BoardSnapshotPayload: Decodable {
    struct Repository: Decodable { let projectV2: Project? }
    struct Project: Decodable {
        let id: String
        let number: Int
        let title: String
        let field: Field?
        let items: ItemConnection
    }
    struct Field: Decodable {
        let id: String
        let name: String
        let options: [Option]
    }
    struct Option: Decodable {
        let id: String
        let name: String
    }
    struct ItemConnection: Decodable {
        let pageInfo: PageInfo
        let nodes: [Item]
    }
    struct PageInfo: Decodable {
        let hasNextPage: Bool
        let endCursor: String?
    }
    struct Item: Decodable {
        let id: String
        let fieldValueByName: StatusValue?
        let content: Content?
    }
    struct StatusValue: Decodable {
        let name: String?
    }
    struct Content: Decodable {
        let __typename: String
        let number: Int
        let title: String
        let url: URL
        let state: String
        let assignees: AssigneeConnection?
    }
    struct AssigneeConnection: Decodable {
        struct Assignee: Decodable { let login: String }
        let nodes: [Assignee]
    }

    let repository: Repository?
}
