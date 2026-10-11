import Foundation

/// Programs that `go run` and `cargo run` compile and start. They have arbitrary names, so a
/// server like that is recognised by where its binary lives, not by what it is called.
enum BuildOutput {
    case goRun
    case cargo

    // `go run` builds into $TMPDIR/go-build123456/b001/exe/<name> and deletes it when it exits.
    private static let goRunPattern = #"/go-build[0-9]+/b[0-9]+/exe/"#
    // target/debug/<name>, target/release/<name>, target/<triple>/release/<name>, target/debug/deps/<name>
    private static let cargoPattern = #"/target/(?:[^/\s]+/)?(?:debug|release)/"#

    /// What a program (or a whole command line that starts with one) is, if it's a build output.
    static func kind(ofExecutable text: String) -> BuildOutput? {
        if text.range(of: goRunPattern, options: .regularExpression) != nil { return .goRun }
        if text.range(of: cargoPattern, options: .regularExpression) != nil { return .cargo }
        return nil
    }

    /// The command that builds and starts such a program, so it is the right thing to run again.
    static func isBuilder(_ executable: String) -> Bool {
        ["go", "cargo", "cargo-watch"].contains((executable as NSString).lastPathComponent)
    }
}
