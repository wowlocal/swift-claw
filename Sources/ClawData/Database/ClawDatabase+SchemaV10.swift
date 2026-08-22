import ClawCore
import GRDB

// MARK: - Schema V10 Shared Telegram Chat

extension ClawDatabase {
  static func addSharedTelegramChatColumns(_ db: Database) throws {
    try db.alter(table: "sessions") { table in
      table.add(column: "conversation_kind", .text).notNull()
        .defaults(to: ConversationKind.privateChat.rawValue)
      table.add(column: "telegram_chat_id", .integer)
      table.add(column: "telegram_thread_id", .integer)
    }
    try db.execute(
      sql: """
        UPDATE sessions
        SET telegram_chat_id = CAST(substr(session_key, 7) AS INTEGER)
        WHERE session_key LIKE 'tg:dm:%'
        """
    )
    try db.execute(
      sql: """
        UPDATE sessions
        SET conversation_kind = ?
        WHERE session_key LIKE 'sched:%'
        """,
      arguments: [ConversationKind.scheduled.rawValue]
    )
    try db.create(
      index: "index_sessions_telegram_conversation",
      on: "sessions",
      columns: ["telegram_chat_id", "telegram_thread_id"]
    )

    try db.alter(table: "messages") { table in
      table.add(column: "telegram_message_id", .integer)
      table.add(column: "is_edited", .boolean).notNull().defaults(to: false)
      table.add(column: "sender_kind", .text)
      table.add(column: "sender_id", .integer)
      table.add(column: "sender_display_name", .text)
      table.add(column: "sender_username", .text)
      table.add(column: "sender_is_bot", .boolean)
    }

    try db.alter(table: "outbound_deliveries") { table in
      table.add(column: "message_thread_id", .integer)
    }
  }
}
