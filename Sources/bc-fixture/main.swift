import CoworkFixtures
import Foundation

// Builds a sample Mac for screenshots and manual testing:
//
//     bc-fixture <empty-folder>
//     BC_FIXTURE_ROOT=<empty-folder> open BetterClaude.app   (debug builds only)
//
// Everything it writes is invented. It refuses a folder that already has content.

let arguments = CommandLine.arguments.dropFirst()
guard let path = arguments.first else {
    FileHandle.standardError.write(Data("usage: bc-fixture <empty-folder>\n".utf8))
    exit(64)
}
let root = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
do {
    try FixtureHome(root: root).make()
    print(root.resolvingSymlinksInPath().path)
} catch {
    FileHandle.standardError.write(Data("bc-fixture: \(error)\n".utf8))
    exit(1)
}
