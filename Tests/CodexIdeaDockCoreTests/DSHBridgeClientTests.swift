import XCTest
@testable import CodexIdeaDockCore

/// 桥接靠 `?source=phone` 区分「手机在轮询」和「桌面自己在轮询」。
/// 弄错后者会冒充手机，把每条桌面审批都扣住等手机。
final class DSHBridgeClientTests: XCTestCase {
    private var root: URL!
    private var stateURL: URL!
    private var session: URLSession!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flowcue-bridge-client-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        stateURL = root.appendingPathComponent("dsh-bridge.json")
        try #"{"token":"0123456789abcdef0123456789abcdef","port":47823}"#
            .write(to: stateURL, atomically: true, encoding: .utf8)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [Recorder.self]
        session = URLSession(configuration: configuration)
        Recorder.requests = []
    }

    override func tearDownWithError() throws {
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }

    private func makeClient() -> DSHBridgeClient {
        DSHBridgeClient(configuration: DSHBridgeClient.Configuration(
            stateURL: stateURL,
            baseURL: URL(string: "http://127.0.0.1:47823")!,
            session: session
        ))
    }

    func testPhonePollCarriesSourcePhone() async throws {
        _ = try await makeClient().pending(source: "phone")
        let request = try XCTUnwrap(Recorder.requests.last)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/v1/pending")
        XCTAssertEqual(
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
            [URLQueryItem(name: "source", value: "phone")]
        )
    }

    func testDesktopPollCarriesNoQuery() async throws {
        _ = try await makeClient().pending()
        let request = try XCTUnwrap(Recorder.requests.last)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/v1/pending")
        XCTAssertNil(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    }

    func testRequestCarriesBearerToken() async throws {
        _ = try await makeClient().pending(source: "phone")
        XCTAssertEqual(
            Recorder.requests.last?.value(forHTTPHeaderField: "Authorization"),
            "Bearer 0123456789abcdef0123456789abcdef"
        )
    }

    // MARK: URLProtocol 桩

    private final class Recorder: URLProtocol {
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Recorder.requests.append(request)
            guard let url = request.url else { return }
            let response = HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"pending":[]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }
}
