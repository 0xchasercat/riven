import Testing
@testable import BentoCore

@Suite("Engine contracts")
struct EngineContractTests {
    @Test("Ghostty contract uses linked libghostty-vt")
    func ghosttyUsesLinkedLibGhosttyVt() {
        let engine = GhosttyEngineContract()

        #expect(engine.status == .linked(version: "libghostty-vt"))
        #expect(throws: Never.self) {
            try engine.makePane(id: PaneID("term"), cwd: "/repo", command: nil)
        }
    }

    @Test("STTextView contract is the native editor engine")
    func stTextViewIsNativeEditorEngine() {
        let engine = STTextViewEngineContract()

        #expect(engine.status == .linked(version: "2.x"))
        #expect(throws: Never.self) {
            try engine.openDocument(path: "/repo/Package.swift")
        }
    }
}
