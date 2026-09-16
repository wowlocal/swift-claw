import ClawCore
import ClawTestSupport
import Foundation
import GRDB
import Testing

@testable import ClawData
@testable import ClawGateway

/// The delivery identity moved off the run and onto the row's own `dedup_key`, so a message that
/// belongs to no run can be enqueued, sent and recorded like any other.
@Suite struct OutboxDeliveryIdentityTests {
  @Test func aLearningNoticeSurvivesInsertSendAndRestartWithoutDuplicating() async throws {
    // given — a notice row with no run
    let queue = try TestDatabase.make()
    let outbox = OutboxStoreGRDB(writer: queue)
    _ = try outbox.claimNotice(Self.notice(subjectDigest: "abc", ordinal: 0))
    let transport = RecordingTransport()

    // when — the dispatcher drains, then the process restarts and drains again
    await Self.dispatcher(outbox: outbox, transport: transport).drainOnce()
    let restarted = OutboxStoreGRDB(writer: queue)
    await Self.dispatcher(outbox: restarted, transport: transport).drainOnce()

    // then — sent exactly once, and nothing is left behind for a third drain
    let sends = await transport.richSends
    #expect(sends.map(\.markdown) == ["candidate ready"])
    #expect(try restarted.pendingOutbound().isEmpty)
  }

  @Test func aRunReplyAndALearningNoticeBothDrainInOnePass() async throws {
    // given — one run-owned row and one runless notice, pending together
    let seeded = try makeSeededFixture()
    _ = try seeded.outbox.claimOutbound(
      runId: seeded.runId,
      chunk: OutboxChunk(
        stepIndex: 0,
        chatId: seeded.chatId,
        payload: "your answer",
        payloadHash: "h"
      )
    )
    _ = try seeded.outbox.claimNotice(Self.notice(subjectDigest: "abc", ordinal: 0))
    let transport = RecordingTransport()

    // when
    await Self.dispatcher(outbox: seeded.outbox, transport: transport).drainOnce()

    // then — neither row failed the other, and the owner's answer went first
    let sends = await transport.richSends
    #expect(sends.map(\.markdown) == ["your answer", "candidate ready"])
    #expect(try seeded.outbox.pendingOutbound().isEmpty)
  }

  @Test func uncertainConferenceNoticeQuarantinesOnlyItsUnsentRemainder() throws {
    // given — one partially sent multipart conference notice and an unrelated runless notice
    let seeded = try makeSeededFixture()
    let affectedID = try #require(UUID(uuidString: "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"))
    let unrelatedID = try #require(UUID(uuidString: "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"))
    for ordinal in 0...2 {
      _ = try seeded.outbox.claimConferenceNotice(
        Self.conferenceNotice(
          submissionID: affectedID,
          originRunID: seeded.runId,
          ordinal: ordinal
        )
      )
    }
    _ = try seeded.outbox.claimConferenceNotice(
      Self.conferenceNotice(
        submissionID: unrelatedID,
        originRunID: seeded.runId,
        ordinal: 2
      )
    )
    let firstKey = Self.conferenceKey(submissionID: affectedID, ordinal: 0)
    let uncertainKey = Self.conferenceKey(submissionID: affectedID, ordinal: 1)
    try seeded.outbox.markSent(deliveryKey: firstKey, telegramMessageId: 10, now: Date())

    // when
    try seeded.outbox.markDeliveryUncertain(deliveryKey: uncertainKey)

    // then — the sent prefix stays SENT, the uncertain remainder is FAILED, and another subject
    // remains PENDING for normal delivery
    let statuses = try seeded.writer.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT dedup_key, status FROM outbound_deliveries ORDER BY dedup_key"
      ).reduce(into: [String: String]()) { result, row in
        result[row["dedup_key"]] = row["status"]
      }
    }
    #expect(statuses[firstKey] == OutboxDeliveryStatus.sent.rawValue)
    #expect(statuses[uncertainKey] == OutboxDeliveryStatus.failed.rawValue)
    #expect(
      statuses[Self.conferenceKey(submissionID: affectedID, ordinal: 2)]
        == OutboxDeliveryStatus.failed.rawValue
    )
    #expect(
      statuses[Self.conferenceKey(submissionID: unrelatedID, ordinal: 2)]
        == OutboxDeliveryStatus.pending.rawValue
    )
  }
}

// MARK: - Fixtures

private extension OutboxDeliveryIdentityTests {
  static func notice(subjectDigest: String, ordinal: Int) -> LearningNoticeChunk {
    LearningNoticeChunk(
      subjectDigest: subjectDigest,
      ordinal: ordinal,
      chatId: 42,
      payload: "candidate ready",
      payloadHash: "hash"
    )
  }

  static func conferenceNotice(
    submissionID: UUID,
    originRunID: Int64,
    ordinal: Int
  ) -> ConferenceNoticeChunk {
    ConferenceNoticeChunk(
      submissionID: submissionID,
      originRunID: originRunID,
      ordinal: ordinal,
      chatId: 42,
      payload: "conference result \(ordinal)",
      payloadHash: "hash-\(ordinal)"
    )
  }

  static func conferenceKey(submissionID: UUID, ordinal: Int) -> String {
    OutboxDedupKey.make(
      subjectDigest: "conference:\(submissionID.uuidString.lowercased())",
      ordinal: ordinal
    )
  }

  static func dispatcher(
    outbox: OutboxStoreGRDB,
    transport: RecordingTransport
  ) -> OutboxDispatcher<ContinuousClock> {
    OutboxDispatcher(
      outbox: outbox,
      delivery: transport,
      signal: OutboxSignal(),
      logger: TestLog.silent
    )
  }
}
