import Foundation
import Testing

@testable import ClawCore

@Suite struct SessionKeyTests {
  @Test func syntheticFormsRenderAndNeverResolveAChatId() {
    // given / when / then — delivery targets live on the job row / in config, never in the key
    // (preamble Global Constraints); chatId(from:) must stay nil for both synthetic forms.
    #expect(SessionKey.scheduledJob(id: 7) == "sched:job:7")
    #expect(SessionKey.heartbeat == "sched:heartbeat")
    #expect(SessionKey.chatId(from: SessionKey.scheduledJob(id: 7)) == nil)
    #expect(SessionKey.chatId(from: SessionKey.heartbeat) == nil)
  }

  @Test func telegramDMKeysStillRoundTrip() {
    // given / when / then — the existing form is untouched
    #expect(SessionKey.telegramDM(chatId: 42) == "tg:dm:42")
    #expect(SessionKey.chatId(from: SessionKey.telegramDM(chatId: 42)) == 42)
  }

  @Test func telegramGroupTopicKeysRoundTripTheCompleteDestination() throws {
    // given
    let destination = TelegramDestination(chatId: -1_001_234, messageThreadId: 77)

    // when
    let key = SessionKey.telegramGroup(
      chatId: destination.chatId,
      messageThreadId: destination.messageThreadId
    )

    // then
    #expect(key == "tg:group:-1001234:topic:77")
    #expect(SessionKey.destination(from: key) == destination)
    #expect(SessionKey.conversationKind(from: key) == .group)
  }
}
