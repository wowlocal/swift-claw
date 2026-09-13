import Foundation

public struct ConferenceConfig: Sendable, Equatable {
  public enum EnvKey {
    public static let enabled = "CLAW_CONFERENCE_ENABLED"
    public static let caseFile = "CLAW_CONFERENCE_CASE_FILE"
    public static let seasonFile = "CLAW_CONFERENCE_SEASON_FILE"
    public static let expectedGitHubActor = "CLAW_CONFERENCE_EXPECTED_GITHUB_ACTOR"
  }

  public let enabled: Bool
  public let activeCase: ConferenceCase?
  public let season: ConferenceSeason?
  public let expectedGitHubActor: String?

  public init(
    enabled: Bool,
    activeCase: ConferenceCase?,
    season: ConferenceSeason? = nil,
    expectedGitHubActor: String?
  ) {
    self.enabled = enabled
    self.activeCase = activeCase
    self.season = season
    self.expectedGitHubActor = expectedGitHubActor
  }

  public static let disabled = ConferenceConfig(
    enabled: false,
    activeCase: nil,
    season: nil,
    expectedGitHubActor: nil
  )

  public var cases: [ConferenceCase] {
    season?.cases ?? activeCase.map { [$0] } ?? []
  }

  public func currentCase(at date: Date) -> ConferenceCase? {
    if let season {
      return season.caseItem(at: date)
    }
    return activeCase
  }

  /// Conference mode is an isolated deployment profile. Enabling it requires an explicit state
  /// root, one operator-authored case or season file, and the GitHub actor the result must prove.
  /// The ordinary single-owner daemon stays unchanged while this flag is absent.
  public static func load(environment: [String: String]) throws -> ConferenceConfig {
    let enabled = try bool(environment[EnvKey.enabled])
    guard enabled else {
      return .disabled
    }

    guard clean(environment[AppConfig.EnvKey.stateRoot]) != nil else {
      throw ConferenceConfigError.explicitStateRootRequired
    }

    let casePath = clean(environment[EnvKey.caseFile])
    let seasonPath = clean(environment[EnvKey.seasonFile])
    guard casePath != nil || seasonPath != nil else {
      throw ConferenceConfigError.invalidSetting(EnvKey.caseFile)
    }
    guard casePath == nil || seasonPath == nil else {
      throw ConferenceConfigError.invalidSetting(EnvKey.seasonFile)
    }

    let activeCase: ConferenceCase?
    let season: ConferenceSeason?
    if let casePath {
      activeCase = try loadCase(at: casePath)
      season = nil
    } else if let seasonPath {
      activeCase = nil
      season = try loadSeason(at: seasonPath)
    } else {
      throw ConferenceConfigError.invalidSetting(EnvKey.caseFile)
    }

    guard let actor = clean(environment[EnvKey.expectedGitHubActor]), validGitHubLogin(actor) else {
      throw ConferenceConfigError.invalidSetting(EnvKey.expectedGitHubActor)
    }

    return ConferenceConfig(
      enabled: true,
      activeCase: activeCase,
      season: season,
      expectedGitHubActor: actor
    )
  }
}

public enum ConferenceConfigError: Error, Sendable, Equatable, CustomStringConvertible {
  case invalidSetting(String)
  case explicitStateRootRequired
  case unreadableCaseFile
  case caseFileTooLarge
  case invalidCaseFile
  case unreadableSeasonFile
  case seasonFileTooLarge
  case invalidSeasonFile
  case coderRequired
  case isolatedCoderHomeRequired
  case githubTokenRequired
  case githubActorVerificationFailed
  case githubActorMismatch(expected: String, actual: String)

  public var description: String {
    switch self {
    case .invalidSetting(let key):
      return "Invalid conference setting: \(key)"
    case .explicitStateRootRequired:
      return "Conference workflow requires an explicit CLAW_STATE_ROOT for an isolated deployment"
    case .unreadableCaseFile:
      return "Conference case file cannot be read"
    case .caseFileTooLarge:
      return "Conference case file exceeds 128 KiB"
    case .invalidCaseFile:
      return "Conference case file is invalid"
    case .unreadableSeasonFile:
      return "Conference season file cannot be read"
    case .seasonFileTooLarge:
      return "Conference season file exceeds 128 KiB"
    case .invalidSeasonFile:
      return "Conference season file is invalid"
    case .coderRequired:
      return "Conference workflow requires CLAW_CODER_ENABLED=true"
    case .isolatedCoderHomeRequired:
      return "Conference workflow requires CLAW_CODER_CONFIG_HOME inside CLAW_STATE_ROOT"
    case .githubTokenRequired:
      return "Conference workflow requires a dedicated GH_TOKEN for the configured bot actor"
    case .githubActorVerificationFailed:
      return "Conference workflow could not verify the dedicated GitHub bot credential"
    case .githubActorMismatch(let expected, let actual):
      return "Conference GitHub credential belongs to \(actual), expected \(expected)"
    }
  }
}

private extension ConferenceConfig {
  static func loadCase(at path: String) throws -> ConferenceCase {
    guard path.hasPrefix("/") else {
      throw ConferenceConfigError.invalidSetting(EnvKey.caseFile)
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw ConferenceConfigError.unreadableCaseFile
    }
    guard data.count <= 128 * 1024 else {
      throw ConferenceConfigError.caseFileTooLarge
    }
    guard let item = try? JSONDecoder().decode(ConferenceCase.self, from: data) else {
      throw ConferenceConfigError.invalidCaseFile
    }
    try validate(item)
    return item
  }

  static func loadSeason(at path: String) throws -> ConferenceSeason {
    guard path.hasPrefix("/") else {
      throw ConferenceConfigError.invalidSetting(EnvKey.seasonFile)
    }
    let data: Data
    do {
      data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
      throw ConferenceConfigError.unreadableSeasonFile
    }
    guard data.count <= 128 * 1024 else {
      throw ConferenceConfigError.seasonFileTooLarge
    }
    guard let season = try? JSONDecoder().decode(ConferenceSeason.self, from: data) else {
      throw ConferenceConfigError.invalidSeasonFile
    }
    try validate(season)
    return season
  }

  static func validate(_ season: ConferenceSeason) throws {
    let weekdays = season.days.map(\.weekday)
    guard !season.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      season.name.count <= 200,
      !season.mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      season.mission.count <= 20_000,
      TimeZone(identifier: season.timeZone) != nil,
      !season.days.isEmpty,
      season.days.count <= ConferenceWeekday.allCases.count,
      Set(weekdays).count == weekdays.count
    else {
      throw ConferenceConfigError.invalidSeasonFile
    }
    do {
      for item in season.cases {
        try validate(item)
      }
    } catch {
      throw ConferenceConfigError.invalidSeasonFile
    }
  }

  static func bool(_ raw: String?) throws -> Bool {
    guard let value = clean(raw)?.lowercased() else {
      return false
    }
    switch value {
    case "true", "yes", "on", "1":
      return true
    case "false", "no", "off", "0":
      return false
    default:
      throw ConferenceConfigError.invalidSetting(EnvKey.enabled)
    }
  }

  static func clean(_ raw: String?) -> String? {
    guard let raw else {
      return nil
    }
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
      return nil
    }
    return value
  }

  static func validate(_ item: ConferenceCase) throws {
    guard item.id.count <= 64,
      item.id.first?.isLetter == true || item.id.first?.isNumber == true,
      item.id.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "-" }),
      !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      item.title.count <= 200,
      !item.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      item.prompt.count <= 20_000,
      validCommit(item.baselineRef),
      !item.baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      item.baseBranch.count <= 200
    else {
      throw ConferenceConfigError.invalidCaseFile
    }

    let request = CoderRequest(
      source: .githubRepository(url: item.repositoryURL),
      task: "conference configuration validation",
      workspace: .separate,
      startRef: item.baselineRef,
      deliverable: .pullRequest,
      baseBranch: item.baseBranch,
      instructions: nil,
      publishExistingChanges: false
    )
    do {
      _ = try request.validated()
    } catch {
      throw ConferenceConfigError.invalidCaseFile
    }
  }

  static func validCommit(_ value: String) -> Bool {
    (value.count == 40 || value.count == 64) && value.allSatisfy(\.isHexDigit)
  }

  static func validGitHubLogin(_ value: String) -> Bool {
    guard value.count <= 100, value.first != "-", value.last != "-" else {
      return false
    }
    return value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
  }
}
