import Foundation

func option(_ name: String) -> String? {
  guard let index = CommandLine.arguments.firstIndex(of: name), index + 1 < CommandLine.arguments.count else { return nil }
  return CommandLine.arguments[index + 1]
}
func emit(_ value: [String: Any]) {
  let data = try! JSONSerialization.data(withJSONObject: value)
  FileHandle.standardOutput.write(data + Data([10]))
}
guard let directory = option("--downloader-data-dir"), let helper = option("--downloader-helper"),
      (try? URL(fileURLWithPath: directory).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
      (try? FileManager.default.contentsOfDirectory(atPath: directory))?.isEmpty == true,
      helper.hasSuffix("Helpers/DownloadCenter.app/Contents/MacOS/chengying-download-center-helper") else {
  emit(["type": "failed", "error": "The isolated cold-start fixture was not prepared correctly."])
  exit(2)
}
emit(["type": "ready", "protocol_version": 1])
while let line = readLine(), let data = line.data(using: .utf8),
      let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
  if request["command"] as? String == "shutdown" { break }
  emit(["type": "status", "id": request["id"] as? String ?? "", "runtime_ready": false, "models": []])
}
