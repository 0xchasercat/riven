import Testing
@testable import BentoCore

@Suite("Ghostty bridge")
struct GhosttyBridgeTests {
    @Test("creates stable Bento-side handles for panes")
    func createsSessionHandle() throws {
        let bridge = GhosttyBridge()
        let paneID = PaneID("term")

        let handle = try bridge.createSession(id: paneID, cwd: "/repo", command: "zsh")

        #expect(handle.paneID == paneID)
        try bridge.resize(handle, columns: 100, rows: 30)
        try bridge.writeInput(Array("printf hello".utf8), to: handle)
        try bridge.close(handle)
    }

    @Test("validates resize and input before reaching C API")
    func validatesInput() throws {
        let bridge = GhosttyBridge()
        let handle = try bridge.createSession(id: PaneID("term"), cwd: "/repo", command: nil)

        #expect(throws: GhosttyBridgeError.invalidSize(columns: 0, rows: 24)) {
            try bridge.resize(handle, columns: 0, rows: 24)
        }
        #expect(throws: GhosttyBridgeError.emptyInput) {
            try bridge.writeInput([], to: handle)
        }
    }
}
