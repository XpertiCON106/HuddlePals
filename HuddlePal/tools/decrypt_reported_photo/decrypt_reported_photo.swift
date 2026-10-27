// Decrypts ONE reported huddle photo or video for moderation review.
//
// HuddlePals photos and videos are end-to-end encrypted: the Storage object
// is an AES-GCM "combined" box (12-byte nonce ‖ ciphertext ‖ 16-byte tag)
// under a per-deposit key that only the huddle's members hold. A video
// deposit is two objects under the same key: its poster (a JPEG) and its clip
// (an MP4). When a member reports a deposit, their device attaches that key
// (reports.photo_key, base64). It opens this deposit's files and nothing
// else. See README.md next to this script.
//
// Usage (macOS, no dependencies — CryptoKit ships with the OS):
//   swift tools/decrypt_reported_photo/decrypt_reported_photo.swift <downloaded-object> <photo_key|-> <output>
// Pass "-" as the key to read it from stdin (keeps it out of shell history).
// The output gets the extension of what's inside: .jpg for a photo or a
// poster, .mp4 for a video clip, whatever name you give it.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fail("usage: decrypt_reported_photo.swift <downloaded-object> <photo_key|-> <output>")
}
let inputPath = args[1], keyArgument = args[2], outputPath = args[3]

let keyText = keyArgument == "-"
    ? (readLine(strippingNewline: true) ?? "")
    : keyArgument
guard let keyData = Data(base64Encoded: keyText.trimmingCharacters(in: .whitespacesAndNewlines)),
      keyData.count == 32
else { fail("the photo key must be the base64 reports.photo_key value (32 bytes)") }

guard let ciphertext = FileManager.default.contents(atPath: inputPath) else {
    fail("can't read \(inputPath)")
}

let plaintext: Data
do {
    let box = try AES.GCM.SealedBox(combined: ciphertext)
    plaintext = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
} catch {
    fail("decryption failed — wrong key for this file, or not a HuddlePals object (\(error))")
}

/// What the decrypted bytes are: a JPEG starts FF D8 FF; an MP4 starts with
/// a box whose type (bytes 4–7) is "ftyp".
enum Kind {
    case photo, video, unknown
}
let kind: Kind
if plaintext.starts(with: [0xFF, 0xD8, 0xFF]) {
    kind = .photo
} else if plaintext.count >= 8, plaintext.dropFirst(4).prefix(4).elementsEqual("ftyp".utf8) {
    kind = .video
} else {
    kind = .unknown
}

var outputURL = URL(fileURLWithPath: outputPath)
let named = outputURL.pathExtension.lowercased()
switch kind {
case .photo where !["jpg", "jpeg"].contains(named):
    outputURL = outputURL.deletingPathExtension().appendingPathExtension("jpg")
case .video where named != "mp4":
    outputURL = outputURL.deletingPathExtension().appendingPathExtension("mp4")
default:
    break
}

guard FileManager.default.createFile(atPath: outputURL.path, contents: plaintext) else {
    fail("can't write \(outputURL.path)")
}
let description = switch kind {
case .photo: "a JPEG photo"
case .video: "an MP4 video clip"
case .unknown: "neither a JPEG nor an MP4?"
}
print("wrote \(outputURL.path) (\(plaintext.count) bytes, \(description))")
if outputURL.path != URL(fileURLWithPath: outputPath).path {
    print("note: named .\(outputURL.pathExtension) for what it holds, not \(outputPath)")
}
