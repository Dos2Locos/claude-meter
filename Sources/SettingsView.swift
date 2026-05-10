import SwiftUI

struct SettingsView: View {
    private static let weekdayOptions: [(day: Int, label: String)] = [
        (0, "Sun"),
        (1, "Mon"),
        (2, "Tue"),
        (3, "Wed"),
        (4, "Thu"),
        (5, "Fri"),
        (6, "Sat")
    ]

    @Environment(\.dismiss) private var dismiss

    @State private var organizationId: String
    @State private var sessionKey: String
    @State private var peakDays: Set<Int>
    @State private var peakStart: String
    @State private var peakEnd: String
    @State private var peakTimeZone: String
    @State private var isAutoExtracting = false
    @State private var extractionResult: String?
    @State private var showError = false
    @State private var errorMessage = ""
    @State private var showHelpAlert = false

    let onSave: (ClaudeSettings) -> Void

    init(currentSettings: ClaudeSettings?, onSave: @escaping (ClaudeSettings) -> Void) {
        let peakWindow = currentSettings?.happyHourPeakWindow ?? .default
        _organizationId = State(initialValue: currentSettings?.organizationId ?? "")
        _sessionKey = State(initialValue: currentSettings?.sessionKey ?? "")
        _peakDays = State(initialValue: Set(peakWindow.days))
        _peakStart = State(initialValue: peakWindow.start)
        _peakEnd = State(initialValue: peakWindow.end)
        _peakTimeZone = State(initialValue: peakWindow.tz)
        self.onSave = onSave
    }

    var body: some View {
        VStack(spacing: 0) {
            if isAutoExtracting {
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)
                    Text("Searching for credentials...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        credentialsSection
                        happyHourSection
                    }
                    .padding()
                }

                // Bottom action bar
                HStack(spacing: 12) {
                    Button("Auto-Detect") {
                        autoDetectCredentials()
                    }
                    .buttonStyle(.bordered)

                    Spacer()

                    Button("Cancel") {
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)

                    Button("Save") {
                        saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(organizationId.isEmpty || sessionKey.isEmpty)
                }
                .padding()
                .background(.regularMaterial)
            }
        }
        .frame(width: 540, height: 560)
        .alert("Error", isPresented: $showError) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(errorMessage)
        }
        .alert("How to Get Credentials Manually", isPresented: $showHelpAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("""
            For Chrome/Brave browsers:

            1. Open https://claude.ai in your browser
            2. Make sure you're logged in
            3. Press F12 to open Developer Tools
            4. Click on the "Application" tab
            5. In the left sidebar, expand "Cookies"
            6. Click on "https://claude.ai"

            7. Find and copy these two cookies:
               • sessionKey: Copy the entire value
               • lastActiveOrg: This is your Organization ID

            8. Paste them into the fields above

            Note: sessionKey usually starts with "sk-ant-sid01-"
            """)
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Credentials")
                    .font(.headline)

                Spacer()

                Button(action: { showHelpAlert = true }) {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .help("How to get credentials manually")
            }

            Text("Required to monitor your Claude usage")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text("Organization ID")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("6e35a193-deaa-46a0-80bd-f7a1652d383f", text: $organizationId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Session Key")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                SecureField("sk-ant-sid01-...", text: $sessionKey)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            if let result = extractionResult {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text(result)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private var happyHourSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Happy Hour")
                .font(.headline)

            Text("Peak hours are checked in the configured timezone. Happy hour is everything outside that peak window.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text("Peak Days")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                    ForEach(Self.weekdayOptions, id: \.day) { option in
                        Toggle(option.label, isOn: Binding(
                            get: { peakDays.contains(option.day) },
                            set: { isEnabled in
                                if isEnabled {
                                    peakDays.insert(option.day)
                                } else {
                                    peakDays.remove(option.day)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Peak Start")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("05:00", text: $peakStart)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Peak End")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    TextField("23:00", text: $peakEnd)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Peak Time Zone")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("America/Los_Angeles", text: $peakTimeZone)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            Text("Invalid fields fall back individually to Anthropic defaults when saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func autoDetectCredentials() {
        isAutoExtracting = true
        extractionResult = nil

        Task {
            let extractor = CredentialExtractor()

            if let credentials = extractor.extractCredentials() {
                await MainActor.run {
                    if let orgId = credentials.organizationId {
                        organizationId = orgId
                    }
                    if let sessionKey = credentials.sessionKey {
                        self.sessionKey = sessionKey
                    }

                    extractionResult = "Credentials found in \(credentials.source)"
                    isAutoExtracting = false
                }
            } else {
                await MainActor.run {
                    isAutoExtracting = false
                    errorMessage = """
                    Could not automatically detect credentials.

                    Please enter them manually:

                    1. Open https://claude.ai/settings/usage
                    2. Open Developer Tools (Cmd+Option+I)
                    3. Go to Network tab and refresh
                    4. Find the 'usage' request
                    5. Copy Organization ID from URL
                    6. Copy Session Key from Cookie header
                    """
                    showError = true
                }
            }
        }
    }

    private func saveSettings() {
        let existingSettings = ClaudeSettings.load()

        let settings = ClaudeSettings(
            organizationId: organizationId.trimmingCharacters(in: .whitespacesAndNewlines),
            sessionKey: sessionKey.trimmingCharacters(in: .whitespacesAndNewlines),
            autoTriggerQuota: existingSettings?.autoTriggerQuota ?? false,
            happyHourPeakWindow: HappyHourPeakWindow(
                days: peakDays.sorted(),
                start: peakStart.trimmingCharacters(in: .whitespacesAndNewlines),
                end: peakEnd.trimmingCharacters(in: .whitespacesAndNewlines),
                tz: peakTimeZone.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        )

        do {
            try settings.save()
            Task { await Logger.shared.log("Settings saved successfully", level: .info) }
            onSave(settings)
            dismiss()
        } catch {
            Task { await Logger.shared.log("Error saving settings: \(error)", level: .error) }
            errorMessage = "Failed to save settings: \(error.localizedDescription)"
            showError = true
        }
    }
}

// Settings Window Controller
class SettingsWindowController: NSWindowController {
    convenience init(currentSettings: ClaudeSettings?, onSave: @escaping (ClaudeSettings) -> Void) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 560),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.title = "Settings"
        window.titlebarAppearsTransparent = true
        window.center()
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true

        let settingsView = SettingsView(currentSettings: currentSettings, onSave: onSave)
        window.contentView = NSHostingView(rootView: settingsView)

        self.init(window: window)
    }
}
