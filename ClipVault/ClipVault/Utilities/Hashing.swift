import CryptoKit
import Foundation

enum Hashing {
    static func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func sha256(string: String) -> String {
        let data = Data(string.utf8)
        return sha256(data: data)
    }
}
