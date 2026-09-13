import ClawCore
import ClawLLM
import ClawTestSupport
import ClawWorkspace
import Foundation
import Testing

@testable import clawd

@Suite struct ConferenceContextIsolationTests {
  @Test func conferenceContextUsesTheSeasonCaseForTheCurrentLocalWeekday() async throws {
    // given
    let root = try makeTemporaryRoot(prefix: "conference-season-context")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ])
    let http = ScriptedHTTPExecutor([])
    var builder = try CompositionAcceptance.makeBuilder(http: http, config: config)
    builder.now = { Date(timeIntervalSince1970: 1_789_459_200) }
    let workspace = FileSystemWorkspace(root: root.appendingPathComponent("workspace"))
    let providerStack = try builder.makeRosterStack(http: http)
    let sandbox = await builder.prepareSandbox()
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ContinuousClock())
    let season = ConferenceSeason(
      name: "Podlodka iOS Crew #18",
      mission: "Find the black box and return to base.",
      timeZone: "Europe/Moscow",
      repositoryURL: "https://github.com/wowlocal/crew18-sim",
      baselineRef: String(repeating: "a", count: 40),
      baseBranch: "main",
      days: [
        ConferenceDay(
          weekday: .tuesday,
          id: "accessibility",
          title: "Accessibility",
          prompt: "Make submarine controls accessible."
        ),
        ConferenceDay(
          weekday: .wednesday,
          id: "logging",
          title: "Logging",
          prompt: "Add an expedition log."
        ),
      ]
    )

    // when
    let agent = builder.makeAgentStack(
      roster: providerStack.roster,
      cooldown: cooldown,
      workspace: workspace,
      costResolver: CostResolver(
        priceTable: PriceFileLoader.load(),
        referenceUSDPerToken: 0.00001
      ),
      sandbox: sandbox,
      mcpTools: [],
      conferenceProfile: true,
      conferenceConfig: ConferenceConfig(
        enabled: true,
        activeCase: nil,
        season: season,
        expectedGitHubActor: "wowlocal"
      )
    )
    let result = try agent.contextBuilder.assemble(
      snapshot: SessionContextSnapshot(
        sessionKey: SessionKey.telegramTopic(chatId: -100, threadId: 199),
        history: [],
        historyMessageIds: [],
        windowStartMessageId: 0,
        isTainted: false,
        hasPrivateData: false
      ),
      sessionId: 1,
      origin: .interactive
    )

    // then
    let context = result.messages.map { $0.content.text }.joined(separator: "\n")
    #expect(context.contains(season.name))
    #expect(context.contains(season.mission))
    #expect(context.contains(season.repositoryURL))
    #expect(context.contains("Accessibility"))
    #expect(context.contains("Logging") == false)
  }

  @Test func conferenceContextKeepsParticipantHistoryWithoutSharedPrivateMaterial() async throws {
    // given — two real private conversations and shared workspace/memory on the same database.
    let root = try makeTemporaryRoot(prefix: "conference-context")
    defer { try? FileManager.default.removeItem(at: root) }
    let config = try AppConfig.load(environment: [
      AppConfig.EnvKey.stateRoot: root.path,
      AppConfig.EnvKey.llmModel: CompositionAcceptance.qualifiedModel,
    ])
    let http = ScriptedHTTPExecutor([])
    let builder = try CompositionAcceptance.makeBuilder(http: http, config: config)
    let workspace = FileSystemWorkspace(root: root.appendingPathComponent("workspace"))
    let workspaceMarkers = try seedWorkspace(at: workspace.root)
    let foreign = "accessibility PRIVATE_OTHER_PARTICIPANT"
    let ownHistory = "My earlier approach is OWN_HISTORY_MARKER"
    let ownAnswer = "accessibility MY_CURRENT_PROPOSAL"
    _ = try persist(foreign, userID: 101, updateID: 1, builder: builder)
    _ = try persist(ownHistory, userID: 202, updateID: 2, builder: builder)
    let claim = try persist(ownAnswer, userID: 202, updateID: 3, builder: builder)
    let sessionID = try #require(claim.sessionId)
    let snapshot = try builder.stores.sessionMessages.loadContextSnapshot(
      sessionId: sessionID,
      throughMessageId: #require(claim.messageId),
      limit: 20
    )
    let memoryMarker = "PRIVATE_DURABLE_MEMORY"
    _ = try builder.stores.memory.append(
      NewMemoryItem(text: memoryMarker, kind: .user, sessionId: nil),
      now: Date(timeIntervalSince1970: 1_700_000_000)
    )
    let providerStack = try builder.makeRosterStack(http: http)
    let sandbox = await builder.prepareSandbox()
    let cooldown = PrimaryRouteCooldown(longSeconds: 900, clock: ContinuousClock())

    // when — use the same production stack builder as daemon startup, in each product mode.
    for conferenceProfile in [false, true] {
      let agent = builder.makeAgentStack(
        roster: providerStack.roster,
        cooldown: cooldown,
        workspace: workspace,
        costResolver: CostResolver(
          priceTable: PriceFileLoader.load(),
          referenceUSDPerToken: 0.00001
        ),
        sandbox: sandbox,
        mcpTools: [],
        conferenceProfile: conferenceProfile
      )
      let result = try agent.contextBuilder.assemble(
        snapshot: snapshot,
        sessionId: sessionID,
        origin: .interactive
      )
      let text = result.messages.map { $0.content.text }.joined(separator: "\n")

      // then — ordinary mode is a positive control: the fixture really is recallable/readable.
      #expect(text.contains(ownHistory))
      #expect(text.contains(ownAnswer))
      for marker in workspaceMarkers + [foreign, memoryMarker] {
        #expect(text.contains(marker) == !conferenceProfile, "Unexpected context source: \(marker)")
      }
      #expect(result.hasPrivateDataAccess == !conferenceProfile)
    }
  }
}

private extension ConferenceContextIsolationTests {
  func seedWorkspace(at root: URL) throws -> [String] {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    var markers: [String] = []
    for file in [WorkspaceFile.soul, .agents, .tools, .user, .memory] {
      let marker = "PRIVATE_WORKSPACE_\(file.relativePath)"
      try Data(marker.utf8).write(to: root.appendingPathComponent(file.relativePath))
      markers.append(marker)
    }
    let skill = root.appendingPathComponent("skills/private-procedure", isDirectory: true)
    try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
    let marker = "PRIVATE_SKILL_INDEX"
    let content = """
      ---
      name: private-procedure
      description: \(marker)
      ---
      Private procedure body.
      """
    try Data(content.utf8).write(to: skill.appendingPathComponent("SKILL.md"))
    markers.append(marker)
    return markers
  }

  func persist(
    _ text: String,
    userID: Int64,
    updateID: Int64,
    builder: DaemonBuilder
  ) throws -> ClaimResult {
    try builder.stores.sessionMessages.claimAndPersistInbound(
      InboundMessage(
        updateId: updateID,
        sessionKey: SessionKey.telegramDM(chatId: userID),
        chatId: userID,
        userId: userID,
        text: text,
        isEdited: false,
        telegramMessageId: updateID,
        ts: Date(timeIntervalSince1970: 1_700_000_000)
      )
    )
  }
}
