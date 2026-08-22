import ClawCore
import GRDB

enum TelegramSenderCoding {
  static func decode(_ row: Row) -> TelegramSender? {
    guard
      let kindValue: String = row["sender_kind"],
      let kind = TelegramSenderKind(rawValue: kindValue),
      let senderId: Int64 = row["sender_id"]
    else {
      return nil
    }

    return TelegramSender(
      kind: kind,
      id: senderId,
      displayName: row["sender_display_name"],
      username: row["sender_username"],
      isBot: row["sender_is_bot"] ?? false
    )
  }
}
