import Foundation

struct UsageResponse: Codable, Sendable {
    let fiveHour: UsagePeriod?
    let sevenDay: UsagePeriod?
    let sevenDayOauthApps: UsagePeriod?
    let sevenDayOpus: UsagePeriod?
    let iguanaNecktie: UsagePeriod?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case sevenDayOauthApps = "seven_day_oauth_apps"
        case sevenDayOpus = "seven_day_opus"
        case iguanaNecktie = "iguana_necktie"
    }
}

struct UsagePeriod: Codable, Sendable {
    let utilization: Double
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }

    var resetsAtDate: Date? {
        guard let resetsAt = resetsAt else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: resetsAt)
    }

    var timeUntilReset: String {
        guard let resetDate = resetsAtDate else { return "N/A" }
        let now = Date()
        let interval = resetDate.timeIntervalSince(now)

        if interval < 0 {
            return "Expired"
        }

        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60

        if hours > 0 {
            return "\(hours) hr \(minutes) min"
        } else {
            return "\(minutes) min"
        }
    }
}

struct ClaudeSettings: Codable, Sendable {
    var organizationId: String
    var sessionKey: String
    var autoTriggerQuota: Bool
    var happyHourPeakWindow: HappyHourPeakWindow

    enum CodingKeys: String, CodingKey {
        case organizationId
        case sessionKey
        case autoTriggerQuota
        case happyHourPeakWindow
    }

    static let settingsURL: URL = {
        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
        let configDirectory = homeDirectory.appendingPathComponent(".config/claude-meter")
        try? FileManager.default.createDirectory(at: configDirectory, withIntermediateDirectories: true)
        return configDirectory.appendingPathComponent("settings.json")
    }()

    init(
        organizationId: String,
        sessionKey: String,
        autoTriggerQuota: Bool = false,
        happyHourPeakWindow: HappyHourPeakWindow = .default
    ) {
        self.organizationId = organizationId
        self.sessionKey = sessionKey
        self.autoTriggerQuota = autoTriggerQuota
        self.happyHourPeakWindow = happyHourPeakWindow
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        organizationId = try container.decode(String.self, forKey: .organizationId)
        sessionKey = try container.decode(String.self, forKey: .sessionKey)
        autoTriggerQuota = try container.decodeIfPresent(Bool.self, forKey: .autoTriggerQuota) ?? false
        happyHourPeakWindow = try container.decodeIfPresent(HappyHourPeakWindow.self, forKey: .happyHourPeakWindow) ?? .default
    }

    static func load() -> ClaudeSettings? {
        guard let data = try? Data(contentsOf: settingsURL) else { return nil }
        return try? JSONDecoder().decode(ClaudeSettings.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.settingsURL)
    }
}

// MARK: - Quota Period Trigger Models

struct ConversationResponse: Codable, Sendable {
    let uuid: String
    let name: String
}

struct MessageLimitEvent: Codable, Sendable {
    let type: String
    let messageLimit: MessageLimit

    enum CodingKeys: String, CodingKey {
        case type
        case messageLimit = "message_limit"
    }
}

struct MessageLimit: Codable, Sendable {
    let type: String
    let windows: Windows
}

struct Windows: Codable, Sendable {
    let fiveHour: WindowDetail

    enum CodingKeys: String, CodingKey {
        case fiveHour = "5h"
    }
}

struct WindowDetail: Codable, Sendable {
    let status: String
    let resetsAt: Int

    enum CodingKeys: String, CodingKey {
        case status
        case resetsAt = "resets_at"
    }
}
