// Generate an ephemeral test-only seed without consulting the login Keychain.
import CryptoKit
import Foundation

let key = Curve25519.Signing.PrivateKey()
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try key.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("test-seed"))
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("test-seed").path)
try key.publicKey.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("test-public"))
