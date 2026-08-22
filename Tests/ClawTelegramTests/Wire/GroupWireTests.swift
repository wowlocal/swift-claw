import ClawCore
import Foundation
import Testing

@testable import ClawTelegram

@Suite struct GroupWireTests {
  private let decoder = JSONDecoder()

  @Test func supergroupTopicCarriesItsTypeThreadAuthorAndMentionEntity() throws {
    // given
    let json = """
      {
        "update_id": 91,
        "message": {
          "message_id": 501,
          "message_thread_id": 77,
          "from": {
            "id": 7,
            "is_bot": false,
            "first_name": "Ada",
            "last_name": "Lovelace",
            "username": "ada"
          },
          "chat": {"id": -1001234, "type": "supergroup", "title": "Crew", "is_forum": true},
          "text": "@claw_bot help",
          "entities": [{"type": "mention", "offset": 0, "length": 9}]
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then
    #expect(raw.chatType == .supergroup)
    #expect(raw.messageThreadId == 77)
    #expect(raw.sender?.id == 7)
    #expect(raw.sender?.displayName == "Ada Lovelace")
    #expect(raw.sender?.username == "ada")
    #expect(raw.entities == [TelegramMessageEntity(type: "mention", offset: 0, length: 9)])
  }

  @Test func anonymousSenderChatWinsOverTheSyntheticFromUser() throws {
    // given — Telegram supplies sender_chat for anonymous administrators
    let json = """
      {
        "update_id": 92,
        "message": {
          "message_id": 502,
          "from": {"id": 1087968824, "is_bot": true, "first_name": "GroupAnonymousBot"},
          "sender_chat": {"id": -1001234, "type": "supergroup", "title": "Crew"},
          "chat": {"id": -1001234, "type": "supergroup", "title": "Crew"},
          "text": "announcement"
        }
      }
      """

    // when
    let update = try decoder.decode(TUpdate.self, from: Data(json.utf8))
    let raw = try #require(update.toRawUpdate().message)

    // then
    #expect(raw.fromUserId == -1_001_234)
    #expect(raw.sender?.kind == .chat)
    #expect(raw.sender?.displayName == "Crew")
  }
}
