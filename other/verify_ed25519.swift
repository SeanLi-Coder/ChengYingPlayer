// Verify release bytes with a public key only; never access signing credentials.
import CryptoKit
import Foundation

do {
  guard CommandLine.arguments.count == 4,
        let publicBytes = Data(base64Encoded: CommandLine.arguments[1]), publicBytes.count == 32,
        let signature = Data(base64Encoded: CommandLine.arguments[2]), signature.count == 64 else {
    throw NSError(domain: "ReleaseSignature", code: 1)
  }
  let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
  let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3]), options: .mappedIfSafe)
  guard key.isValidSignature(signature, for: data) else {
    throw NSError(domain: "ReleaseSignature", code: 2)
  }
  print("Ed25519 public-key verification passed.")
} catch {
  fputs("Ed25519 public-key verification failed.\n", stderr)
  exit(1)
}
