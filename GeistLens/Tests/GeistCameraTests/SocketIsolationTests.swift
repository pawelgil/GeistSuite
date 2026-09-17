import Foundation
import Testing
@testable import GeistCamera

@Suite("Socket isolation")
struct SocketIsolationTests {
    @Test func SocketClient_DeallocatedWithoutExplicitClose_ReleasesClient() async throws {
        let server = try TestFeederServer.listen()
        defer { server.close() }
        weak var releasedClient: SocketClient?

        do {
            let client = SocketClient(path: server.socketPath)
            try await client.connect(timeout: 2)
            await server.waitForConnection(timeout: 2)
            releasedClient = client
        }

        #expect(releasedClient == nil)
    }

    @Test func SocketClient_ConnectionsExceedWorkerCount_UnrelatedTaskRuns() async throws {
        let fixtures = try await makeSilentConnections(
            count: ProcessInfo.processInfo.activeProcessorCount + 1
        )
        defer { close(fixtures) }

        await confirmation { confirmed in
            let unrelatedTask = Task { confirmed() }
            await unrelatedTask.value
        }
    }

    @Test func SocketClient_PartialHeaderAtClose_ReadLoopFinishes() async throws {
        let fixture = try await makeSilentConnection()
        defer { fixture.server.close() }
        fixture.server.sendRaw(Data(repeating: 0, count: 2))

        let readLoopFinished = Task { await drain(fixture.client.inbound) }
        fixture.client.close()

        await readLoopFinished.value
    }

    @Test func SocketClient_SilentPeerAtClose_ReadLoopFinishes() async throws {
        let fixture = try await makeSilentConnection()
        defer { fixture.server.close() }

        let readLoopFinished = Task { await drain(fixture.client.inbound) }
        fixture.client.close()

        await readLoopFinished.value
    }

    @Test func TestFeederServer_CloseBeforeAccept_AcceptLoopFinishes() async throws {
        let server = try TestFeederServer.listen()
        let acceptLoopFinished = Task { await drain(server.inbound) }

        server.close()

        await acceptLoopFinished.value
    }

    private func close(_ fixtures: [SocketFixture]) {
        for fixture in fixtures {
            fixture.client.close()
            fixture.server.close()
        }
    }

    private func makeSilentConnection() async throws -> SocketFixture {
        let server = try TestFeederServer.listen()
        let client = SocketClient(path: server.socketPath)
        try await client.connect(timeout: 2)
        await server.waitForConnection(timeout: 2)
        return SocketFixture(client: client, server: server)
    }

    private func makeSilentConnections(count: Int) async throws -> [SocketFixture] {
        var fixtures: [SocketFixture] = []
        do {
            for _ in 0 ..< count {
                fixtures.append(try await makeSilentConnection())
            }
            return fixtures
        } catch {
            close(fixtures)
            throw error
        }
    }
}

private struct SocketFixture {
    let client: SocketClient
    let server: TestFeederServer
}

private func drain<Element>(_ stream: AsyncStream<Element>) async {
    for await _ in stream {}
}
