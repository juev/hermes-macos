import Foundation
import HermesCore

/// The client against the dashboard it was built for: reads the tokens from the standard input (the
/// script asks the Keychain for them), then makes the calls the window makes, in the order it makes
/// them, and says what came back. Every line that starts with `ok` passed; `FAIL` stops the run with
/// a non-zero exit code.

// Line buffered: a check that hangs has to show what it got to.
setvbuf(stdout, nil, _IOLBF, 0)

let input = FileHandle.standardInput.readDataToEndOfFile()
let raw = String(decoding: input, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)

struct StoredTokens: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Int64
    let provider: String
    let userID: String
}

guard !raw.isEmpty else {
    FileHandle.standardError.write(Data("no tokens on stdin: run scripts/smoke.sh\n".utf8))
    exit(2)
}
guard let tokens = try? JSONDecoder().decode(StoredTokens.self, from: Data(raw.utf8)) else {
    FileHandle.standardError.write(Data("stdin is not a token object\n".utf8))
    exit(2)
}

let address = ProcessInfo.processInfo.environment["HERMES_SERVER"] ?? "https://hermes.evsyukov.org"
guard let endpoint = Endpoint(address: address) else {
    FileHandle.standardError.write(Data("HERMES_SERVER is not an address: \(address)\n".utf8))
    exit(2)
}

/// The tally, shared with the task that makes the calls.
final class Reporter: @unchecked Sendable {
    private let lock = NSLock()
    private var failed = 0

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return failed
    }

    func report(_ ok: Bool, _ what: String, _ detail: String = "") {
        if ok {
            print("ok   \(what)\(detail.isEmpty ? "" : ": \(detail)")")
        } else {
            lock.lock()
            failed += 1
            lock.unlock()
            print("FAIL \(what)\(detail.isEmpty ? "" : ": \(detail)")")
        }
    }
}

let reporter = Reporter()

let semaphore = DispatchSemaphore(value: 0)
// Detached on purpose: the top level of a Swift 6 main.swift runs on the main actor, and the main
// thread below waits on the semaphore — a task of that actor would wait for a thread nobody frees.
Task.detached {
    let client = DashboardClient(endpoint: endpoint)
    let session = DashboardSession(endpoint: endpoint)
    do {
        try await session.adopt(Tokens(
            accessToken: tokens.accessToken,
            refreshToken: tokens.refreshToken,
            expiresAt: tokens.expiresAt,
            provider: tokens.provider,
            userID: tokens.userID
        ))
    } catch {
        reporter.report(false, "the tokens are readable", "\(error)")
        semaphore.signal()
        return
    }

    // 1. The dashboard says what it is.
    do {
        let status = try await client.status()
        reporter.report(status.version != nil, "status", "v\(status.version ?? "-"), auth \(status.authRequired ? "required" : "open"), flows \(status.authFlows)")
    } catch {
        reporter.report(false, "status", "\(error)")
    }

    // 2. The sidebar's list.
    var newest: SessionSummary?
    do {
        let page = try await session.sessions(limit: 5)
        newest = page.sessions.first
        reporter.report(!page.sessions.isEmpty, "sessions", "\(page.sessions.count) of \(page.total), first “\(newest?.label.prefix(40) ?? "-")”")
    } catch {
        reporter.report(false, "sessions", "\(error)")
    }

    // 2b. The archive, which the sidebar shows on its own.
    do {
        let archived = try await session.sessions(limit: 3, archived: .only)
        reporter.report(true, "archive", "\(archived.sessions.count) of \(archived.total) archived")
    } catch {
        reporter.report(false, "archive", "\(error)")
    }

    // 3. Search.
    do {
        let hits = try await session.search("hermes", limit: 5)
        reporter.report(true, "search", "\(hits.count) hits, first in role \(hits.first?.role ?? "-")")
    } catch {
        reporter.report(false, "search", "\(error)")
    }

    // 4. A transcript, built the way the window builds it.
    var delivered: String?
    if let newest {
        do {
            let rows = try await session.messages(sessionID: newest.id, limit: 60)
            let items = Transcript.items(from: rows)
            let tools = items.flatMap { item -> [ToolRun] in
                if case .assistant(let turn) = item { return turn.tools }
                return []
            }
            let files = items.flatMap { item -> [String] in
                if case .assistant(let turn) = item { return turn.deliveredFiles }
                return []
            }
            delivered = files.first
            reporter.report(!items.isEmpty, "transcript", "\(rows.count) rows, \(items.count) turns, \(tools.count) tool runs, \(files.count) delivered files")
        } catch {
            reporter.report(false, "transcript", "\(error)")
        }
    }

    // 5. A file the agent delivered, if the chat had one.
    if let delivered {
        do {
            let token = try await session.accessToken()
            let data = try await FileDownload(endpoint: endpoint).data(path: delivered, token: token)
            reporter.report(!data.isEmpty, "download", "\(data.count) bytes of \(delivered.suffix(40))")
        } catch {
            reporter.report(false, "download", "\(error)")
        }
    } else {
        print("skip download: the newest chat delivered no file")
    }

    // 6. The socket: a ticket, the handshake, and the ready event.
    do {
        guard let token = try await session.accessToken() else {
            throw ChatError.notConnected
        }
        let ticket = try await client.socketTicket(token: token)
        reporter.report(!ticket.isEmpty, "ws ticket", "\(ticket.count) characters")

        let connection = GatewayConnection(url: endpoint.socketURL(ticket: ticket), transport: URLSessionSocketTransport())
        let ready = try await connection.start(timeout: .seconds(20))
        reporter.report(true, "gateway ready", "epoch \(ready.replayEpoch ?? "-"), authority \(ready.sessionAuthority), heartbeat \(ready.heartbeat)")
        await connection.close()
    } catch {
        reporter.report(false, "socket", "\(error)")
    }

    print(reporter.failures == 0 ? "all checks passed" : "\(reporter.failures) check(s) failed")
    semaphore.signal()
}
semaphore.wait()
exit(reporter.failures == 0 ? 0 : 1)
