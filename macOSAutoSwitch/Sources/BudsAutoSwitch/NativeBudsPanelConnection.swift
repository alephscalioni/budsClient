/// A settings/call lockout is not a physical disconnection. This presentation
/// gate grants no settings, volume, transport, or automatic-switch permission.
enum NativeBudsPanelConnection {
    static func connected(readFailed: Bool, physicalLink: Bool?, audioPresent: Bool?,
                          deviceState: Bool, existingSettingsRoute: Bool) -> Bool {
        guard !readFailed, physicalLink != false else { return false }
        // macOS can retain idle HAL endpoints after link loss. A route alone
        // must not promote an unknown physical link to a current connection.
        return deviceState || (physicalLink == true && (audioPresent == true || existingSettingsRoute))
    }
}
