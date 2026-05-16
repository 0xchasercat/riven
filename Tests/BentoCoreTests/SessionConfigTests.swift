import Foundation
import Testing
@testable import BentoCore

@Suite("Task pane session config")
struct SessionConfigTests {
    @Test("parses alpha task pane YAML")
    func parseSessionYAML() throws {
        let yaml = """
        version: 1
        panes:
          - name: api
            cwd: backend
            cmd: cargo watch -x run
            restart: never
          - name: web
            cwd: frontend
            cmd: bun dev
        """

        let config = try SessionConfig.parse(yaml)

        #expect(config.version == 1)
        #expect(config.panes.count == 2)
        #expect(config.panes[0] == TaskPaneConfig(name: "api", cwd: "backend", command: "cargo watch -x run", restart: .never))
        #expect(config.panes[1].restart == .never)
    }

    @Test("rejects unsupported schema versions")
    func rejectsUnsupportedVersion() throws {
        let yaml = """
        version: 2
        panes:
          - name: api
            cmd: cargo run
        """

        #expect(throws: SessionConfigError.unsupportedVersion(2)) {
            _ = try SessionConfig.parse(yaml)
        }
    }

    @Test("trust records are per project path")
    func trustRecordsArePerProject() throws {
        let store = ProjectTrustStore()
        let project = URL(fileURLWithPath: "/tmp/bento-alpha")

        #expect(store.isTrusted(projectRoot: project) == false)
        store.trust(projectRoot: project)
        #expect(store.isTrusted(projectRoot: project) == true)
        #expect(store.isTrusted(projectRoot: URL(fileURLWithPath: "/tmp/other")) == false)
    }
}
