import AppKit
import SwiftUI

@MainActor
class MenuBarManager: NSObject {
    private let statusItem: NSStatusItem
    private let button: NSStatusBarButton
    private var menu: NSMenu!
    private var usageData: UsageResponse?
    private var lastUpdatedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var apiClient: ClaudeAPIClient?
    private var settings: ClaudeSettings?
    private var settingsWindowController: SettingsWindowController?
    private let logger = Logger.shared

    // App version
    nonisolated private let appVersion = "1.2.3"

    // Auto-detection retry tracking
    private var lastAutoDetectionAttempt: Date?
    private let autoDetectionCooldownSeconds: TimeInterval = 300 // 5 minutes

    init(statusItem: NSStatusItem, button: NSStatusBarButton) {
        self.statusItem = statusItem
        self.button = button
        super.init()

        Task { await logger.log("MenuBarManager initializing", level: .info) }
        setupMenu()
        loadSettings()
        updateIcon(percentage: nil)
        updateMenu()  // Initialize menu even without credentials
        startPeriodicRefresh()
    }

    private func loadSettings() {
        Task { await logger.log("Loading settings", level: .info) }
        settings = ClaudeSettings.load()

        if let settings = settings {
            Task { await logger.log("Settings loaded successfully", level: .info) }
            Task { await logger.log("Organization ID: \(settings.organizationId)", level: .debug) }
            apiClient = ClaudeAPIClient(settings: settings)
            Task {
                await refreshUsage()
            }
        } else {
            Task { await logger.log("No settings found, showing auto-detection prompt", level: .info) }
            // Show prompt before attempting auto-detection
            showAutoDetectionPrompt()
        }
    }

    private func showAutoDetectionPrompt() {
        let alert = NSAlert()
        alert.messageText = "Welcome to ClaudeMeter"
        alert.informativeText = """
        ClaudeMeter can automatically detect your Claude credentials from:
        • Claude Desktop app
        • Brave Browser
        • Google Chrome

        This requires accessing your macOS Keychain to decrypt cookies.
        You'll see a system prompt asking for permission.

        Alternatively, you can configure credentials manually in Settings.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Try Auto-Detection")
        alert.addButton(withTitle: "Configure Manually")

        let response = alert.runModal()

        if response == .alertFirstButtonReturn {
            // User chose auto-detection
            Task { await logger.log("User chose auto-detection", level: .info) }
            tryAutoDetection()
        } else {
            // User chose manual configuration
            Task { await logger.log("User chose manual configuration", level: .info) }
            updateMenu()  // Update menu to show setup options
        }
    }

    private func tryAutoDetection(isRetry: Bool = false) {
        // Update last attempt timestamp
        lastAutoDetectionAttempt = Date()

        Task { @MainActor in
            let extractor = CredentialExtractor()
            if let credentials = extractor.extractCredentials() {
                await logger.log("Auto-detection successful", level: .info)

                if let orgId = credentials.organizationId, let sessionKey = credentials.sessionKey {
                    let newSettings = ClaudeSettings(
                        organizationId: orgId,
                        sessionKey: sessionKey,
                        autoTriggerQuota: false,
                        happyHourPeakWindow: .default
                    )

                    do {
                        try newSettings.save()
                        settings = newSettings
                        apiClient = ClaudeAPIClient(settings: newSettings)

                        Task {
                            await refreshUsage()
                        }

                        if isRetry {
                            await logger.log("Credentials refreshed automatically from \(credentials.source)", level: .info)
                        } else {
                            showNotification(title: "ClaudeMeter Ready", message: "Credentials detected from \(credentials.source)")
                        }
                    } catch {
                        await logger.log("Error saving auto-detected settings: \(error)", level: .error)
                    }
                }
            } else {
                await logger.log("Auto-detection failed, user needs to configure manually", level: .warning)
                updateMenu()  // Update menu to show setup options
            }
        }
    }

    private func canRetryAutoDetection() -> Bool {
        guard let lastAttempt = lastAutoDetectionAttempt else {
            return true // Never tried, can retry
        }

        let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
        let canRetry = timeSinceLastAttempt >= autoDetectionCooldownSeconds

        if !canRetry {
            let remainingTime = Int(autoDetectionCooldownSeconds - timeSinceLastAttempt)
            Task { await logger.log("Auto-detection on cooldown. Retry available in \(remainingTime)s", level: .debug) }
        }

        return canRetry
    }

    private func showNotification(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func setupMenu() {
        menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    private func startPeriodicRefresh() {
        Task { await logger.log("Starting periodic refresh (60s interval)", level: .debug) }

        refreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                await refreshUsage()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func refreshUsage() async {
        guard let apiClient = apiClient else {
            await logger.log("Cannot refresh: No API client configured", level: .debug)
            return
        }

        await logger.log("Fetching usage data", level: .debug)

        do {
            usageData = try await apiClient.fetchUsage()
            lastUpdatedAt = Date()

            // Check for null state (quota period expired) and auto-trigger if enabled
            if let settings = settings, settings.autoTriggerQuota {
                if let fiveHour = usageData?.fiveHour, fiveHour.resetsAt == nil {
                    await logger.log("Detected null quota state with auto-trigger enabled", level: .info)
                    await triggerQuotaPeriod()
                    // Refresh usage data after triggering
                    usageData = try await apiClient.fetchUsage()
                }
            }

            // Update menu and icon after data is fetched
            updateMenu()

            if let percentage = usageData?.fiveHour?.utilization {
                await logger.log("Usage: \(percentage)%", level: .debug)
                updateIcon(percentage: percentage)
            }
        } catch {
            await logger.log("Error fetching usage: \(error)", level: .error)
            updateIcon(percentage: nil)

            // Check if it's an authentication error and retry credential detection
            if let apiError = error as? ClaudeAPIClient.APIError,
               case .httpError(let statusCode) = apiError,
               (statusCode == 401 || statusCode == 403) {

                await logger.log("Authentication error detected (HTTP \(statusCode)). Credentials may have expired.", level: .warning)

                if canRetryAutoDetection() {
                    await logger.log("Attempting to refresh credentials automatically...", level: .info)
                    tryAutoDetection(isRetry: true)
                } else {
                    await logger.log("Cannot retry yet - cooldown period active", level: .debug)
                }
            }
        }
    }

    private func triggerQuotaPeriod() async {
        guard let apiClient = apiClient else {
            await logger.log("Cannot trigger quota: No API client configured", level: .error)
            return
        }

        await logger.log("Smart quota refresh: Triggering new quota period", level: .info)

        do {
            let resetsAt = try await apiClient.triggerQuotaPeriod()
            await logger.log("Smart quota refresh: New quota period started, resets at: \(resetsAt)", level: .info)
        } catch {
            await logger.log("Smart quota refresh: Error triggering quota period: \(error)", level: .error)
        }
    }

    private func updateIcon(percentage: Double?) {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // Draw circle background
            context.setStrokeColor(NSColor.labelColor.withAlphaComponent(0.3).cgColor)
            context.setLineWidth(2.0)
            let circlePath = CGPath(ellipseIn: rect.insetBy(dx: 2, dy: 2), transform: nil)
            context.addPath(circlePath)
            context.strokePath()

            // Draw usage arc if we have a percentage
            if let percentage = percentage {
                let center = CGPoint(x: rect.midX, y: rect.midY)
                let radius = (rect.width - 4) / 2
                let startAngle = -CGFloat.pi / 2 // Start at top
                let endAngle = startAngle + (2 * CGFloat.pi * CGFloat(percentage / 100.0))

                // Color based on usage
                let color: NSColor
                if percentage < 50 {
                    color = .systemGreen
                } else if percentage < 80 {
                    color = .systemYellow
                } else {
                    color = .systemRed
                }

                context.setStrokeColor(color.cgColor)
                context.setLineWidth(2.0)
                context.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
                context.strokePath()
            }

            return true
        }

        image.isTemplate = true
        button.image = image

        // Add percentage text as title
        let baseTitle: String
        if let percentage = percentage {
            baseTitle = " \(Int(percentage))%"
        } else {
            baseTitle = " --"
        }

        if let happyHourTitle = happyHourTitle() {
            button.title = "\(baseTitle) \(happyHourTitle)"
        } else {
            button.title = baseTitle
        }
    }

    private func updateMenu() {
        menu.removeAllItems()

        if let usage = usageData, settings != nil {
            let headerItem = NSMenuItem(title: "Claude Usage", action: nil, keyEquivalent: "")
            headerItem.isEnabled = false
            menu.addItem(headerItem)

            if let updatedText = lastUpdatedText() {
                let lastUpdated = NSMenuItem(title: updatedText, action: nil, keyEquivalent: "")
                lastUpdated.isEnabled = false
                menu.addItem(lastUpdated)
            }

            let usageMetrics = usageMenuMetrics(from: usage)
            let peakMetric = peakWindowMenuMetric()

            if !usageMetrics.isEmpty || peakMetric != nil {
                menu.addItem(NSMenuItem.separator())
            }

            for metric in usageMetrics {
                menu.addItem(makeProgressMenuItem(
                    title: metric.title,
                    value: metric.value,
                    detail: metric.detail,
                    secondaryDetail: metric.secondaryDetail,
                    accentColor: metric.accentColor
                ))
            }

            if let peakMetric {
                if !usageMetrics.isEmpty {
                    menu.addItem(NSMenuItem.separator())
                }

                menu.addItem(makeProgressMenuItem(
                    title: peakMetric.title,
                    value: peakMetric.value,
                    detail: peakMetric.detail,
                    secondaryDetail: peakMetric.secondaryDetail,
                    accentColor: peakMetric.accentColor
                ))
            }

            menu.addItem(NSMenuItem.separator())

            let refreshItem = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
            refreshItem.target = self
            menu.addItem(refreshItem)

            menu.addItem(NSMenuItem.separator())

            // Smart Quota Refresh toggle
            let smartQuotaItem = NSMenuItem(title: "Smart Quota Refresh", action: #selector(toggleSmartQuota), keyEquivalent: "")
            smartQuotaItem.target = self
            smartQuotaItem.state = settings?.autoTriggerQuota == true ? .on : .off
            menu.addItem(smartQuotaItem)

            // Info text below toggle
            let infoItem = NSMenuItem(title: "   Keeps your quota window active", action: nil, keyEquivalent: "")
            infoItem.isEnabled = false
            menu.addItem(infoItem)

            menu.addItem(NSMenuItem.separator())

            // Launch at login toggle
            let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
            launchAtLoginItem.target = self
            launchAtLoginItem.state = LaunchAtLoginHelper.isEnabled ? .on : .off
            menu.addItem(launchAtLoginItem)

            menu.addItem(NSMenuItem.separator())

            let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
            settingsItem.target = self
            menu.addItem(settingsItem)

            let logsItem = NSMenuItem(title: "View Logs", action: #selector(openLogs), keyEquivalent: "")
            logsItem.target = self
            menu.addItem(logsItem)

            menu.addItem(NSMenuItem.separator())

            let versionItem = NSMenuItem(title: "Version \(appVersion)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)

            let quitItem = NSMenuItem(title: "Quit ClaudeMeter", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        } else {
            let setupItem = NSMenuItem(title: "⚠️ Setup Required", action: nil, keyEquivalent: "")
            setupItem.isEnabled = false
            menu.addItem(setupItem)

            menu.addItem(NSMenuItem.separator())

            let configItem = NSMenuItem(title: "Configure Settings...", action: #selector(openSettings), keyEquivalent: "")
            configItem.target = self
            menu.addItem(configItem)

            let logsItem = NSMenuItem(title: "View Logs", action: #selector(openLogs), keyEquivalent: "")
            logsItem.target = self
            menu.addItem(logsItem)

            menu.addItem(NSMenuItem.separator())

            let versionItem = NSMenuItem(title: "Version \(appVersion)", action: nil, keyEquivalent: "")
            versionItem.isEnabled = false
            menu.addItem(versionItem)

            let quitItem = NSMenuItem(title: "Quit ClaudeMeter", action: #selector(quit), keyEquivalent: "q")
            quitItem.target = self
            menu.addItem(quitItem)
        }
    }

    @objc private func refreshNow() {
        Task { await logger.log("Manual refresh triggered", level: .info) }
        Task {
            await refreshUsage()
        }
    }

    @objc private func toggleSmartQuota() {
        guard var currentSettings = settings else {
            Task { await logger.log("Cannot toggle smart quota: No settings configured", level: .error) }
            return
        }

        // Toggle the setting
        currentSettings.autoTriggerQuota.toggle()

        // Save to disk
        do {
            try currentSettings.save()
            settings = currentSettings
            Task { await logger.log("Smart Quota Refresh toggled: \(currentSettings.autoTriggerQuota)", level: .info) }
            updateMenu()

            // Show brief explanation on first enable
            if currentSettings.autoTriggerQuota {
                Task {
                    // Check if quota is currently in null state and trigger immediately
                    if let fiveHour = usageData?.fiveHour, fiveHour.resetsAt == nil {
                        await logger.log("Quota in null state, triggering immediately", level: .info)
                        await triggerQuotaPeriod()
                        await refreshUsage()
                    }
                }
            }
        } catch {
            Task { await logger.log("Error saving smart quota setting: \(error)", level: .error) }
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = "Could not save setting: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginHelper.toggle()
            Task { await logger.log("Launch at login toggled: \(LaunchAtLoginHelper.isEnabled)", level: .info) }
            updateMenu()
        } catch {
            Task { await logger.log("Error toggling launch at login: \(error)", level: .error) }
            let alert = NSAlert()
            alert.messageText = "Error"
            alert.informativeText = "Could not toggle launch at login: \(error.localizedDescription)"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func openSettings() {
        Task { await logger.log("Opening settings window", level: .info) }

        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(currentSettings: settings) { [weak self] newSettings in
                Task { await self?.logger.log("Settings updated", level: .info) }
                self?.settings = newSettings
                self?.apiClient = ClaudeAPIClient(settings: newSettings)

                Task {
                    await self?.refreshUsage()
                }
            }
        }

        settingsWindowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openLogs() {
        let logPath = logger.getLogFilePath()
        Task { await logger.log("Opening logs at: \(logPath)", level: .info) }

        NSWorkspace.shared.open(URL(fileURLWithPath: logPath))
    }

    @objc private func quit() {
        Task { await logger.log("ClaudeMeter quitting", level: .info) }
        NSApplication.shared.terminate(nil)
    }

    private func currentHappyHourStatus() -> HappyHourStatus? {
        settings?.happyHourPeakWindow.status()
    }

    private func usageMenuMetrics(from usage: UsageResponse) -> [MenuProgressMetric] {
        [
            metric(title: "5h Window", period: usage.fiveHour),
            metric(title: "7d Window", period: usage.sevenDay),
            metric(title: "7d OAuth Apps", period: usage.sevenDayOauthApps),
            metric(title: "7d Opus", period: usage.sevenDayOpus),
            metric(title: "Iguana Necktie", period: usage.iguanaNecktie)
        ].compactMap { $0 }
    }

    private func metric(title: String, period: UsagePeriod?) -> MenuProgressMetric? {
        guard let period else { return nil }

        let detail: String
        if period.resetsAt != nil {
            detail = "\(Int(period.utilization))% used • resets in \(period.timeUntilReset)"
        } else {
            detail = "\(Int(period.utilization))% used • waiting for next reset"
        }

        return MenuProgressMetric(
            title: title,
            value: period.utilization / 100.0,
            detail: detail,
            secondaryDetail: nil,
            accentColor: progressColor(for: period.utilization / 100.0)
        )
    }

    private func peakWindowMenuMetric() -> MenuProgressMetric? {
        guard let settings else { return nil }

        let status = settings.happyHourPeakWindow.status()
        let progress = peakWindowProgress(for: settings.happyHourPeakWindow)
        let stateLabel = status.isHappyHour ? "Happy hour" : "Peak active"
        let timeZoneLabel = settings.happyHourPeakWindow.timeZone.abbreviation() ?? settings.happyHourPeakWindow.tz
        let schedule = "\(settings.happyHourPeakWindow.start)-\(settings.happyHourPeakWindow.end) \(timeZoneLabel)"

        let detail: String
        if status.isHappyHour, let countdown = status.countdownText {
            detail = "\(stateLabel) • peak resumes in \(countdown)"
        } else {
            detail = stateLabel
        }

        return MenuProgressMetric(
            title: "Peak Window",
            value: progress,
            detail: detail,
            secondaryDetail: schedule,
            accentColor: status.isHappyHour ? .systemBlue : .systemOrange
        )
    }

    private func peakWindowProgress(for window: HappyHourPeakWindow, at date: Date = Date()) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = window.timeZone

        let weekday = calendar.component(.weekday, from: date) - 1
        guard window.days.contains(weekday) else {
            return 0
        }

        let totalMinutes = max(window.endMinutes - window.startMinutes, 1)
        let currentMinutes = (calendar.component(.hour, from: date) * 60) + calendar.component(.minute, from: date)
        let elapsed = min(max(currentMinutes - window.startMinutes, 0), totalMinutes)
        return Double(elapsed) / Double(totalMinutes)
    }

    private func progressColor(for value: Double) -> NSColor {
        if value < 0.5 {
            return .systemGreen
        } else if value < 0.8 {
            return .systemYellow
        } else {
            return .systemRed
        }
    }

    private func lastUpdatedText(now: Date = Date()) -> String? {
        guard let lastUpdatedAt else { return nil }

        let interval = max(0, Int(now.timeIntervalSince(lastUpdatedAt)))
        if interval < 5 {
            return "Last updated: just now"
        }
        if interval < 60 {
            return "Last updated: \(interval)s ago"
        }

        let minutes = interval / 60
        return "Last updated: \(minutes)m ago"
    }

    private func happyHourTitle() -> String? {
        guard let status = currentHappyHourStatus(),
              status.isHappyHour,
              let countdown = status.countdownText else {
            return nil
        }

        return "✨ \(countdown)"
    }
}

extension MenuBarManager: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        // Don't call refreshUsage here - it causes layout shifts
        // The menu is already up-to-date from the periodic refresh
        // Only log for debugging purposes
        Task { await logger.log("Menu opened", level: .debug) }
    }
}

private struct MenuProgressMetric {
    let title: String
    let value: Double
    let detail: String
    let secondaryDetail: String?
    let accentColor: NSColor
}

private extension MenuBarManager {
    func makeProgressMenuItem(title: String, value: Double, detail: String, secondaryDetail: String?, accentColor: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
        item.view = MenuProgressItemView(
            frame: NSRect(x: 0, y: 0, width: 320, height: secondaryDetail == nil ? 76 : 92),
            title: title,
            value: value,
            detail: detail,
            secondaryDetail: secondaryDetail,
            accentColor: accentColor
        )
        return item
    }
}

private final class MenuProgressItemView: NSView {
    private let preferredHeight: CGFloat

    init(frame frameRect: NSRect, title: String, value: Double, detail: String, secondaryDetail: String?, accentColor: NSColor) {
        self.preferredHeight = frameRect.height
        super.init(frame: frameRect)

        let clampedValue = min(max(value, 0), 1)

        let titleField = NSTextField(labelWithString: title)
        titleField.font = .systemFont(ofSize: 12, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        let detailField = NSTextField(labelWithString: detail)
        detailField.font = .systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byWordWrapping
        detailField.maximumNumberOfLines = 2
        detailField.cell?.wraps = true
        detailField.setContentCompressionResistancePriority(.required, for: .vertical)
        detailField.setContentHuggingPriority(.required, for: .vertical)
        titleField.setContentCompressionResistancePriority(.required, for: .vertical)
        titleField.setContentHuggingPriority(.required, for: .vertical)

        let secondaryDetailField: NSTextField?
        if let secondaryDetail {
            let field = NSTextField(labelWithString: secondaryDetail)
            field.font = .systemFont(ofSize: 11)
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            secondaryDetailField = field
        } else {
            secondaryDetailField = nil
        }

        let progressIndicator = MenuProgressBarView(
            frame: NSRect(x: 0, y: 0, width: 0, height: 8),
            value: clampedValue,
            accentColor: accentColor
        )
        progressIndicator.translatesAutoresizingMaskIntoConstraints = false

        var arrangedSubviews: [NSView] = [titleField, progressIndicator, detailField]
        if let secondaryDetailField {
            arrangedSubviews.append(secondaryDetailField)
        }

        let stack = NSStackView(views: arrangedSubviews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            progressIndicator.heightAnchor.constraint(equalToConstant: 8),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: preferredHeight)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private final class MenuProgressBarView: NSView {
    private let value: Double
    private let accentColor: NSColor

    init(frame frameRect: NSRect, value: Double, accentColor: NSColor) {
        self.value = value
        self.accentColor = accentColor
        super.init(frame: frameRect)
        wantsLayer = true
    }

    override func layout() {
        super.layout()

        guard let layer else { return }
        layer.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.16).cgColor
        layer.cornerRadius = bounds.height / 2
        layer.masksToBounds = true

        let fillLayer: CALayer
        if let existing = layer.sublayers?.first {
            fillLayer = existing
        } else {
            fillLayer = CALayer()
            layer.addSublayer(fillLayer)
        }

        fillLayer.backgroundColor = accentColor.cgColor
        fillLayer.cornerRadius = bounds.height / 2
        fillLayer.frame = NSRect(
            x: 0,
            y: 0,
            width: bounds.width * value,
            height: bounds.height
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
