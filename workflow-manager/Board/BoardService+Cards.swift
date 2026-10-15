//
//  BoardService+Cards.swift
//  workflow-manager
//
//  The phone's card screen, served: a card in full, the card window's edits,
//  and images in both directions. Kept beside `BoardService` rather than in it
//  because the board messages there are the protocol's baseline and these are
//  an addition a phone may or may not use.
//
//  The rules are the Mac's own, applied here rather than trusted to the phone:
//  edits go through the same models, inside the same undo-disabled save, and a
//  phone's note lands in the card's activity exactly as one typed in the card
//  window does — where `get_card` hands it to Claude.
//

import Foundation
import SwiftData
import ClaudeWMWire

/// One upload, by connection: two phones (or one phone reconnected) sending an
/// image with the same id must not have their pieces mixed.
struct UploadKey: Hashable {
    let client: UUID
    let uploadID: String
}

struct PendingUpload {
    var projectID: String
    var cardID: String
    var filename: String
    var assembler: WireImageTransfer.Assembler
}

extension BoardService {

    // MARK: - A card in full

    func sendCard(projectID: String, cardID: String, to client: UUID, on server: BoardServer) {
        guard let project = project(id: projectID) else {
            server.send(.failure(WireFailure(code: .unknownProject,
                                             message: "That board is no longer on this Mac.")), to: client)
            return
        }
        guard let item = card(id: cardID, in: project) else {
            server.send(.failure(WireFailure(code: .unknownCard,
                                             message: "That card is no longer on this board.")), to: client)
            return
        }
        server.send(.cardDetail(BoardSnapshotBuilder.detail(of: item, in: project)), to: client)
    }

    // MARK: - Edits

    /// The card window's edits. Called from inside `apply`, so already inside
    /// its undo-disabled save.
    func applyCardEdit(_ mutation: BoardMutation, in project: Project) -> Outcome {
        guard let cardID = mutation.cardID, let item = card(id: cardID, in: project) else {
            return .rejected(.unknownCard, "That card is no longer on this board.")
        }
        switch mutation {
        case .setSubtask(_, let subtaskID, let done):
            guard let subtask = item.orderedSubtasks.first(where: { $0.uuid.uuidString == subtaskID }) else {
                return .rejected(.unknownCard, "That subtask is no longer on the card.")
            }
            subtask.isDone = done

        case .addSubtask(_, let title):
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .rejected(.rejected, "A subtask needs a title.") }
            let subtask = Subtask(title: trimmed, sortOrder: FractionalOrder.afterLast(of: item.subtasks.map(\.sortOrder)))
            context.insert(subtask)
            subtask.item = item

        case .deleteSubtask(_, let subtaskID):
            guard let subtask = item.orderedSubtasks.first(where: { $0.uuid.uuidString == subtaskID }) else {
                return .rejected(.unknownCard, "That subtask is no longer on the card.")
            }
            context.delete(subtask)

        case .addNote(_, let note):
            let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return .rejected(.rejected, "The note is empty.") }
            // "You", as from the card window: it is the board's owner either
            // way, and `get_card` tells the agent to read notes by "You".
            let event = CardEvent(actor: "You", tool: nil, summary: "Added a note", note: trimmed)
            context.insert(event)
            event.item = item

        case .setDueDate(_, let dueDate):
            item.dueDate = dueDate

        case .setOwner(_, let owner):
            item.owner = owner.trimmingCharacters(in: .whitespacesAndNewlines)

        case .setTags(_, let tags):
            var seen = Set<String>()
            item.tags = tags
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }

        default:
            return .rejected(.unsupportedMutation, "This Mac doesn’t understand “\(mutation.kind)”.")
        }
        return .applied
    }

    // MARK: - Images in

    /// One piece of an image a phone is sending. The last piece is checked —
    /// it must really be an image — stored on the card as an attachment, and
    /// referenced at the end of the card's notes, as a paste in the card
    /// window does.
    func receive(_ chunk: WireUploadChunk, from client: UUID, on server: BoardServer) {
        let key = UploadKey(client: client, uploadID: chunk.uploadID)
        func refuse(_ message: String) {
            uploads[key] = nil
            server.send(.failure(WireFailure(requestID: chunk.uploadID, code: .rejected, message: message)), to: client)
        }

        if chunk.offset == 0 {
            guard chunk.totalBytes > 0, chunk.totalBytes <= WireImageTransfer.maxUploadBytes else {
                return refuse("That image is too large to send.")
            }
            guard let project = project(id: chunk.projectID), card(id: chunk.cardID, in: project) != nil else {
                return refuse("That card is no longer on this board.")
            }
            uploads[key] = PendingUpload(projectID: chunk.projectID, cardID: chunk.cardID, filename: chunk.filename,
                                         assembler: .init(expectedBytes: chunk.totalBytes))
        }
        guard var upload = uploads[key] else { return refuse("That image arrived out of order. Try again.") }

        let whole: Data?
        do {
            whole = try upload.assembler.add(offset: chunk.offset, data: chunk.data, isLast: chunk.isLast)
        } catch {
            return refuse("That image arrived incomplete. Try again.")
        }
        uploads[key] = upload
        server.send(.uploadProgress(uploadID: chunk.uploadID, receivedBytes: upload.assembler.data.count), to: client)
        guard let whole else { return }
        uploads[key] = nil

        guard let project = project(id: upload.projectID), let item = card(id: upload.cardID, in: project) else {
            return refuse("That card is no longer on this board.")
        }
        guard let image = AttachmentImage.normalize(whole) else {
            return refuse("That file isn’t an image Pitwall can read.")
        }

        let undoManager = context.undoManager
        undoManager?.disableUndoRegistration()
        let attachment = CardAttachment(
            filename: upload.filename.isEmpty ? "Photo.\(image.contentType == "public.jpeg" ? "jpeg" : "png")" : upload.filename,
            contentType: image.contentType, data: image.data,
            pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight
        )
        context.insert(attachment)
        attachment.item = item
        let reference = attachment.markdownReference
        let separator = item.details.isEmpty || item.details.hasSuffix("\n") ? "" : "\n"
        item.details += separator + reference + "\n"
        try? context.save()
        undoManager?.enableUndoRegistration()

        server.send(.uploadComplete(uploadID: chunk.uploadID, attachmentID: attachment.uuid.uuidString,
                                    reference: reference), to: client)
        didMutate?(project)
    }

    // MARK: - Images out

    /// An image by id, in pieces. With `maxEdge` it is scaled down and sent as
    /// JPEG — a phone drawing a thumbnail has no use for a 5 MB screenshot.
    func sendAttachment(_ attachmentID: String, projectID: String, maxEdge: Int?,
                        to client: UUID, on server: BoardServer) {
        guard let project = project(id: projectID),
              let uuid = UUID(uuidString: attachmentID),
              let attachment = project.allItems
                  .lazy.flatMap(\.attachments)
                  .first(where: { $0.uuid == uuid && !$0.isDeleted })
        else {
            server.send(.failure(WireFailure(requestID: attachmentID, code: .unknownCard,
                                             message: "That image is no longer on the card.")), to: client)
            return
        }

        var data = attachment.data
        var contentType = attachment.contentType
        if let maxEdge, maxEdge > 0, max(attachment.pixelWidth, attachment.pixelHeight) > maxEdge,
           let scaled = AttachmentImage.preview(of: attachment.data, maxEdge: maxEdge) {
            data = scaled
            contentType = "public.jpeg"
        }
        for piece in WireImageTransfer.pieces(of: data) {
            server.send(.attachmentChunk(WireAttachmentChunk(
                attachmentID: attachmentID, maxEdge: maxEdge, contentType: contentType,
                totalBytes: data.count, offset: piece.offset, data: piece.data, isLast: piece.isLast
            )), to: client)
        }
    }
}
