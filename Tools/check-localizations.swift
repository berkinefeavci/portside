// Usage: swift Tools/check-localizations.swift <stringsdata-dir> <Localization-dir> [--dump]
//
// Compares the localizable keys the Swift compiler extracted from the sources
// (`-emit-localized-strings`, one .stringsdata file per source file) with every
// Localization/<lang>.lproj/Localizable.strings. Fails when a language misses a key, or when a
// translation of a key with arguments uses different format specifiers (a mismatch can crash at runtime).
// Keys that no longer occur in the sources are reported but do not fail the check.
import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: check-localizations.swift <stringsdata-dir> <Localization-dir> [--dump]\n".utf8))
    exit(2)
}
let extractedDirectory = URL(fileURLWithPath: arguments[1])
let localizationDirectory = URL(fileURLWithPath: arguments[2])
let dump = arguments.contains("--dump")

func files(in directory: URL, withExtension pathExtension: String) -> [URL] {
    guard let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [] }
    return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == pathExtension }
}

/// .stringsdata is JSON: {"source": …, "tables": {"Localizable": [{"key": …, "comment": …}]}, "version": 1}.
func extractedKeys() -> Set<String> {
    var keys = Set<String>()
    let dataFiles = files(in: extractedDirectory, withExtension: "stringsdata")
    guard !dataFiles.isEmpty else {
        print("check-localizations: no .stringsdata files under \(extractedDirectory.path)")
        exit(1)
    }
    for file in dataFiles {
        guard let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tables = object["tables"] as? [String: Any] else {
            print("check-localizations: unreadable \(file.lastPathComponent): \(String(decoding: (try? Data(contentsOf: file))?.prefix(400) ?? Data(), as: UTF8.self))")
            exit(1)
        }
        guard let entries = tables["Localizable"] as? [[String: Any]] else { continue }
        for entry in entries { if let key = entry["key"] as? String { keys.insert(key) } }
    }
    return keys
}

/// printf-style specifiers in order, e.g. "%@ ve %lld%%" → ["%@", "%lld"]. "%%" is a literal.
func specifiers(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: "%(?:%|(?:\\d+\\$)?[-+ 0#]*\\d*(?:\\.\\d+)?(?:hh|h|ll|l|q|L|z|t|j)?[@dDiuUxXoOfeEgGcCsSpaA])")
    let range = NSRange(text.startIndex..., in: text)
    return pattern.matches(in: text, range: range).compactMap { match -> String? in
        let token = String(text[Range(match.range, in: text)!])
        guard token != "%%" else { return nil }
        // Positional "%1$@" and plain "%@" are the same specifier for comparison.
        return token.replacingOccurrences(of: #"^%\d+\$"#, with: "%", options: .regularExpression)
    }
}

let keys = extractedKeys()
if dump {
    print("check-localizations: \(keys.count) extracted keys")
    for key in keys.sorted() { print("KEY\t" + key.replacingOccurrences(of: "\n", with: "\\n")) }
}

var failed = false
let languages = files(in: localizationDirectory, withExtension: "strings")
    .filter { $0.lastPathComponent == "Localizable.strings" }
    .sorted { $0.path < $1.path }
if languages.isEmpty { print("check-localizations: no Localizable.strings under \(localizationDirectory.path)"); failed = true }
for file in languages {
    let language = file.deletingLastPathComponent().deletingPathExtension().lastPathComponent
    guard let table = NSDictionary(contentsOf: file) as? [String: String] else {
        print("check-localizations: \(language): Localizable.strings does not parse"); failed = true; continue
    }
    let missing = keys.subtracting(table.keys).sorted()
    let stale = Set(table.keys).subtracting(keys).sorted()
    // Keys without arguments are looked up but never passed through String(format:), so a literal
    // "%" in their translation is fine; only keys that carry arguments must match specifier for specifier.
    let mismatched = table.filter { keys.contains($0.key) && !specifiers($0.key).isEmpty
        && specifiers($0.key).sorted() != specifiers($0.value).sorted() }
        .map(\.key).sorted()
    print("check-localizations: \(language): \(table.count) entries, \(missing.count) missing, \(mismatched.count) specifier mismatches, \(stale.count) unused")
    for key in missing { print("MISSING\t\(language)\t" + key.replacingOccurrences(of: "\n", with: "\\n")) }
    for key in mismatched { print("SPECIFIER\t\(language)\t\(key)\t→\t\(table[key]!)") }
    for key in stale { print("UNUSED\t\(language)\t" + key.replacingOccurrences(of: "\n", with: "\\n")) }
    if !missing.isEmpty || !mismatched.isEmpty { failed = true }
}
exit(failed ? 1 : 0)
