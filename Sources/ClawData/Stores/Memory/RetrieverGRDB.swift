import ClawCore
import Foundation
import GRDB

public struct RetrieverGRDB: Retriever {
  private let database: MappedDatabase

  public init(writer: any DatabaseWriter) {
    database = MappedDatabase(writer: writer)
  }

  public func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    limit: Int
  ) throws(StoreError) -> [RecallHit] {
    try searchRelevantMessages(
      query: query,
      currentSessionId: currentSessionId,
      windowStartMessageId: windowStartMessageId,
      excludedMessageIds: excludedMessageIds,
      scope: .personal,
      limit: limit
    )
  }

  public func searchRelevantMessages(
    query: String,
    currentSessionId: Int64,
    windowStartMessageId: Int64?,
    excludedMessageIds: [Int64],
    scope: RecallScope,
    limit: Int
  ) throws(StoreError) -> [RecallHit] {
    // A tokenless query (empty/punctuation) yields nil -> zero results; never raw-interpolate text.
    guard let pattern = FTS5Pattern(matchingAnyTokenIn: query) else {
      return []
    }

    return try database.readMapping { db in
      let groupChatId: Int64?
      if scope == .telegramGroup {
        groupChatId = try Int64.fetchOne(
          db,
          sql: """
            SELECT telegram_chat_id FROM sessions
            WHERE id = ? AND conversation_kind = ?
            """,
          arguments: [currentSessionId, ConversationKind.group.rawValue]
        )
        guard groupChatId != nil else {
          return []
        }
      } else {
        groupChatId = nil
      }

      // messages_fts.rowid == messages.id (external content). BM25 is negative; lower = better, so
      // ORDER BY is ASC. RecallScore negates it back so higher = better for policy/telemetry.
      // Personal recall stays trusted-only so attacker-influenceable text cannot resurface after a
      // detaint. Group recall intentionally includes untrusted rows, but only from the same numeric
      // chat boundary; context assembly fences them again and group turns have no tools.
      var sql = """
        SELECT m.id, m.session_id, m.role, m.content, m.ts, m.sender_kind, m.sender_id,
          m.sender_display_name, m.sender_username, m.sender_is_bot,
          bm25(messages_fts) AS bm25_score
        FROM messages m
        JOIN messages_fts ON messages_fts.rowid = m.id
        JOIN sessions s ON s.id = m.session_id
        WHERE messages_fts MATCH ?
          AND m.role IN ('\(MessageRole.user.rawValue)', '\(MessageRole.assistant.rawValue)')
        """
      var arguments: StatementArguments = [pattern]

      switch scope {
      case .personal:
        sql += "\n  AND m.provenance = ? AND s.conversation_kind != ?"
        arguments += [Provenance.trusted.rawValue, ConversationKind.group.rawValue]
      case .telegramGroup:
        sql += "\n  AND s.conversation_kind = ? AND s.telegram_chat_id = ?"
        arguments += [ConversationKind.group.rawValue, groupChatId]
      }

      if let windowStart = windowStartMessageId {
        // Dedup against the current session's in-window range.
        sql += "\n  AND NOT (m.session_id = ? AND m.id >= ?)"
        arguments += [currentSessionId, windowStart]
      }

      if excludedMessageIds.isEmpty == false {
        let placeholders = databaseQuestionMarks(count: excludedMessageIds.count)
        sql += "\n  AND m.id NOT IN (\(placeholders))"
        arguments += StatementArguments(excludedMessageIds)
      }

      sql += "\n  ORDER BY bm25(messages_fts) ASC\n  LIMIT ?"
      arguments += [limit]

      let rows = try Row.fetchAll(db, sql: sql, arguments: arguments)
      return try rows.map { row in
        // The SQL filters `role IN ('user','assistant')`, so an unknown role is unreachable
        // today — the guard keeps the decode direction fail-closed if that filter ever moves.
        guard let role = MessageRole(rawValue: row["role"]) else {
          throw StoreError.unexpected("messages row \(row["id"] as Int64) has an unrecognized role")
        }
        return RecallHit(
          id: row["id"],
          sessionId: row["session_id"],
          role: role,
          content: row["content"],
          score: RecallScore(sqliteBM25: row["bm25_score"]),
          createdAt: row["ts"],
          sender: TelegramSenderCoding.decode(row)
        )
      }
    }
  }
}
