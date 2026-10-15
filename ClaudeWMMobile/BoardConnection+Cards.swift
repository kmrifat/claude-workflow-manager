//
//  BoardConnection+Cards.swift
//  ClaudeWMMobile
//
//  The card screen's half of the protocol: a card in full, Home's overview,
//  and images in both directions.
//
//  ## Images going out
//
//  A photo is placed in the notes as `![name](pending:<uploadID>)` the moment
//  it is chosen, so the text reads in order while it travels. The Mac stores
//  each image as it arrives and *appends* its reference to the card's notes —
//  which is all an older reader of the notes needs — but the notes the phone
//  saves put each reference back where the photo was placed. So a save that
//  still names a `pending:` image is held until every image it names has
//  arrived (`HeldDetails`), then sent with the real `attachment:` ids.
//
//  The Mac forgets a half-sent image when the connection drops, so an upload
//  in flight starts again from its first piece on reconnect.
//

import Foundation
import UIKit
import ClaudeWMWire

/// One image on its way to the Mac.
struct UploadState: Equatable {
    enum Status: Equatable {
        case sending
        case done(attachmentID: String)
        case failed(String)
    }

    var projectID: String
    var cardID: String
    var filename: String
    var data: Data
    var received = 0
    var status: Status = .sending

    var fraction: Double {
        data.isEmpty ? 1 : min(1, Double(received) / Double(data.count))
    }
}

/// Notes waiting for their images.
struct HeldDetails {
    var projectID: String
    var text: String
}

enum PendingImage {
    static let scheme = "pending"

    static func markdown(name: String, uploadID: String) -> String {
        let clean = name.replacingOccurrences(of: "]", with: "").replacingOccurrences(of: "\n", with: " ")
        return "![\(clean.isEmpty ? "image" : clean)](\(scheme):\(uploadID))"
    }

    /// Every upload id the text names, in order.
    static func ids(in text: String) -> [String] {
        let ns = text as NSString
        return pattern.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range(at: 1)) }
    }

    private static let pattern = try! NSRegularExpression(pattern: "\\]\\(pending:([0-9A-Za-z-]+)\\)")
}

/// The key an image is cached under: one attachment can be wanted as a
/// thumbnail and at full size at once.
enum ImageKey {
    static func of(_ attachmentID: String, maxEdge: Int?) -> String {
        "\(attachmentID.uppercased())@\(maxEdge ?? 0)"
    }
}

extension BoardConnection {

    // MARK: - A card in full

    /// Opens `cardID` for the card screen: asked for now, and asked for again
    /// whenever its board moves until `closeCard`.
    func open(cardID: String, in projectID: String) {
        openCard = (projectID, cardID)
        requestCard(projectID: projectID, cardID: cardID)
    }

    func closeCard() {
        openCard = nil
    }

    func requestCard(projectID: String, cardID: String) {
        send(.requestCard(projectID: projectID, cardID: cardID))
    }

    // MARK: - Home

    func requestOverview() {
        send(.requestOverview)
    }

    /// A busy board sends an event per keystroke on the Mac. Home only needs
    /// to settle, not to follow along.
    func refreshOverviewSoon() {
        overviewRefresh?.cancel()
        overviewRefresh = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.requestOverview()
            self?.send(.listProjects)
        }
    }

    // MARK: - Creating a card

    /// Creates a card, then calls `then` with the id the Mac gave it. The Mac
    /// mints ids, so anything that needs the card — its fields, its photos —
    /// waits for the answer.
    func createCard(in projectID: String, columnID: String, title: String,
                    then: @escaping (String) -> Void) {
        guard let requestID = mutate(.createCard(columnID: columnID, title: title, details: ""), in: projectID)
        else { return }
        afterCreate[requestID] = then
    }

    // MARK: - Images out

    /// Starts sending an image for a card and returns its upload id, which is
    /// also the id its `pending:` line in the notes carries.
    @discardableResult
    func upload(_ data: Data, filename: String, preview: UIImage?, cardID: String, in projectID: String,
                uploadID: String = UUID().uuidString) -> String {
        uploads[uploadID] = UploadState(projectID: projectID, cardID: cardID, filename: filename, data: data)
        if let preview { localImages[uploadID] = preview }
        sendPieces(of: uploadID)
        return uploadID
    }

    /// Keeps the picture for an image that has no card to go to yet — a new
    /// card's photo, before the card exists.
    func stage(_ image: UIImage, as uploadID: String) {
        localImages[uploadID] = image
    }

    func retryUpload(_ uploadID: String) {
        guard uploads[uploadID] != nil else { return }
        uploads[uploadID]?.status = .sending
        uploads[uploadID]?.received = 0
        sendPieces(of: uploadID)
    }

    /// Every image still travelling, from the start: the Mac drops a half-sent
    /// image with the connection that was sending it.
    func resumeUploads() {
        for (id, upload) in uploads where upload.status == .sending {
            uploads[id]?.received = 0
            sendPieces(of: id)
        }
    }

    private func sendPieces(of uploadID: String) {
        guard state.isConnected, let upload = uploads[uploadID] else { return }
        guard upload.data.count <= WireImageTransfer.maxUploadBytes else {
            uploads[uploadID]?.status = .failed("That image is too large to send.")
            flushHeldDetails(for: upload.cardID)
            return
        }
        for piece in WireImageTransfer.pieces(of: upload.data) {
            send(.uploadChunk(WireUploadChunk(
                uploadID: uploadID, projectID: upload.projectID, cardID: upload.cardID,
                filename: upload.filename, totalBytes: upload.data.count,
                offset: piece.offset, data: piece.data, isLast: piece.isLast
            )))
        }
    }

    func uploadFinished(_ uploadID: String, attachmentID: String) {
        guard let upload = uploads[uploadID] else { return }
        uploads[uploadID]?.received = upload.data.count
        uploads[uploadID]?.status = .done(attachmentID: attachmentID)
        // The picture we already have is the picture the Mac now has.
        if let image = localImages[uploadID] {
            images[ImageKey.of(attachmentID, maxEdge: nil)] = image
        }
        flushHeldDetails(for: upload.cardID)
    }

    /// True while any image the text names is still on its way.
    func isWaitingForImages(_ text: String) -> Bool {
        PendingImage.ids(in: text).contains { uploads[$0]?.status == .sending }
    }

    // MARK: - Saving notes

    /// Saves a card's notes, holding them until every image they name has
    /// arrived. `previous` is what the notes were, so an unchanged save sends
    /// nothing.
    func saveDetails(_ text: String, cardID: String, in projectID: String, previous: String? = nil) {
        heldDetails[cardID] = HeldDetails(projectID: projectID, text: text)
        flushHeldDetails(for: cardID, previous: previous)
    }

    /// Sends held notes once nothing they name is still travelling. A photo
    /// that failed is dropped from them rather than holding them forever.
    func flushHeldDetails(for cardID: String, previous: String? = nil) {
        guard let held = heldDetails[cardID], !isWaitingForImages(held.text) else { return }
        heldDetails[cardID] = nil

        // Each pending line becomes its attachment, or — if that image never
        // made it — goes, rather than leaving a reference to nothing.
        var lines: [String] = []
        for line in held.text.components(separatedBy: "\n") {
            guard let id = PendingImage.ids(in: line).first else { lines.append(line); continue }
            if case .done(let attachmentID) = uploads[id]?.status {
                lines.append(line.replacingOccurrences(of: "\(PendingImage.scheme):\(id)",
                                                       with: "\(AttachmentReferences.scheme):\(attachmentID)"))
            }
        }
        let text = lines.joined(separator: "\n")
        for id in PendingImage.ids(in: held.text) {
            uploads[id] = nil
        }
        // The Mac appended each image's reference as it arrived, so even a
        // save that changes nothing else must go out when it placed any.
        if text != previous || held.text != text {
            mutate(.setDetails(cardID: cardID, details: text), in: held.projectID)
        }
    }

    // MARK: - Images in

    /// The image, if it is here; otherwise asks for it and returns nil, and
    /// the view redraws when it arrives.
    func image(_ attachmentID: String, in projectID: String, maxEdge: Int?) -> UIImage? {
        let key = ImageKey.of(attachmentID, maxEdge: maxEdge)
        if let image = images[key] { return image }
        // A full-size copy serves a thumbnail too.
        if maxEdge != nil, let full = images[ImageKey.of(attachmentID, maxEdge: nil)] { return full }
        if !requestedImages.contains(key), state.isConnected {
            requestedImages.insert(key)
            // Asked for on the next turn: this is called while a view draws.
            Task { @MainActor [weak self] in
                self?.send(.requestAttachment(projectID: projectID, attachmentID: attachmentID, maxEdge: maxEdge))
            }
        }
        return nil
    }

    func receive(_ chunk: WireAttachmentChunk) {
        let key = ImageKey.of(chunk.attachmentID, maxEdge: chunk.maxEdge)
        var data = chunk.offset == 0 ? Data() : (incomingImages[key] ?? Data())
        guard data.count == chunk.offset else {
            // A piece went missing; ask again next time it is drawn.
            incomingImages[key] = nil
            requestedImages.remove(key)
            return
        }
        data.append(chunk.data)
        guard chunk.isLast else { incomingImages[key] = data; return }
        incomingImages[key] = nil
        requestedImages.remove(key)
        if let image = UIImage(data: data) { images[key] = image }
    }

    /// An image the Mac no longer has. Not worth a banner: the notes still
    /// show its name.
    func imageRequestFailed(_ requestID: String) -> Bool {
        let prefix = requestID.uppercased() + "@"
        let matching = requestedImages.filter { $0.hasPrefix(prefix) }
        guard !matching.isEmpty else { return false }
        requestedImages.subtract(matching)
        return true
    }

    // MARK: - The phone's guess

    /// `applyLocally` for an open card: the card screen shows the edit at once,
    /// and the Mac's answer replaces it a moment later.
    func applyToDetail(_ mutation: BoardMutation) {
        guard let cardID = mutation.cardID, var detail = cardDetails[cardID] else { return }
        defer { cardDetails[cardID] = detail }
        switch mutation {
        case .setTitle(_, let title):         detail.card.title = title
        case .setDetails(_, let details):     detail.card.details = details
        case .setPriority(_, let priority):   detail.card.priority = priority
        case .setRequested(_, let requested): detail.card.requested = requested
        case .setDueDate(_, let dueDate):     detail.card.dueDate = dueDate
        case .setOwner(_, let owner):         detail.card.owner = owner.isEmpty ? nil : owner
        case .setTags(_, let tags):           detail.card.tags = tags
        case .moveCard(_, let columnID, _):   detail.columnID = columnID
        case .setSubtask(_, let subtaskID, let done):
            if let index = detail.subtasks.firstIndex(where: { $0.id == subtaskID }) {
                detail.subtasks[index].done = done
            }
        case .addSubtask(_, let title):
            detail.subtasks.append(WireSubtask(id: "local-\(UUID().uuidString)", title: title, done: false))
        case .deleteSubtask(_, let subtaskID):
            detail.subtasks.removeAll { $0.id == subtaskID }
        case .addNote(_, let note):
            detail.activity.insert(WireActivity(id: UUID().uuidString, date: .now, actor: "You",
                                                summary: "Added a note", note: note), at: 0)
        case .deleteCard, .createCard, .unrecognized:
            break
        }
        detail.card.subtaskCount = detail.subtasks.count
        detail.card.subtasksDone = detail.subtasks.filter(\.done).count
    }
}
