//
//  SealedChannel.swift
//  ClaudeWMWire
//
//  End-to-end encryption for a phone reaching its Mac through a Cloudflare
//  Tunnel.
//
//  On the LAN and over Tailscale the connection is TLS with the pairing key as
//  a pre-shared key, so nothing but the two devices ever sees a frame. A
//  Cloudflare Tunnel cannot carry that: Cloudflare terminates TLS at its edge
//  with its own certificate, and a phone cannot run `cloudflared` to tunnel raw
//  TCP. So the tunnel carries an ordinary `wss://` connection, and every
//  WebSocket message inside it is sealed with a key only the two devices can
//  derive — Cloudflare forwards ciphertext and learns nothing but sizes and
//  timing.
//
//  ## The handshake
//
//      phone → Mac   "PWS1" ‖ client nonce (32 random bytes)
//      Mac → phone   "PWS1" ‖ server nonce (32 random bytes)
//
//  Each side then derives two keys with HKDF-SHA256 from the pairing key,
//  salted with both nonces — one per direction. Every later message is
//  ChaCha20-Poly1305, its nonce an implicit per-direction counter.
//
//  What that buys, and why there is nothing more to it:
//
//  - **A peer without the pairing key cannot get in.** Its first sealed
//    message fails to open and the Mac closes the socket before any board code
//    runs — the same promise TLS-PSK makes on the LAN.
//  - **Nothing can be replayed.** Fresh nonces from *both* sides mean a
//    recorded session's keys never recur; the counter means no message can be
//    repeated, dropped or reordered within one.
//  - **No proof messages are needed.** The first sealed message in each
//    direction *is* the proof: only a holder of the key could have made it.
//
//  Pure CryptoKit, no I/O — this package's rule. The two transports call it.
//

import Foundation
import CryptoKit

public enum SealedChannel {
    public static let magic = Data("PWS1".utf8)
    public static let nonceLength = 32

    public enum Failure: Error, Equatable {
        case notAHandshake
        case cannotOpen
    }

    /// 32 fresh random bytes.
    public static func makeNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// The handshake message: magic and nonce.
    public static func handshake(nonce: Data) -> Data { magic + nonce }

    /// The nonce in a handshake message, or a failure if it is not one.
    public static func nonce(fromHandshake data: Data) throws -> Data {
        guard data.count == magic.count + nonceLength, data.prefix(magic.count) == magic else {
            throw Failure.notAHandshake
        }
        return Data(data.suffix(nonceLength))
    }

    /// The two directions' keys. Both sides compute the same pair; `isServer`
    /// only decides which is used for sending.
    public static func session(
        pairingKey: Data,
        clientNonce: Data,
        serverNonce: Data,
        isServer: Bool
    ) -> SealedSession {
        let salt = clientNonce + serverNonce
        let ikm = SymmetricKey(data: pairingKey)
        let toServer = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                              info: Data("pitwall relay phone→mac v1".utf8), outputByteCount: 32)
        let toClient = HKDF<SHA256>.deriveKey(inputKeyMaterial: ikm, salt: salt,
                                              info: Data("pitwall relay mac→phone v1".utf8), outputByteCount: 32)
        return SealedSession(sending: isServer ? toClient : toServer, receiving: isServer ? toServer : toClient)
    }
}

/// One connection's keys and counters.
///
/// Sending and receiving each touch only their own counter, but a transport may
/// seal on one queue and open on another, so both sit behind a lock.
public final class SealedSession: @unchecked Sendable {
    private let sendingKey: SymmetricKey
    private let receivingKey: SymmetricKey
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private let lock = NSLock()

    init(sending: SymmetricKey, receiving: SymmetricKey) {
        self.sendingKey = sending
        self.receivingKey = receiving
    }

    public func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        let box = try ChaChaPoly.seal(plaintext, using: sendingKey, nonce: Self.nonce(sent))
        sent += 1
        return box.ciphertext + box.tag
    }

    /// Opens the next message. Throws — and the transport must then close —
    /// on anything not sealed by the peer as its very next message.
    public func open(_ sealed: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard sealed.count >= 16 else { throw SealedChannel.Failure.cannotOpen }
        do {
            let box = try ChaChaPoly.SealedBox(
                nonce: Self.nonce(received),
                ciphertext: sealed.prefix(sealed.count - 16),
                tag: sealed.suffix(16)
            )
            let plaintext = try ChaChaPoly.open(box, using: receivingKey)
            received += 1
            return plaintext
        } catch {
            throw SealedChannel.Failure.cannotOpen
        }
    }

    /// 12 bytes: four zero, then the counter, big-endian. Never reused, because
    /// each direction has its own key and its own counter.
    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}
