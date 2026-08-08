import Foundation

final class CodexAppServerClient {
    typealias JSONObject = [String: Any]
    typealias Completion = (Result<JSONObject, Error>) -> Void

    var onNotification: ((String, JSONObject) -> Void)?
    var onProtectedRequest: ((String, JSONObject) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let queue = DispatchQueue(label: "com.ranveer.droppy.codex-app-server")
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var nextRequestID = 1
    private var initializeRequestID: Int?
    private var isInitialized = false
    private var startCompletion: ((Result<Void, Error>) -> Void)?
    private var pending: [Int: Completion] = [:]

    var isRunning: Bool {
        queue.sync { process?.isRunning == true }
    }

    func start(completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.process?.isRunning == true, self.isInitialized {
                DispatchQueue.main.async { completion(.success(())) }
                return
            }
            if self.process?.isRunning == true {
                self.stopLocked()
            }

            guard let executableURL = Self.codexExecutableURL() else {
                DispatchQueue.main.async { completion(.failure(CodexFeatureError.unavailable)) }
                return
            }

            let process = Process()
            let input = Pipe()
            let output = Pipe()
            let errors = Pipe()
            process.executableURL = executableURL
            process.arguments = ["app-server"]
            process.standardInput = input
            process.standardOutput = output
            process.standardError = errors
            process.environment = Self.processEnvironment()
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

            self.process = process
            self.inputPipe = input
            self.outputPipe = output
            self.errorPipe = errors
            self.startCompletion = completion
            self.isInitialized = false
            self.outputBuffer.removeAll(keepingCapacity: true)
            self.errorBuffer.removeAll(keepingCapacity: true)

            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.consumeOutput(data) }
            }
            errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.errorBuffer.append(data) }
            }
            process.terminationHandler = { [weak self] process in
                self?.queue.async { self?.processTerminated(status: process.terminationStatus) }
            }

            do {
                try process.run()
                let requestID = self.sendRequestLocked(
                    method: "initialize",
                    params: [
                        "clientInfo": [
                            "name": "mission-control",
                            "title": "Mission Control",
                            "version": Bundle.main.object(
                                forInfoDictionaryKey: "CFBundleShortVersionString"
                            ) as? String ?? "0.1.0",
                        ]
                    ],
                    completion: { _ in }
                )
                self.initializeRequestID = requestID
            } catch {
                self.finishStart(.failure(error))
                self.stopLocked()
            }
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopLocked() }
    }

    func request(
        method: String,
        params: JSONObject = [:],
        completion: @escaping Completion
    ) {
        queue.async { [weak self] in
            guard
                let self,
                self.process?.isRunning == true,
                self.isInitialized
            else {
                DispatchQueue.main.async { completion(.failure(CodexFeatureError.unavailable)) }
                return
            }
            _ = self.sendRequestLocked(method: method, params: params, completion: completion)
        }
    }

    private func sendRequestLocked(
        method: String,
        params: JSONObject,
        completion: @escaping Completion
    ) -> Int {
        let requestID = nextRequestID
        nextRequestID += 1
        pending[requestID] = completion
        writeLocked(["method": method, "id": requestID, "params": params])
        return requestID
    }

    private func writeLocked(_ object: JSONObject) {
        guard
            let inputPipe,
            JSONSerialization.isValidJSONObject(object),
            var data = try? JSONSerialization.data(withJSONObject: object)
        else { return }
        data.append(0x0A)
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: data)
        } catch {
            processTerminated(status: -1)
        }
    }

    private func consumeOutput(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = outputBuffer[..<newline]
            outputBuffer.removeSubrange(...newline)
            guard
                !line.isEmpty,
                let object = try? JSONSerialization.jsonObject(with: Data(line)) as? JSONObject
            else { continue }
            handleMessage(object)
        }
    }

    private func handleMessage(_ object: JSONObject) {
        if let requestID = object["id"] as? Int, object["method"] == nil {
            if requestID == initializeRequestID {
                initializeRequestID = nil
                if let error = object["error"] as? JSONObject {
                    finishStart(.failure(Self.error(from: error)))
                    stopLocked()
                    return
                }
                guard let result = object["result"] as? JSONObject else {
                    finishStart(.failure(CodexFeatureError.malformedResponse))
                    stopLocked()
                    return
                }
                writeLocked(["method": "initialized", "params": [:]])
                isInitialized = true
                let completion = pending.removeValue(forKey: requestID)
                DispatchQueue.main.async { completion?(.success(result)) }
                finishStart(.success(()))
                return
            }

            guard let completion = pending.removeValue(forKey: requestID) else { return }
            if let error = object["error"] as? JSONObject {
                DispatchQueue.main.async { completion(.failure(Self.error(from: error))) }
            } else if let result = object["result"] as? JSONObject {
                DispatchQueue.main.async { completion(.success(result)) }
            } else {
                DispatchQueue.main.async {
                    completion(.failure(CodexFeatureError.malformedResponse))
                }
            }
            return
        }

        guard let method = object["method"] as? String else { return }
        let params = object["params"] as? JSONObject ?? [:]
        if let requestID = object["id"] as? Int {
            handleServerRequest(id: requestID, method: method, params: params)
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.onNotification?(method, params)
            }
        }
    }

    private func handleServerRequest(id: Int, method: String, params: JSONObject) {
        DispatchQueue.main.async { [weak self] in
            self?.onProtectedRequest?(method, params)
        }

        if let result = Self.safeRejectionResult(for: method) {
            writeLocked(["id": id, "result": result])
        } else {
            writeLocked([
                "id": id,
                "error": ["code": -32601, "message": "Handled in the Codex app"],
            ])
        }
    }

    static func safeRejectionResult(for method: String) -> JSONObject? {
        switch method {
        case "item/commandExecution/requestApproval", "item/fileChange/requestApproval":
            return ["decision": "cancel"]
        case "item/permissions/requestApproval":
            return ["permissions": JSONObject()]
        case "mcpServer/elicitation/request":
            return ["action": "cancel", "content": NSNull()]
        case "item/tool/requestUserInput", "tool/requestUserInput":
            return ["answers": JSONObject()]
        default:
            return nil
        }
    }

    private func finishStart(_ result: Result<Void, Error>) {
        guard let completion = startCompletion else { return }
        startCompletion = nil
        DispatchQueue.main.async { completion(result) }
    }

    private func processTerminated(status: Int32) {
        guard process != nil else { return }
        let stderr = String(data: errorBuffer, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let message = stderr?.isEmpty == false
            ? stderr!
            : "Codex App Server exited with status \(status)."
        finishStart(.failure(CodexFeatureError.server(message)))
        let completions = pending.values
        pending.removeAll()
        process = nil
        isInitialized = false
        initializeRequestID = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        DispatchQueue.main.async { [weak self] in
            completions.forEach { $0(.failure(CodexFeatureError.server(message))) }
            self?.onDisconnect?(message)
        }
    }

    private func stopLocked() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        let processToStop = process
        processToStop?.terminationHandler = nil
        if processToStop?.isRunning == true {
            processToStop?.terminate()
        }
        process = nil
        isInitialized = false
        initializeRequestID = nil
        inputPipe = nil
        outputPipe = nil
        errorPipe = nil
        pending.removeAll()
    }

    private static func error(from object: JSONObject) -> Error {
        CodexFeatureError.server(object["message"] as? String ?? "Codex request failed.")
    }

    static func codexExecutableURL(fileManager: FileManager = .default) -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        return candidates
            .first(where: fileManager.isExecutableFile(atPath:))
            .map(URL.init(fileURLWithPath:))
    }

    private static func processEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let additions = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        let current = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = (current + additions).uniqued().joined(separator: ":")
        return environment
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
