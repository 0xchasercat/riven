import Darwin
import Foundation

public struct PseudoTerminalSession: Sendable {
    public var executable: String
    public var arguments: [String]
    public var cwd: String

    public init(executable: String, arguments: [String], cwd: String) {
        self.executable = executable
        self.arguments = arguments
        self.cwd = cwd
    }

    public func runUntilExit(timeout: Duration) async throws -> String {
        var master: Int32 = -1
        var slave: Int32 = -1
        guard openpty(&master, &slave, nil, nil, nil) == 0 else {
            throw PseudoTerminalError.openptyFailed(errno)
        }
        defer { close(master) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        let masterHandle = FileHandle(fileDescriptor: master, closeOnDealloc: false)
        try process.run()
        try slaveHandle.close()

        async let output = readAll(from: masterHandle)
        async let exit: Void = waitForExit(process, timeout: timeout)
        _ = try await exit
        return try await output
    }

    private func readAll(from handle: FileHandle) async throws -> String {
        await Task.detached(priority: .userInitiated) {
            var data = Data()
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    private func waitForExit(_ process: Process, timeout: Duration) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                process.waitUntilExit()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                if process.isRunning {
                    process.terminate()
                    throw PseudoTerminalError.timedOut
                }
            }
            try await group.next()
            group.cancelAll()
        }
    }
}

public enum PseudoTerminalError: Error, Equatable {
    case openptyFailed(Int32)
    case timedOut
    case alreadyRunning
    case spawnFailed(String)
}

/// Long-lived PTY-backed child process used by the BentoAgent broker.
///
/// Unlike ``PseudoTerminalSession`` (which reads until the process exits and
/// returns the captured string), this type keeps the master fd open, streams
/// output via an `AsyncStream<Data>`, accepts incoming writes, supports
/// `TIOCSWINSZ` resizes, and surfaces the child exit status via a separate
/// stream.
public final class LivePseudoTerminal: @unchecked Sendable {
    public struct Spec: Sendable {
        public var executable: String
        public var arguments: [String]
        public var cwd: String
        public var environment: [String: String]
        public var columns: UInt16
        public var rows: UInt16

        public init(
            executable: String,
            arguments: [String],
            cwd: String,
            environment: [String: String] = [:],
            columns: UInt16 = 80,
            rows: UInt16 = 24
        ) {
            self.executable = executable
            self.arguments = arguments
            self.cwd = cwd
            self.environment = environment
            self.columns = columns
            self.rows = rows
        }
    }

    private let spec: Spec
    private let process = Process()
    private var masterFD: Int32 = -1
    private let stateLock = NSLock()
    private var didStart = false
    private var didClose = false

    private let outputContinuation: AsyncStream<Data>.Continuation
    public let output: AsyncStream<Data>

    private let exitContinuation: AsyncStream<Int32>.Continuation
    public let exits: AsyncStream<Int32>

    public init(spec: Spec) {
        self.spec = spec
        var outCont: AsyncStream<Data>.Continuation!
        self.output = AsyncStream<Data> { outCont = $0 }
        self.outputContinuation = outCont

        var exitCont: AsyncStream<Int32>.Continuation!
        self.exits = AsyncStream<Int32> { exitCont = $0 }
        self.exitContinuation = exitCont
    }

    deinit {
        closeMaster()
    }

    public func start() throws {
        stateLock.lock()
        if didStart {
            stateLock.unlock()
            throw PseudoTerminalError.alreadyRunning
        }
        didStart = true
        stateLock.unlock()

        var master: Int32 = -1
        var slave: Int32 = -1
        var winsize = winsize(ws_row: spec.rows, ws_col: spec.columns, ws_xpixel: 0, ws_ypixel: 0)
        let result = withUnsafeMutablePointer(to: &winsize) { wsPtr in
            openpty(&master, &slave, nil, nil, wsPtr)
        }
        guard result == 0 else {
            throw PseudoTerminalError.openptyFailed(errno)
        }
        self.masterFD = master

        let slaveHandle = FileHandle(fileDescriptor: slave, closeOnDealloc: true)
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.currentDirectoryURL = URL(fileURLWithPath: spec.cwd)
        if !spec.environment.isEmpty {
            var env = ProcessInfo.processInfo.environment
            for (k, v) in spec.environment { env[k] = v }
            process.environment = env
        }
        process.standardInput = slaveHandle
        process.standardOutput = slaveHandle
        process.standardError = slaveHandle

        process.terminationHandler = { [outputContinuation, exitContinuation] proc in
            exitContinuation.yield(proc.terminationStatus)
            exitContinuation.finish()
            outputContinuation.finish()
        }

        do {
            try process.run()
        } catch {
            closeMaster()
            try? slaveHandle.close()
            throw PseudoTerminalError.spawnFailed(String(describing: error))
        }
        // The slave fd is now owned by the child; close our copy so EOF
        // propagates to the master once the child exits.
        try? slaveHandle.close()

        startReaderThread()
    }

    public func write(_ data: Data) {
        stateLock.lock()
        let fd = masterFD
        let closed = didClose
        stateLock.unlock()
        guard !closed, fd >= 0, !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var cursor = base
            while remaining > 0 {
                let n = Darwin.write(fd, cursor, remaining)
                if n <= 0 {
                    if errno == EINTR { continue }
                    return
                }
                cursor = cursor.advanced(by: n)
                remaining -= n
            }
        }
    }

    public func resize(columns: UInt16, rows: UInt16) {
        stateLock.lock()
        let fd = masterFD
        stateLock.unlock()
        guard fd >= 0 else { return }
        var ws = winsize(ws_row: rows, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0)
        _ = withUnsafeMutablePointer(to: &ws) { ptr in
            ioctl(fd, TIOCSWINSZ, ptr)
        }
    }

    public func terminate() {
        if process.isRunning {
            process.terminate()
        }
        closeMaster()
    }

    public var isRunning: Bool { process.isRunning }

    private func startReaderThread() {
        let fd = masterFD
        let cont = outputContinuation
        let thread = Thread {
            let bufSize = 8 * 1024
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
            defer { buf.deallocate() }
            while true {
                let n = Darwin.read(fd, buf, bufSize)
                if n > 0 {
                    cont.yield(Data(bytes: buf, count: n))
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                // EOF or error — terminate the stream. Exit status arrives via
                // the terminationHandler.
                break
            }
        }
        thread.name = "LivePseudoTerminal.reader"
        thread.start()
    }

    private func closeMaster() {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard !didClose else { return }
        didClose = true
        if masterFD >= 0 {
            close(masterFD)
            masterFD = -1
        }
    }
}
