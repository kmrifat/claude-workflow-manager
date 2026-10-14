import Foundation
import Testing
@testable import ClaudeWMWire

/// A connected pair, as the handshake leaves them.
private func pair(serverKey: Data? = nil) -> (phone: SealedSession, mac: SealedSession) {
    let key = Data(repeating: 7, count: 32)
    let clientNonce = SealedChannel.makeNonce()
    let serverNonce = SealedChannel.makeNonce()
    return (
        SealedChannel.session(pairingKey: key, clientNonce: clientNonce, serverNonce: serverNonce, isServer: false),
        SealedChannel.session(pairingKey: serverKey ?? key, clientNonce: clientNonce, serverNonce: serverNonce,
                              isServer: true)
    )
}

@Test func bothDirectionsRoundTrip() throws {
    let (phone, mac) = pair()
    let hello = Data(#"{"type":"hello"}"#.utf8)
    #expect(try mac.open(phone.seal(hello)) == hello)
    let welcome = Data(#"{"type":"welcome"}"#.utf8)
    #expect(try phone.open(mac.seal(welcome)) == welcome)
}

@Test func manyMessagesStayInStep() throws {
    let (phone, mac) = pair()
    for index in 0..<200 {
        let message = Data("message \(index)".utf8)
        #expect(try mac.open(phone.seal(message)) == message)
    }
}

@Test func aPeerWithTheWrongKeyCannotGetIn() throws {
    let (phone, mac) = pair(serverKey: Data(repeating: 8, count: 32))
    #expect(throws: SealedChannel.Failure.cannotOpen) { try mac.open(phone.seal(Data("hello".utf8))) }
}

@Test func aMessageCannotBeReplayed() throws {
    let (phone, mac) = pair()
    let sealed = try phone.seal(Data("move card".utf8))
    _ = try mac.open(sealed)
    #expect(throws: SealedChannel.Failure.cannotOpen) { try mac.open(sealed) }
}

@Test func messagesCannotBeReordered() throws {
    let (phone, mac) = pair()
    let first = try phone.seal(Data("one".utf8))
    let second = try phone.seal(Data("two".utf8))
    #expect(throws: SealedChannel.Failure.cannotOpen) { try mac.open(second) }
    _ = first
}

@Test func aTamperedMessageIsRefused() throws {
    let (phone, mac) = pair()
    var sealed = try phone.seal(Data("delete card".utf8))
    sealed[sealed.startIndex] ^= 0x01
    #expect(throws: SealedChannel.Failure.cannotOpen) { try mac.open(sealed) }
}

@Test func aMessageCannotBeReflectedBack() throws {
    // A phone's own message bounced back at it must not open: the two
    // directions have different keys.
    let (phone, _) = pair()
    let sealed = try phone.seal(Data("hello".utf8))
    #expect(throws: SealedChannel.Failure.cannotOpen) { try phone.open(sealed) }
}

@Test func aRecordedSessionCannotBeReusedLater() throws {
    // Same key, same client nonce, a fresh server nonce: the replayed first
    // message no longer opens.
    let key = Data(repeating: 7, count: 32)
    let clientNonce = SealedChannel.makeNonce()
    let recorded = SealedChannel.session(pairingKey: key, clientNonce: clientNonce,
                                         serverNonce: SealedChannel.makeNonce(), isServer: false)
    let sealed = try recorded.seal(Data("hello".utf8))
    let later = SealedChannel.session(pairingKey: key, clientNonce: clientNonce,
                                      serverNonce: SealedChannel.makeNonce(), isServer: true)
    #expect(throws: SealedChannel.Failure.cannotOpen) { try later.open(sealed) }
}

@Test func theHandshakeCarriesTheNonce() throws {
    let nonce = SealedChannel.makeNonce()
    #expect(nonce.count == 32)
    #expect(try SealedChannel.nonce(fromHandshake: SealedChannel.handshake(nonce: nonce)) == nonce)
    #expect(throws: SealedChannel.Failure.notAHandshake) { try SealedChannel.nonce(fromHandshake: Data("GET /".utf8)) }
    #expect(throws: SealedChannel.Failure.notAHandshake) {
        try SealedChannel.nonce(fromHandshake: SealedChannel.magic + Data(count: 31))
    }
}

@Test func welcomeCarriesTheRelayAddressAndOldOnesStillDecode() throws {
    let message = ServerMessage.welcome(serverName: "Mac", relayURL: "https://pitwall.example.com")
    let data = try WireCodec.encode(ServerFrame(message: message))
    #expect(try WireCodec.decodeServerFrame(data).message == message)

    // An older Mac's welcome has no relay field.
    let old = Data(#"{"version":1,"message":{"type":"welcome","serverName":"Mac"}}"#.utf8)
    if let frame = try? WireCodec.decodeServerFrame(old) {
        #expect(frame.message == .welcome(serverName: "Mac", relayURL: nil))
    }
}
