import Foundation

/// Telegram's stable chat classification, kept in the wire-agnostic core so routing and
/// persistence never infer trust from the sign of an id alone.
public enum TelegramChatType: String, Sendable, Equatable {
  case privateChat = "private"
  case group
  case supergroup
  case channel
  case unknown

  public var isGroup: Bool {
    self == .group || self == .supergroup
  }
}

/// The complete Telegram delivery address. A forum topic is not optional delivery metadata: it is
/// part of the conversation identity and must survive the transactional outbox.
public struct TelegramDestination: Sendable, Equatable, Hashable {
  public let chatId: Int64
  public let messageThreadId: Int64?

  public init(chatId: Int64, messageThreadId: Int64? = nil) {
    self.chatId = chatId
    self.messageThreadId = messageThreadId
  }
}

public enum TelegramSenderKind: String, Sendable, Equatable {
  case user
  case chat
}

/// A display snapshot for group history. Numeric ids remain the only authorization principal;
/// mutable names and usernames are untrusted presentation data.
public struct TelegramSender: Sendable, Equatable {
  public let kind: TelegramSenderKind
  public let id: Int64
  public let displayName: String?
  public let username: String?
  public let isBot: Bool

  public init(
    kind: TelegramSenderKind,
    id: Int64,
    displayName: String? = nil,
    username: String? = nil,
    isBot: Bool = false
  ) {
    self.kind = kind
    self.id = id
    self.displayName = displayName
    self.username = username
    self.isBot = isBot
  }

  public var historyHeader: String {
    let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let handle = username.map { "@\($0)" } ?? ""
    let label = [name, handle].filter { $0.isEmpty == false }.joined(separator: " ")
    let actor = kind == .user ? "Telegram user" : "Telegram sender chat"
    return label.isEmpty ? "\(actor) id=\(id)" : "\(actor) \(label) id=\(id)"
  }
}

/// The subset of Bot API MessageEntity needed for exact addressing. Telegram indexes entities in
/// UTF-16 code units, so extraction deliberately uses NSString rather than Swift String indices.
public struct TelegramMessageEntity: Sendable, Equatable {
  public let type: String
  public let offset: Int
  public let length: Int
  public let mentionedUserId: Int64?

  public init(type: String, offset: Int, length: Int, mentionedUserId: Int64? = nil) {
    self.type = type
    self.offset = offset
    self.length = length
    self.mentionedUserId = mentionedUserId
  }

  public func text(in source: String) -> String? {
    guard offset >= 0, length >= 0 else {
      return nil
    }
    let utf16 = source as NSString
    guard offset <= utf16.length, length <= utf16.length - offset else {
      return nil
    }
    return utf16.substring(with: NSRange(location: offset, length: length))
  }
}
