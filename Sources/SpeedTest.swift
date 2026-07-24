import Foundation

final class SpeedTest: @unchecked Sendable {
    enum State: Sendable {
        case idle
        case testing(phase: SpeedTestPhase)
        case completed(SpeedTestResult)
        case failed(message: String)
        case cancelled
    }

    @MainActor var onStateChange: (@MainActor @Sendable (State) -> Void)?

    private let stateQueue = DispatchQueue(label: "com.nishantkumar.speedbar.speed-test")
    private let downloadBytes = 20_000_000
    private let uploadBytes = 5_000_000
    private var session: URLSession?
    private var activeTask: URLSessionTask?
    private var generation = 0
    private var isRunning = false

    func start() {
        stateQueue.async { [weak self] in
            guard let self, !self.isRunning else { return }

            self.isRunning = true
            self.generation += 1
            let token = self.generation
            self.session = URLSession(configuration: self.makeConfiguration())
            self.emit(.testing(phase: .preparing))
            self.runDownloadWarmup(token: token)
        }
    }

    func cancel() {
        stateQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.generation += 1
            self.isRunning = false
            self.activeTask?.cancel()
            self.activeTask = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.emit(.cancelled)
        }
    }

    private func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = false
        configuration.httpAdditionalHeaders = [
            "Accept-Encoding": "identity",
            "Cache-Control": "no-store",
            "User-Agent": "SpeedBar/0.2"
        ]
        return configuration
    }

    private func runDownloadWarmup(token: Int) {
        guard let request = downloadRequest(byteCount: 250_000) else {
            fail("The download test could not be prepared.", token: token)
            return
        }

        performDownload(
            request: request,
            minimumByteCount: 200_000,
            token: token
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.emit(.testing(phase: .download))
                self.runMeasuredDownload(token: token)
            case .failure:
                self.fail("The test server did not respond. Check your connection and try again.", token: token)
            }
        }
    }

    private func runMeasuredDownload(token: Int) {
        guard let request = downloadRequest(byteCount: downloadBytes) else {
            fail("The download test could not be prepared.", token: token)
            return
        }

        let startedAt = ProcessInfo.processInfo.systemUptime
        performDownload(
            request: request,
            minimumByteCount: Int(Double(downloadBytes) * 0.95),
            token: token
        ) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let byteCount):
                let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
                guard elapsed > 0 else {
                    self.fail("The download measurement was interrupted.", token: token)
                    return
                }
                let downloadSpeed = Double(byteCount) / elapsed
                self.emit(.testing(phase: .upload))
                self.runUploadWarmup(downloadSpeed: downloadSpeed, token: token)
            case .failure:
                self.fail("The download measurement failed. Check your connection and try again.", token: token)
            }
        }
    }

    private func runUploadWarmup(downloadSpeed: Double, token: Int) {
        let warmupData = makeRandomData(count: 64_000)
        performUpload(data: warmupData, token: token) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded else {
                self.fail("The upload test server did not respond. Try again in a moment.", token: token)
                return
            }
            self.runMeasuredUpload(downloadSpeed: downloadSpeed, token: token)
        }
    }

    private func runMeasuredUpload(downloadSpeed: Double, token: Int) {
        let payload = makeRandomData(count: uploadBytes)
        let startedAt = ProcessInfo.processInfo.systemUptime

        performUpload(data: payload, token: token) { [weak self] succeeded in
            guard let self else { return }
            guard succeeded else {
                self.fail("The upload measurement failed. Check your connection and try again.", token: token)
                return
            }

            let elapsed = ProcessInfo.processInfo.systemUptime - startedAt
            guard elapsed > 0 else {
                self.fail("The upload measurement was interrupted.", token: token)
                return
            }

            let result = SpeedTestResult(
                downloadBytesPerSecond: downloadSpeed,
                uploadBytesPerSecond: Double(payload.count) / elapsed,
                completedAt: Date()
            )
            self.finish(with: .completed(result), token: token)
        }
    }

    private func downloadRequest(byteCount: Int) -> URLRequest? {
        guard let url = URL(string: "https://speed.cloudflare.com/__down?bytes=\(byteCount)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        return request
    }

    private func performDownload(
        request: URLRequest,
        minimumByteCount: Int,
        token: Int,
        completion: @escaping @Sendable (Result<Int, Error>) -> Void
    ) {
        guard let session else {
            fail("The speed test session ended unexpectedly.", token: token)
            return
        }

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            self.stateQueue.async { [self] in
                guard self.isCurrent(token) else { return }
                self.activeTask = nil

                guard error == nil,
                      let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      let data,
                      data.count >= minimumByteCount else {
                    completion(.failure(error ?? SpeedTestError.invalidResponse))
                    return
                }
                completion(.success(data.count))
            }
        }
        activeTask = task
        task.resume()
    }

    private func performUpload(
        data: Data,
        token: Int,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        guard let session,
              let url = URL(string: "https://speed.cloudflare.com/__up") else {
            fail("The upload test could not be prepared.", token: token)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(data.count), forHTTPHeaderField: "Content-Length")

        let task = session.uploadTask(with: request, from: data) { [weak self] _, response, error in
            guard let self else { return }
            self.stateQueue.async { [self] in
                guard self.isCurrent(token) else { return }
                self.activeTask = nil
                let statusCode = (response as? HTTPURLResponse)?.statusCode
                completion(error == nil && statusCode.map { (200..<300).contains($0) } == true)
            }
        }
        activeTask = task
        task.resume()
    }

    private func makeRandomData(count: Int) -> Data {
        var data = Data(count: count)
        data.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            arc4random_buf(baseAddress, count)
        }
        return data
    }

    private func isCurrent(_ token: Int) -> Bool {
        isRunning && generation == token
    }

    private func fail(_ message: String, token: Int) {
        finish(with: .failed(message: message), token: token)
    }

    private func finish(with state: State, token: Int) {
        guard isCurrent(token) else { return }
        isRunning = false
        activeTask?.cancel()
        activeTask = nil
        session?.finishTasksAndInvalidate()
        session = nil
        emit(state)
    }

    private func emit(_ state: State) {
        Task { @MainActor [weak self] in
            self?.onStateChange?(state)
        }
    }
}

private enum SpeedTestError: Error, Sendable {
    case invalidResponse
}
