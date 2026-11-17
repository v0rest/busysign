import Foundation
import Testing
@testable import BusySignCore

@Suite struct VersionTests {
    @Test func versionMatchesFile() throws {
        // Tests/BusySignCoreTests/VersionTests.swift -> repo root
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let raw = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
        #expect(raw.trimmingCharacters(in: .whitespacesAndNewlines) == Version.current)
    }
}
