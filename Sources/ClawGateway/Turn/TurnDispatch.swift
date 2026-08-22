import ClawCore
import Foundation
import Logging

/// The inbound plain-text → durable run bridge: fuses claim + persistence, then enqueues the
/// run and returns without awaiting it. Persistence failure prevents cursor advancement;
/// background turn failures are logged in-band by `TurnEnqueuer`.
struct TurnDispatch: Sendable {
  let sessionMessages: any SessionMessageStore

  let enqueuer: TurnEnqueuer
  let replies: ReplySender

  /// Where an inbound photo's bytes wait for the turn that replays them.
  let imageCache: ImageCache

  let now: @Sendable () -> Date
  let logger: Logger

  func dispatch(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String,
    provenance: Provenance = .trusted,
    image: ImagePart? = nil,
    disposition: InboundDisposition? = nil
  ) async throws(RoutingHalt) -> HandleOutcome {
    let isGroup = message.chatType.isGroup
    let resolvedDisposition = disposition ?? .startRun(origin: isGroup ? .group : .interactive)
    let inbound = InboundMessage(
      updateId: rawUpdate.updateId,
      sessionKey: sessionKey(for: message),
      chatId: message.chatId,
      userId: message.userId,
      text: text,
      isEdited: message.isEdited,
      provenance: provenance,
      telegramMessageId: message.messageId,
      messageThreadId: message.messageThreadId,
      sender: isGroup ? message.sender : nil,
      conversationKind: isGroup ? .group : .privateChat,
      disposition: resolvedDisposition,
      ts: now()
    )

    let claim = try await replies.perform(
      "inbound persist",
      updateId: rawUpdate.updateId,
      destination: message.destination
    ) {
      try sessionMessages.claimAndPersistInbound(inbound)
    }

    guard claim.newlyClaimed else {
      return replies.skipDuplicate(updateId: rawUpdate.updateId)
    }

    guard
      let sessionId = claim.sessionId,
      let runId = claim.runId,
      let triggerMessageId = claim.triggerMessageId
    else {
      return .processed
    }

    // The claim is what mints the row id the bytes are keyed by, so the deposit can only happen
    // here — and it must land before the run is enqueued, or the turn it belongs to looks text-only.
    if let image {
      await imageCache.store(image, sessionId: sessionId, messageId: triggerMessageId)
    }

    // The inbound → run bridge: the one INFO line that shows a real message was accepted and
    // which run it became. run/session/update ride as metadata so the whole lifecycle greps by
    // `run=<id>`; only the message SIZE is logged, never its text.
    var runLog = logger
    runLog[metadataKey: "run"] = "\(runId)"
    runLog[metadataKey: "session"] = "\(sessionId)"
    runLog[metadataKey: "update"] = "\(rawUpdate.updateId)"
    runLog.info(
      """
      message accepted; dispatching run \
      (chars=\(text.count) edited=\(message.isEdited) image=\(image != nil))
      """
    )

    await enqueuer.enqueue(
      runId: runId,
      sessionId: sessionId,
      destination: message.destination,
      triggerMessageId: triggerMessageId,
      log: runLog
    )

    return .processed
  }

  func archive(
    rawUpdate: RawUpdate,
    message: IncomingMessage,
    text: String
  ) async throws(RoutingHalt) -> HandleOutcome {
    try await dispatch(
      rawUpdate: rawUpdate,
      message: message,
      text: text,
      provenance: .untrusted,
      disposition: .archiveOnly
    )
  }

  private func sessionKey(for message: IncomingMessage) -> String {
    if message.chatType.isGroup {
      return SessionKey.telegramGroup(
        chatId: message.chatId,
        messageThreadId: message.messageThreadId
      )
    }
    return SessionKey.telegramDM(chatId: message.chatId)
  }
}
