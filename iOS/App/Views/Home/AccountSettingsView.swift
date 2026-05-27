import SwiftUI

/// Read-only "Account" surface that consolidates everything the user
/// might want to glance at without digging through the home menu:
/// their identity, the paired workspace, the device the app is
/// running on, app version + build, and the sign-out affordance.
///
/// Reached from the home toolbar's `⋯` menu → **Account**. The
/// existing menu-level **Sign out** entry stays too — destructive
/// affordances near the top of the menu are familiar muscle memory,
/// and this sheet is the deeper detail view for users who want to
/// double-check which workspace they're paired to before signing
/// out.
///
/// Everything renders as plain rows in a `Form`. Long values
/// (workspace host, device UUID) render in DM Mono with truncation +
/// long-press copy via the OS context menu.
struct AccountSettingsView: View {

    /// Active workspace + project + user context. Required —
    /// `HomeContainerView` only presents the sheet when the
    /// coordinator has one, so we don't need to handle the nil
    /// state inside the view.
    let context: ActiveContext
    /// Optional device-identity store. When wired, the Device
    /// section shows the per-device UUID (loaded lazily inside a
    /// `.task`). Without it the row reads `—` so the section still
    /// shows the rest of the device metadata.
    let deviceIdentity: (any DeviceIdentityStore)?
    /// Sign-out callback. The sheet dismisses itself, then the
    /// caller routes the workspace ID into
    /// `AppCoordinator.signOut(workspaceID:)`.
    let onSignOut: () -> Void
    /// Re-pair callback — opens the QR scanner sheet (lives on the
    /// container view since it owns the camera presentation flow). On
    /// a successful scan the container view routes the QR text into
    /// `AppCoordinator.repairCurrentDevice(qrText:)`.
    let onRepair: () -> Void
    let onDismiss: () -> Void

    @State private var deviceID: String?
    /// Recomputed every minute via TimelineView so the countdown chip
    /// and the long description stay current while the sheet is up.
    @State private var statusTick = Date()

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                workspaceSection
                pairingSection
                deviceSection
                appSection
                signOutSection
            }
            .scrollContentBackground(.hidden)
            .background(BrandColors.surfaceSecondary)
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { onDismiss() }
                        .tint(BrandColors.accentPrimary)
                }
            }
        }
        .task { await loadDeviceID() }
        .task(id: statusTick) {
            // Refresh the pairing countdown every 30 seconds so the
            // "Expires in N hours/minutes" text doesn't go stale while
            // the user lingers on the sheet. `task(id:)` cancels +
            // restarts when `statusTick` changes, so the loop body is
            // a single sleep + bump.
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            statusTick = Date()
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            row(label: "Username", value: context.user.userName)
            if context.user.displayName != context.user.userName {
                row(label: "Display name", value: context.user.displayName)
            }
            if let email = context.user.email, !email.isEmpty {
                row(label: "Email", value: email)
            }
        } header: {
            sectionHeader("Account")
        }
    }

    private var workspaceSection: some View {
        Section {
            row(label: "Name", value: context.workspace.workspaceName)
            row(
                label: "Host",
                value: context.workspace.workspaceURL.host ?? "—",
                monospaced: true
            )
            row(label: "Cloud", value: context.workspace.cloud.rawValue.uppercased())
            if let region = context.workspace.region, !region.isEmpty {
                row(label: "Region", value: region)
            }
            row(label: "Signed in", value: dateFormatter.string(from: context.workspace.signedInAt))
        } header: {
            sectionHeader("Workspace")
        }
    }

    private var deviceSection: some View {
        Section {
            row(label: "Device ID", value: deviceID ?? "—", monospaced: true)
            row(label: "Paired session", value: pairedSessionSummary, monospaced: true)
        } header: {
            sectionHeader("Device")
        }
    }

    private var pairingSection: some View {
        let status = PairingStatus(expiresAt: sessionExpiresAt, now: statusTick)
        return Section {
            HStack(alignment: .firstTextBaseline) {
                Text(status.longDescription)
                    .font(BrandTypography.body)
                    .foregroundStyle(BrandColors.textPrimary)
                    .multilineTextAlignment(.leading)
                Spacer()
                PairingStatusChip(level: status.level, label: status.shortDescription)
            }
            Button {
                onRepair()
            } label: {
                HStack {
                    Image(systemName: "qrcode.viewfinder")
                    Text(rescanButtonTitle(for: status.level))
                }
                .font(BrandTypography.bodyEmphasis)
                .foregroundStyle(BrandColors.accentPrimary)
            }
        } header: {
            sectionHeader("Pairing")
        } footer: {
            Text("Re-scan the QR code shown in the lakeLoom Databricks App to refresh this device's paired session. Existing recordings and project data stay where they are.")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    private func rescanButtonTitle(for level: PairingStatus.WarningLevel) -> String {
        switch level {
        case .healthy, .soft:
            return "Re-scan QR code"
        case .warning:
            return "Re-scan QR code now"
        case .urgent:
            return "Re-scan QR code — required"
        }
    }

    private var appSection: some View {
        Section {
            row(label: "Version", value: appVersionString)
            row(label: "Build", value: appBuildString)
        } header: {
            sectionHeader("App")
        }
    }

    private var signOutSection: some View {
        Section {
            Button(role: .destructive) {
                onSignOut()
            } label: {
                HStack {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                    Text("Sign out of this workspace")
                }
                .font(BrandTypography.bodyEmphasis)
                .foregroundStyle(BrandColors.statusError)
            }
        } footer: {
            Text("Signing out removes the paired session and returns to QR pairing. Recordings already on this device finish uploading before they're cleared.")
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
        }
    }

    // MARK: - Row helpers

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(BrandTypography.caption)
            .foregroundStyle(BrandColors.textSecondary)
    }

    private func row(label: String, value: String, monospaced: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(BrandTypography.caption)
                .foregroundStyle(BrandColors.textSecondary)
            Spacer()
            Text(value)
                .font(monospaced ? BrandTypography.caption.monospaced() : BrandTypography.body)
                .foregroundStyle(BrandColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    // MARK: - Derived

    private var pairedSessionSummary: String {
        switch context.workspace.authMethod {
        case .qrPaired(let pairedSessionID, _):
            return shortID(pairedSessionID)
        }
    }

    private var sessionExpiresAt: Date {
        switch context.workspace.authMethod {
        case .qrPaired(_, let expiresAt):
            return expiresAt
        }
    }

    private func shortID(_ id: String) -> String {
        let head = id.prefix(8)
        return head.count == id.count ? String(head) : "\(head)…"
    }

    private var dateFormatter: DateFormatter {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }

    private var appVersionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    private var appBuildString: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    }

    // MARK: - Device ID lazy load

    private func loadDeviceID() async {
        guard let store = deviceIdentity else { return }
        if let id = try? await store.deviceID() {
            deviceID = id
        }
    }
}

/// Compact pill that mirrors `PairingStatus.shortDescription` and
/// colors it by `WarningLevel`. Used inline in the Pairing section
/// and (in the same shape) on the home toolbar so the visual language
/// is consistent across surfaces.
struct PairingStatusChip: View {
    let level: PairingStatus.WarningLevel
    let label: String

    var body: some View {
        Text(label)
            .font(BrandTypography.caption.weight(.medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
            .overlay(
                Capsule().stroke(foreground.opacity(0.25), lineWidth: 0.5)
            )
            .accessibilityLabel("Pairing status: \(label)")
    }

    private var foreground: Color {
        switch level {
        case .healthy: return BrandColors.statusSuccess
        case .soft:    return BrandColors.statusInfo
        case .warning: return BrandColors.statusWarning
        case .urgent:  return BrandColors.statusError
        }
    }

    private var background: Color {
        switch level {
        case .healthy: return BrandColors.statusSuccess.opacity(0.12)
        case .soft:    return BrandColors.statusInfo.opacity(0.12)
        case .warning: return BrandColors.statusWarning.opacity(0.15)
        case .urgent:  return BrandColors.statusError.opacity(0.15)
        }
    }
}
