// Decrypts ONE reported huddle photo for moderation review.
//
// HuddlePals photos are end-to-end encrypted: the Storage object is an AES-GCM
// "combined" box (12-byte nonce ‖ ciphertext ‖ 16-byte tag) under a per-photo
// key that only the huddle's members hold. When a member reports a photo,
// their device attaches that photo's key (reports.photo_key, base64). That key
// opens this one file and nothing else. See README.md next to this script.
//
// Usage (macOS, no dependencies — CryptoKit ships with the OS):
//   swift tools/decrypt_reported_photo/decrypt_reported_photo.swift <downloaded-object> <photo_key|-> <output.jpg>
// Pass "-" as the key to read it from stdin (keeps it out of shell history).
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

let args = CommandLine.arguments
guard args.count == 4 else {
    fail("usage: decrypt_reported_photo.swift <downloaded-object> <photo_key|-> <output.jpg>")
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

let jpeg: Data
do {
    let box = try AES.GCM.SealedBox(combined: ciphertext)
    jpeg = try AES.GCM.open(box, using: SymmetricKey(data: keyData))
} catch {
    fail("decryption failed — wrong key for this file, or not a HuddlePals photo object (\(error))")
}

guard FileManager.default.createFile(atPath: outputPath, contents: jpeg) else {
    fail("can't write \(outputPath)")
}
let isJPEG = jpeg.starts(with: [0xFF, 0xD8, 0xFF])
print("wrote \(outputPath) (\(jpeg.count) bytes\(isJPEG ? ", JPEG" : ", not a JPEG?"))")
