import Foundation
import Testing

@testable import ClawCore

@Suite struct ConferenceConfigTests {
  @Test func disabledProfileRequiresNoConferenceSettings() throws {
    let config = try ConferenceConfig.load(environment: [:])

    #expect(config == .disabled)
  }

  @Test func enabledProfileRequiresExplicitStateRoot() throws {
    #expect(throws: ConferenceConfigError.explicitStateRootRequired) {
      _ = try ConferenceConfig.load(environment: [
        ConferenceConfig.EnvKey.enabled: "true"
      ])
    }
  }

  @Test func enabledProfileRequiresExpectedGitHubActor() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }

    #expect(
      throws: ConferenceConfigError.invalidSetting(
        ConferenceConfig.EnvKey.expectedGitHubActor
      )
    ) {
      _ = try ConferenceConfig.load(environment: fixture.environment(actor: nil))
    }
  }

  @Test func validProfileLoadsTrustedCaseAndActor() throws {
    let fixture = try Fixture()
    defer { fixture.cleanup() }

    let config = try ConferenceConfig.load(
      environment: fixture.environment(actor: "crew18-bot")
    )

    #expect(config.enabled)
    #expect(config.activeCase == fixture.caseItem)
    #expect(config.expectedGitHubActor == "crew18-bot")
  }

  @Test func seasonSelectsCasesUsingItsConfiguredTimeZone() throws {
    // given
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    let config = try ConferenceConfig.load(
      environment: fixture.seasonEnvironment(actor: "wowlocal")
    )

    // when
    let tuesday = config.currentCase(at: try date("2026-09-15T08:00:00Z"))
    let wednesday = config.currentCase(at: try date("2026-09-16T08:00:00Z"))
    let thursday = config.currentCase(at: try date("2026-09-17T08:00:00Z"))
    let friday = config.currentCase(at: try date("2026-09-18T08:00:00Z"))

    // then
    #expect(tuesday?.id == "accessibility")
    #expect(wednesday?.id == "logging")
    #expect(thursday?.id == "navigation")
    #expect(friday == nil)
    #expect(config.cases.count == 3)
    #expect(config.season?.mission == "Return from the expedition with a working submarine.")
  }

  @Test func enabledProfileAcceptsExactlyOneCaseSource() throws {
    // given
    let fixture = try Fixture()
    defer { fixture.cleanup() }
    var environment = fixture.seasonEnvironment(actor: "wowlocal")
    environment[ConferenceConfig.EnvKey.caseFile] = fixture.caseFile.path

    // when / then
    #expect(
      throws: ConferenceConfigError.invalidSetting(ConferenceConfig.EnvKey.seasonFile)
    ) {
      _ = try ConferenceConfig.load(environment: environment)
    }
  }
}

private extension ConferenceConfigTests {
  struct Fixture {
    let root: URL
    let caseFile: URL
    let seasonFile: URL
    let caseItem: ConferenceCase

    init() throws {
      root = FileManager.default.temporaryDirectory
        .appendingPathComponent("conference-config-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      caseFile = root.appendingPathComponent("case.json")
      seasonFile = root.appendingPathComponent("season.json")
      caseItem = ConferenceCase(
        id: "day-1",
        title: "Accessibility regression",
        prompt: "Propose a fix for the accessibility regression.",
        repositoryURL: "https://github.com/wowlocal/crew18-sim",
        baselineRef: String(repeating: "a", count: 40),
        baseBranch: "challenge/day-1"
      )
      try JSONEncoder().encode(caseItem).write(to: caseFile, options: .atomic)
      let season = ConferenceSeason(
        name: "Podlodka iOS Crew #18",
        mission: "Return from the expedition with a working submarine.",
        timeZone: "Europe/Moscow",
        repositoryURL: caseItem.repositoryURL,
        baselineRef: caseItem.baselineRef,
        baseBranch: caseItem.baseBranch,
        days: [
          ConferenceDay(
            weekday: .tuesday,
            id: "accessibility",
            title: "Accessibility",
            prompt: "Make the controls accessible."
          ),
          ConferenceDay(
            weekday: .wednesday,
            id: "logging",
            title: "Logging",
            prompt: "Add an expedition log."
          ),
          ConferenceDay(
            weekday: .thursday,
            id: "navigation",
            title: "Navigation",
            prompt: "Resume yesterday's state from a notification."
          ),
        ]
      )
      try JSONEncoder().encode(season).write(to: seasonFile, options: .atomic)
    }

    func environment(actor: String?) -> [String: String] {
      var environment = [
        ConferenceConfig.EnvKey.enabled: "true",
        AppConfig.EnvKey.stateRoot: root.path,
        ConferenceConfig.EnvKey.caseFile: caseFile.path,
      ]
      if let actor {
        environment[ConferenceConfig.EnvKey.expectedGitHubActor] = actor
      }
      return environment
    }

    func seasonEnvironment(actor: String?) -> [String: String] {
      var environment = [
        ConferenceConfig.EnvKey.enabled: "true",
        AppConfig.EnvKey.stateRoot: root.path,
        ConferenceConfig.EnvKey.seasonFile: seasonFile.path,
      ]
      if let actor {
        environment[ConferenceConfig.EnvKey.expectedGitHubActor] = actor
      }
      return environment
    }

    func cleanup() {
      try? FileManager.default.removeItem(at: root)
    }
  }

  func date(_ value: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: value))
  }
}
