import XCTest
import Network
@testable import SpeakFreeLib

/// Routing, gating, and auth for the local API's dictation-control endpoints. Pure: exercises
/// `LocalAPIServer.evaluate` without a socket. The live round trip is in LocalAPIServerLiveTests.
final class LocalAPIServerControlTests: XCTestCase {

    private func evaluate(_ requestLine: String, body: String = "", token: String? = nil,
                          sendToken: String? = nil, host: String = "127.0.0.1:5765",
                          allowControl: Bool = true) -> LocalAPIServer.RequestOutcome {
        var lines = [requestLine, "Host: \(host)", "Content-Type: application/json"]
        if let t = sendToken { lines.append("Authorization: Bearer \(t)") }
        return LocalAPIServer.evaluate(headers: lines.joined(separator: "\r\n"), body: Data(body.utf8),
                                       authToken: token, allowControl: allowControl)
    }

    private func status(_ outcome: LocalAPIServer.RequestOutcome) -> Int? {
        if case .respond(let status, _, _) = outcome { return status }
        return nil
    }

    private let id = UUID()

    // MARK: - Gate: localAPIAllowControl

    func testControlRoutesForbiddenWhenControlDisabled() {
        for line in ["POST /v1/dictation/start HTTP/1.1",
                     "POST /v1/dictation/\(id.uuidString)/stop HTTP/1.1",
                     "POST /v1/dictation/\(id.uuidString)/cancel HTTP/1.1",
                     "GET /v1/dictation/\(id.uuidString) HTTP/1.1",
                     "GET /v1/events HTTP/1.1"] {
            XCTAssertEqual(status(evaluate(line, allowControl: false)), 403, line)
        }
    }

    func testControlIsOffByDefaultInEvaluate() {
        let headers = "GET /v1/events HTTP/1.1\r\nHost: 127.0.0.1"
        XCTAssertEqual(status(LocalAPIServer.evaluate(headers: headers, body: Data(), authToken: nil)), 403)
    }

    func testTranscriptionRouteUnaffectedByControlGate() {
        // With control off, the transcription endpoint still reaches its own validation.
        let outcome = evaluate("POST /v1/audio/transcriptions HTTP/1.1", allowControl: false)
        XCTAssertEqual(status(outcome), 400, "expected the multipart validation error, not 403")
    }

    // MARK: - Same hardening as transcription

    func testControlRequiresBearerTokenWhenConfigured() {
        XCTAssertEqual(status(evaluate("POST /v1/dictation/start HTTP/1.1", token: "s3cret")), 401)
        XCTAssertEqual(status(evaluate("GET /v1/events HTTP/1.1", token: "s3cret", sendToken: "wrong")), 401)
        XCTAssertEqual(evaluate("GET /v1/events HTTP/1.1", token: "s3cret", sendToken: "s3cret"),
                       .control(.events))
    }

    func testControlRejectsNonLoopbackHost() {
        XCTAssertEqual(status(evaluate("POST /v1/dictation/start HTTP/1.1", host: "evil.com")), 421)
        XCTAssertEqual(status(evaluate("GET /v1/events HTTP/1.1", host: "evil.com:5765")), 421)
    }

    func testForbiddenCheckRunsAfterAuth() {
        // An unauthenticated client learns nothing about whether control is enabled.
        XCTAssertEqual(status(evaluate("GET /v1/events HTTP/1.1", token: "t", allowControl: false)), 401)
    }

    // MARK: - Routing

    func testStartParsesBody() {
        XCTAssertEqual(evaluate("POST /v1/dictation/start HTTP/1.1",
                                body: #"{"destination":"cursor","engine":"parakeet","timeout_ms":15000}"#),
                       .control(.start(destination: .cursor, engine: "parakeet", timeoutMs: 15000)))
    }

    func testStartDefaultsToCallerWithEmptyBody() {
        XCTAssertEqual(evaluate("POST /v1/dictation/start HTTP/1.1"),
                       .control(.start(destination: .caller, engine: nil, timeoutMs: nil)))
        XCTAssertEqual(evaluate("POST /v1/dictation/start HTTP/1.1", body: "{}"),
                       .control(.start(destination: .caller, engine: nil, timeoutMs: nil)))
    }

    func testStartRejectsBadBodies() {
        for body in ["not json", "[1]", #"{"destination":"clipboard"}"#, #"{"destination":1}"#,
                     #"{"engine":""}"#, #"{"timeout_ms":0}"#, #"{"timeout_ms":-5}"#,
                     #"{"timeout_ms":1.5}"#, #"{"timeout_ms":true}"#, #"{"timeout_ms":"100"}"#,
                     #"{"timeout_ms":999999999}"#] {
            XCTAssertEqual(status(evaluate("POST /v1/dictation/start HTTP/1.1", body: body)), 400, body)
        }
    }

    func testSessionRoutes() {
        XCTAssertEqual(evaluate("POST /v1/dictation/\(id.uuidString)/stop HTTP/1.1"), .control(.stop(id)))
        XCTAssertEqual(evaluate("POST /v1/dictation/\(id.uuidString)/cancel HTTP/1.1"), .control(.cancel(id)))
        XCTAssertEqual(evaluate("GET /v1/dictation/\(id.uuidString) HTTP/1.1"), .control(.state(id)))
        XCTAssertEqual(evaluate("GET /v1/dictation/\(id.uuidString.lowercased()) HTTP/1.1"), .control(.state(id)))
        XCTAssertEqual(evaluate("GET /v1/events?since=now HTTP/1.1"), .control(.events))
    }

    func testWrongMethodIs405() {
        XCTAssertEqual(status(evaluate("GET /v1/dictation/start HTTP/1.1")), 405)
        XCTAssertEqual(status(evaluate("GET /v1/dictation/\(id.uuidString)/stop HTTP/1.1")), 405)
        XCTAssertEqual(status(evaluate("POST /v1/dictation/\(id.uuidString) HTTP/1.1")), 405)
        XCTAssertEqual(status(evaluate("POST /v1/events HTTP/1.1")), 405)
    }

    func testUnknownOrMalformedSessionIs404() {
        XCTAssertEqual(status(evaluate("GET /v1/dictation/not-a-uuid HTTP/1.1")), 404)
        XCTAssertEqual(status(evaluate("POST /v1/dictation/\(id.uuidString)/pause HTTP/1.1")), 404)
        XCTAssertEqual(status(evaluate("GET /v1/dictation HTTP/1.1")), 404)
        XCTAssertEqual(status(evaluate("POST /v1/dictation/\(id.uuidString)/stop/extra HTTP/1.1")), 404)
    }
}
