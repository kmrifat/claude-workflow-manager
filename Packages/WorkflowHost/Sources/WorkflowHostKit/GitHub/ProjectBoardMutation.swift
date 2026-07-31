import Foundation
import WorkflowCore

/// The mutation that moves a card between board columns.
///
/// **Phase 1 must not call this.** It is written now so the shape is settled and
/// reviewable while the system is still read-only; the dispatcher starts using it
/// in phase 6, when a run moves a card to `activeColumn` on dispatch and to
/// `reviewColumn` when the PR opens.
///
/// A test asserts `updateProjectV2ItemFieldValue` appears in this file and
/// nowhere else, so wiring it up cannot happen by accident.
enum ProjectBoardMutation {
    static let document = """
        mutation MoveCard($projectId: ID!, $itemId: ID!, $fieldId: ID!, $optionId: String!) {
          updateProjectV2ItemFieldValue(input: {
            projectId: $projectId
            itemId: $itemId
            fieldId: $fieldId
            value: { singleSelectOptionId: $optionId }
          }) {
            projectV2Item { id }
          }
        }
        """

    enum BuildError: Error, CustomStringConvertible, Equatable {
        case noStatusField(project: Int)
        case unknownColumn(String, available: [String])

        var description: String {
            switch self {
            case .noStatusField(let project):
                return "project #\(project) has no single-select Status field"
            case .unknownColumn(let name, let available):
                return "no column named \"\(name)\" — the board has: \(available.joined(separator: ", "))"
            }
        }
    }

    /// Builds the request that would move `item` into `column`.
    ///
    /// Resolving the column name against the snapshot's options is what turns a
    /// config typo into an error here rather than a silent no-op at GitHub.
    static func moveCard(
        _ item: ProjectItem,
        to column: String,
        in snapshot: ProjectSnapshot
    ) throws -> GraphQLRequest {
        guard let field = snapshot.statusField else {
            throw BuildError.noStatusField(project: snapshot.number)
        }
        guard let option = field.option(named: column) else {
            throw BuildError.unknownColumn(column, available: field.options.map(\.name))
        }

        return GraphQLRequest(
            query: document,
            variables: [
                "projectId": .string(snapshot.projectId),
                "itemId": .string(item.id),
                "fieldId": .string(field.id),
                "optionId": .string(option.id),
            ]
        )
    }
}
