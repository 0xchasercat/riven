import Foundation

public struct PaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(_ rawValue: String = UUID().uuidString) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public enum PaneKind: Hashable, Codable, Sendable {
    case terminal(TerminalPane)
    case editor(EditorPane)
}

public struct TerminalPane: Hashable, Codable, Sendable {
    public var command: String?
    public var cwd: String

    public init(command: String?, cwd: String) {
        self.command = command
        self.cwd = cwd
    }
}

public struct EditorPane: Hashable, Codable, Sendable {
    public var path: String
    public var cursorLine: Int
    public var cursorColumn: Int
    public var inheritedCWD: String?

    public init(path: String, cursorLine: Int = 1, cursorColumn: Int = 1, inheritedCWD: String? = nil) {
        self.path = path
        self.cursorLine = cursorLine
        self.cursorColumn = cursorColumn
        self.inheritedCWD = inheritedCWD
    }
}

public struct PaneDescriptor: Hashable, Codable, Sendable {
    public var id: PaneID
    public var name: String
    public var kind: PaneKind
    public var isFocused: Bool

    public init(id: PaneID = PaneID(), name: String, kind: PaneKind, isFocused: Bool = false) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isFocused = isFocused
    }

    public var terminal: TerminalPane? {
        if case let .terminal(value) = kind { value } else { nil }
    }

    public var editor: EditorPane? {
        if case let .editor(value) = kind { value } else { nil }
    }

    public var restorableCWD: String? {
        switch kind {
        case let .terminal(terminal):
            terminal.cwd
        case let .editor(editor):
            editor.inheritedCWD ?? URL(fileURLWithPath: editor.path).deletingLastPathComponent().path
        }
    }
}

public enum SplitDirection: String, Codable, Sendable {
    case right
    case down
}

public enum PaneNode: Hashable, Codable, Sendable {
    case leaf(PaneID)
    indirect case split(SplitDirection, PaneNode, PaneNode)
}

public enum PaneGraphError: Error, Equatable {
    case missingPane(PaneID)
}

public struct PaneGraph: Hashable, Codable, Sendable {
    public private(set) var panes: [PaneID: PaneDescriptor]
    public private(set) var rootNode: PaneNode
    public private(set) var focusedPaneID: PaneID

    public init(root: PaneDescriptor) {
        var focusedRoot = root
        focusedRoot.isFocused = true
        self.panes = [focusedRoot.id: focusedRoot]
        self.rootNode = .leaf(focusedRoot.id)
        self.focusedPaneID = focusedRoot.id
    }

    /// Internal initializer used by the pure functional operations in
    /// `PaneGraphOperations.swift` to rebuild a graph after a mutation.
    /// Not intended for use outside the module.
    init(panes: [PaneID: PaneDescriptor], rootNode: PaneNode, focusedPaneID: PaneID) {
        self.panes = panes
        self.rootNode = rootNode
        self.focusedPaneID = focusedPaneID
    }

    public func pane(_ id: PaneID) -> PaneDescriptor? {
        panes[id]
    }

    @discardableResult
    public mutating func split(_ id: PaneID, direction: SplitDirection) throws -> PaneID {
        guard let parent = panes[id] else {
            throw PaneGraphError.missingPane(id)
        }

        let childID = PaneID()
        let child = PaneDescriptor(
            id: childID,
            name: "\(parent.name) copy",
            kind: .terminal(TerminalPane(command: nil, cwd: parent.restorableCWD ?? NSHomeDirectory())),
            isFocused: true
        )

        panes[id]?.isFocused = false
        panes[childID] = child
        focusedPaneID = childID
        rootNode = replacingLeaf(id, in: rootNode, with: .split(direction, .leaf(id), .leaf(childID)))
        return childID
    }

    public mutating func flip(_ id: PaneID, to newKind: PaneKind) throws {
        guard var pane = panes[id] else {
            throw PaneGraphError.missingPane(id)
        }

        let inheritedCWD = pane.restorableCWD
        switch newKind {
        case .terminal:
            pane.kind = newKind
        case let .editor(editor):
            var editor = editor
            editor.inheritedCWD = editor.inheritedCWD ?? inheritedCWD
            pane.kind = .editor(editor)
        }
        panes[id] = pane
    }

    private func replacingLeaf(_ id: PaneID, in node: PaneNode, with replacement: PaneNode) -> PaneNode {
        switch node {
        case let .leaf(existing):
            existing == id ? replacement : node
        case let .split(direction, first, second):
            .split(direction, replacingLeaf(id, in: first, with: replacement), replacingLeaf(id, in: second, with: replacement))
        }
    }
}
