import ClawCore
import Foundation
import GRDB
import Testing

@testable import ClawData

@Suite struct V10MigrationTests {
  @Test func legacySessionsGainConversationMetadataWithoutChangingTheirIdentity() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()
    try ClawDatabase.migrator.migrate(queue, upTo: "v9")
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    try queue.write { db in
      for key in ["tg:dm:42", "sched:job:7", SessionKey.heartbeat] {
        try db.execute(
          sql: """
            INSERT INTO sessions(session_key, created_ts, updated_ts, tainted)
            VALUES (?, ?, ?, 0)
            """,
          arguments: [key, timestamp, timestamp]
        )
      }
    }

    // when
    try ClawDatabase.migrate(queue)

    // then
    let rows = try queue.read { db in
      try Row.fetchAll(
        db,
        sql: """
          SELECT session_key, conversation_kind, telegram_chat_id, telegram_thread_id
          FROM sessions ORDER BY id
          """
      )
    }
    #expect(rows.count == 3)
    #expect(rows[0]["session_key"] == "tg:dm:42")
    #expect(rows[0]["conversation_kind"] == ConversationKind.privateChat.rawValue)
    #expect(rows[0]["telegram_chat_id"] as Int64? == 42)
    #expect(rows[0]["telegram_thread_id"] as Int64? == nil)
    #expect(rows[1]["conversation_kind"] == ConversationKind.scheduled.rawValue)
    #expect(rows[2]["conversation_kind"] == ConversationKind.scheduled.rawValue)
  }

  @Test func sharedChatColumnsExistOnEveryDurableBoundaryThatCarriesThem() throws {
    // given
    let queue = try ClawDatabase.makeInMemoryQueue()

    // when
    try ClawDatabase.migrate(queue)

    // then
    #expect(
      try columnNames(queue, table: "sessions").isSuperset(of: [
        "conversation_kind", "telegram_chat_id", "telegram_thread_id",
      ])
    )
    #expect(
      try columnNames(queue, table: "messages").isSuperset(of: [
        "telegram_message_id", "is_edited", "sender_kind", "sender_id",
        "sender_display_name", "sender_username", "sender_is_bot",
      ])
    )
    #expect(try columnNames(queue, table: "outbound_deliveries").contains("message_thread_id"))
  }

  private func columnNames(_ queue: DatabaseQueue, table: String) throws -> Set<String> {
    try queue.read { db in
      Set(try db.columns(in: table).map(\.name))
    }
  }
}
