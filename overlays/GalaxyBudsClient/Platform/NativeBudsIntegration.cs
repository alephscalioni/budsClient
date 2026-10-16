using System;
using System.Linq;
using System.IO;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Avalonia.Threading;

namespace GalaxyBudsClient.Platform;

/// <summary>Native windows run inside the Buds process, sharing its Dock icon and lifecycle.</summary>
internal static class NativeBudsIntegration
{
    private static readonly SemaphoreSlim ActionGate = new(1, 1);
    private static bool _ownsSmep;
    private static bool _shuttingDown;
    private static int _startGeneration;
    private static DispatcherTimer? _leaseMonitor;
    private static DispatcherTimer? _maintenance;
    private static readonly NativeBudsReadSchedule SettingsReads = new();
    private static bool _maintaining;

    internal static void StartNativeMaintenance()
    {
        if (_maintenance != null) return;
        var startupGeneration = Volatile.Read(ref _startGeneration);
        var startupPending = true;
        var avatarRevision = -1;
        _maintenance = new DispatcherTimer(TimeSpan.FromMilliseconds(600), DispatcherPriority.Background, async (_, _) =>
        {
            if (_shuttingDown) { _maintenance?.Stop(); return; }
            if (_maintaining) return;
            _maintaining = true;
            try
            {
                using var state = ReadState(avatarRevision);
                var root = state.RootElement;
                if (root.GetProperty("account").TryGetProperty("avatar_revision", out var revision) && revision.TryGetInt32(out var currentRevision)) avatarRevision = currentRevision;
                var switching = root.GetProperty("switching");
                static bool Flag(JsonElement o, string key) => o.TryGetProperty(key, out var v) && v.ValueKind == JsonValueKind.True;
                if (startupPending)
                {
                    if (startupGeneration != Volatile.Read(ref _startGeneration) ||
                        (root.TryGetProperty("preferences", out var preferences) && !Flag(preferences, "auto_switch_enabled"))) startupPending = false;
                    else if (Flag(switching, "ready") && Flag(root.GetProperty("account"), "cloud_enrolled"))
                    {
                        startupPending = false;
                        await PerformAsync(new { action = "switch.start" });
                    }
                }
#if DEBUG
                // Controlled A/B for vendor-channel coexistence; no account,
                // handoff or audio decision changes. Never compiled in Release.
                if (Environment.GetEnvironmentVariable("BUDS_VERIFY_DISABLE_SETTINGS_READS") == "1") return;
#endif
                var mac = switching.TryGetProperty("route", out var route) && route.GetString() == "Mac" && Flag(switching, "native_channel_open");
                var selected = switching.GetProperty("selected_buds").GetString();
                var epoch = switching.TryGetProperty("settings_epoch", out var ownership) && ownership.ValueKind == JsonValueKind.String ? ownership.GetString() : null;
                var device = root.GetProperty("device");
                var metadata = root.GetProperty("device_metadata");
                var linked = Flag(metadata, "bluetooth_connected");
                var presentation = root.GetProperty("presentation");
                var panelOpen = Flag(presentation, "panel_open");
                var panelEpoch = presentation.TryGetProperty("panel_epoch", out var visibleEpoch) && visibleEpoch.ValueKind == JsonValueKind.String ? visibleEpoch.GetString() : null;
                if (!mac && linked && metadata.TryGetProperty("connection_epoch", out var linkEpoch) && linkEpoch.ValueKind == JsonValueKind.String) epoch = "link/" + linkEpoch.GetString();
                var eligible = panelOpen && linked && !Flag(switching, "busy") && !Flag(switching, "settling") && Flag(device, "can_refresh");
                var scope = panelOpen && !string.IsNullOrEmpty(panelEpoch) && linked && !string.IsNullOrEmpty(selected) && !string.IsNullOrEmpty(epoch) ? selected + "/" + epoch + "/view/" + panelEpoch : null;
                var readFresh = Flag(device, "can_control") && Flag(device, "read_fresh");
                var observationRevision = device.TryGetProperty("observation_revision", out var observedRevision) && observedRevision.TryGetUInt64(out var parsedRevision) ? parsedRevision : 0;
                if (SettingsReads.ShouldRead(scope, eligible, Flag(device, "busy"), readFresh,
                    Stopwatch.GetTimestamp() / (double)Stopwatch.Frequency, observationRevision))
                {
                    await PerformAsync(new { action = "device.refresh" });
                }
            }
            catch (Exception ex) when (ex is JsonException or InvalidOperationException or IOException) { }
            finally { _maintaining = false; }
        });
        _maintenance.Start();
    }
    public static bool IsAvailable => OperatingSystem.IsMacOS() && File.Exists(Path.Combine(AppContext.BaseDirectory, "libBudsNative.dylib"));
    // Temporary isolation requested by the user. Restore legacy features one by one.
    public static bool NativeOnlyMode => IsAvailable;
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_open_account")]
    private static extern void OpenAccountNative();
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_open_switch_settings")]
    private static extern void OpenSwitchNative([MarshalAs(UnmanagedType.LPUTF8Str)] string address, [MarshalAs(UnmanagedType.LPUTF8Str)] string name);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_show_connected")]
    private static extern void ShowConnectedNative([MarshalAs(UnmanagedType.LPUTF8Str)] string address, [MarshalAs(UnmanagedType.LPUTF8Str)] string name, int galaxy);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_native_shutdown")]
    private static extern void ShutdownNative();
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_copy_state")]
    private static extern IntPtr CopyStateNative(int avatarRevision);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_free_state")]
    private static extern void FreeStateNative(IntPtr value);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_perform_action")]
    private static extern void PerformActionNative([MarshalAs(UnmanagedType.LPUTF8Str)] string request);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_switch_is_active")]
    private static extern int SwitchIsActiveNative();
    public static JsonDocument ReadState(int avatarRevision)
    {
        var pointer = CopyStateNative(avatarRevision);
        try
        {
            var document = JsonDocument.Parse(Marshal.PtrToStringUTF8(pointer) ?? "{}");
            if (document.RootElement.TryGetProperty("switching", out var state)) PublishDiagnostic(state);
            return document;
        }
        finally { if (pointer != IntPtr.Zero) FreeStateNative(pointer); }
    }
    // The existing local CLI receives only audio-controller status. Account
    // identity, profile image, tokens and paired device identifiers stay private.
    public static string PublicSwitchStatus()
    {
        if (!IsAvailable) return "{\"available\":false}";
        using var document = ReadState(int.MaxValue);
        return Sanitize(document.RootElement.GetProperty("switching"));
    }
    public static string PublicDeviceStatus()
    {
        if (!IsAvailable) return "{\"available\":false}";
        using var document = ReadState(int.MaxValue);
        var safe = new System.Collections.Generic.Dictionary<string, JsonElement>();
        if (document.RootElement.TryGetProperty("device", out var device))
            foreach (var key in new[] { "available", "busy", "connected", "can_refresh", "can_control", "can_touch", "model_verified", "observed_at", "read_fresh", "observation_revision", "last_observation", "noise_mode", "noise_modes", "levels", "equalizer", "equalizer_raw", "equalizer_enabled", "equalizer_custom", "custom_eq_bands", "custom_eq_observed_at", "can_custom_eq_read", "can_custom_eq_write", "firmware_version", "firmware_observed_at", "can_info", "ambient_level", "touch_enabled", "media_controls_enabled", "media_controls_mixed", "touch_controls", "tools", "settings", "status", "error", "transport_diagnostics" })
                if (device.TryGetProperty(key, out var value)) safe[key] = value;
        if (document.RootElement.TryGetProperty("switching", out var switching) && switching.TryGetProperty("battery", out var battery))
            safe["battery"] = battery;
        if (document.RootElement.TryGetProperty("device_metadata", out var metadata))
            foreach (var key in new[] { "model", "bluetooth_connected", "audio_endpoint_present", "existing_mac_settings_route", "native_settings_implemented", "handoff_validated" })
                if (metadata.TryGetProperty(key, out var value)) safe[key] = value;
        if (document.RootElement.TryGetProperty("volume", out var volume))
            safe["volume"] = volume;
        return JsonSerializer.Serialize(safe);
    }

    public static string PublicAccountContinuityStatus()
    {
        if (!IsAvailable) return "{\"available\":false}";
        using var document = ReadState(int.MaxValue);
        var safe = new System.Collections.Generic.Dictionary<string, JsonElement>();
        if (document.RootElement.TryGetProperty("account", out var state))
            foreach (var key in new[] { "connected", "can_prepare_certificate", "account_authenticated", "cloud_identity_registered", "certificate_keychain_ready", "peer_roster_contains_this_device", "peer_authenticated", "certificate_blocker", "certificate_http_status", "certificate_stage", "certificate_service_code", "continuity_identity_mode", "continuity_outgoing_only", "continuity_incoming_ble_discovery_available", "continuity_keychain_backend", "continuity_keychain_operation", "continuity_keychain_osstatus", "continuity_keychain_acl_reason", "continuity_keychain_acl_purpose", "continuity_keychain_acl_wildcard", "continuity_keychain_acl_current_app_match_evaluated", "continuity_keychain_acl_current_app_match", "continuity_keychain_acl_count", "continuity_keychain_acl_index", "continuity_keychain_acl_authorization_count", "continuity_keychain_acl_public_count", "continuity_keychain_acl_metadata_count", "continuity_keychain_acl_sensitive_count", "continuity_keychain_acl_unknown_count", "continuity_keychain_acl_any_count", "continuity_keychain_acl_sign_count", "continuity_keychain_acl_decrypt_count", "continuity_keychain_acl_read_count", "continuity_keychain_acl_export_count", "continuity_keychain_acl_change_count", "continuity_keychain_acl_application_count", "continuity_keychain_key_rsa", "continuity_keychain_key_private", "continuity_keychain_key_size_2048", "continuity_keychain_key_extractable_false", "continuity_keychain_key_extraction_attribute_present", "continuity_keychain_key_contradictory_runtime_report", "certificate_schema" })
                if (state.TryGetProperty(key, out var value)) safe[key] = value;
        return JsonSerializer.Serialize(safe);
    }

    public static string PublicContinuityPhones()
    {
        if (!IsAvailable) return "[]";
        using var document = ReadState(int.MaxValue);
        var state = document.RootElement.GetProperty("switching");
        var selected = state.TryGetProperty("selected_phone", out var choice) ? choice.GetString() : "";
        var phones = new System.Collections.Generic.List<object>();
        if (state.TryGetProperty("phones", out var values))
            foreach (var phone in values.EnumerateArray())
                phones.Add(new { name = phone.GetProperty("name").GetString(), selected = phone.GetProperty("id").GetString() == selected });
        return JsonSerializer.Serialize(phones);
    }

    public static async Task ConnectRegisteredPhoneAsync(string name)
    {
        using var document = ReadState(int.MaxValue);
        var state = document.RootElement.GetProperty("switching");
        var matches = state.GetProperty("phones").EnumerateArray()
            .Where(phone => phone.GetProperty("name").GetString() == name).ToArray();
        if (matches.Length != 1) throw new ArgumentException("A uniquely named registered phone is required.");
        var id = matches[0].GetProperty("id").GetString();
        if (state.GetProperty("selected_phone").GetString() != id &&
            new[] { "enabled", "busy", "settling", "recovery_pending" }.Any(key =>
                state.TryGetProperty(key, out var active) && active.GetBoolean()))
            throw new InvalidOperationException("Pause switching before selecting another phone.");
        if (state.GetProperty("selected_phone").GetString() != id)
            await PerformAsync(new { action = "switch.configure", phone = id });
        await PerformAsync(new { action = "account.peer_connect" });
    }

    private static string Sanitize(JsonElement state)
    {
        var safe = new System.Collections.Generic.Dictionary<string, JsonElement>();
        foreach (var key in new[] { "transport", "build_id", "configuration", "starting", "enabled", "busy", "settling", "ready", "status", "error", "route", "mac_activity", "phone_activity", "protocol_status_updates", "native_channel_open", "transport_diagnostics", "multipoint_state", "stream_flags", "recovery_pending" })
            if (state.TryGetProperty(key, out var value)) safe[key] = value;
        return JsonSerializer.Serialize(safe);
    }
    private static DateTime _nextDiagnostic;
    private static void PublishDiagnostic(JsonElement state)
    {
        if (!OperatingSystem.IsMacOS() || DateTime.UtcNow < _nextDiagnostic) return;
        _nextDiagnostic = DateTime.UtcNow.AddSeconds(1);
        try
        {
            var directory = Path.Combine(System.Environment.GetFolderPath(System.Environment.SpecialFolder.UserProfile), "Library", "Application Support", "BudsAutoSwitch", "Diagnostics");
            Directory.CreateDirectory(directory);
            var path = Path.Combine(directory, "native-switch-state.json");
            var temporary = path + ".tmp";
            File.WriteAllText(temporary, Sanitize(state));
            File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
            File.Move(temporary, path, true);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    public static async Task PerformAsync(object request)
    {
        var json = JsonSerializer.Serialize(request);
        using var document = JsonDocument.Parse(json);
        var action = document.RootElement.GetProperty("action").GetString();
        if (action == "switch.stop") Interlocked.Increment(ref _startGeneration);
        if (action != "switch.start") { PerformActionNative(json); return; }
        var generation = Interlocked.Increment(ref _startGeneration);
        await ActionGate.WaitAsync();
        try
        {
            // A completed stop can precede the lease monitor by one tick.
            // Reconcile that already-inactive reservation before a user restart.
            if (_ownsSmep && SwitchIsActiveNative() == 0) ReleaseSmep();
            if (_ownsSmep || _shuttingDown || generation != Volatile.Read(ref _startGeneration)) return;
            PerformActionNative("{\"action\":\"switch.preparing\"}");
            // Preparing cancels the settings transaction. Its SDK child must
            // actually exit before start() checks the shared operation drain.
            var settled = await NativeBudsStartDrain.WaitAsync(() =>
            {
                using var state = ReadState(int.MaxValue);
                // Native actions are queued even when the caller is on Main.
                // An old zero cannot precede switch.preparing being applied.
                var applied = state.RootElement.TryGetProperty("switching", out var switching) &&
                              switching.TryGetProperty("starting", out var starting) && starting.ValueKind == JsonValueKind.True;
                int? operations = state.RootElement.TryGetProperty("device", out var device) &&
                       device.TryGetProperty("transport_diagnostics", out var diagnostics) &&
                       diagnostics.TryGetProperty("pending_operations", out var pending) && pending.TryGetInt32(out var count)
                    ? count : null;
                return (applied, operations);
            }, () => _shuttingDown || generation != Volatile.Read(ref _startGeneration), () => Task.Delay(50));
            if (_shuttingDown || generation != Volatile.Read(ref _startGeneration))
            {
                PerformActionNative("{\"action\":\"switch.cancelled\"}");
                return;
            }
            if (!settled)
            {
                PerformActionNative("{\"action\":\"switch.failure\",\"error\":\"O Bluetooth ainda está encerrando a operação anterior. Tente ativar novamente quando concluir.\"}");
                return;
            }
            if (!await MultipointPatcher.BeginNativeSwitchAsync())
            {
                PerformActionNative("{\"action\":\"switch.failure\",\"error\":\"Outro recurso está usando a conexão dos Buds. Termine essa operação e tente novamente.\"}");
                return;
            }
            _ownsSmep = true;
            if (_shuttingDown || generation != Volatile.Read(ref _startGeneration))
            {
                ReleaseSmep();
                PerformActionNative("{\"action\":\"switch.cancelled\"}");
                return;
            }
            PerformActionNative("{\"action\":\"switch.start\",\"transport_granted\":true}");
            _leaseMonitor ??= new DispatcherTimer(TimeSpan.FromMilliseconds(600), DispatcherPriority.Background, (_, _) =>
            {
                if (_ownsSmep && SwitchIsActiveNative() == 0) ReleaseSmep();
            });
            _leaseMonitor.Start();
        }
        catch
        {
            ReleaseSmep();
            throw;
        }
        finally { ActionGate.Release(); }
    }
    private static void ReleaseSmep()
    {
        _leaseMonitor?.Stop();
        if (!_ownsSmep) return;
        _ownsSmep = false;
        MultipointPatcher.EndNativeSwitch();
    }
    public static async Task ShutdownAsync()
    {
        if (!IsAvailable) return;
        _shuttingDown = true;
        _maintenance?.Stop();
        Interlocked.Increment(ref _startGeneration);
        ShutdownNative();
        // Give the native stop task time to restore mute and close its channel.
        for (var attempt = 0; attempt < 200; attempt++)
        {
            await Task.Delay(100);
            if (SwitchIsActiveNative() == 0) { ReleaseSmep(); return; }
        }
        // The existing guard worker also restores the saved mute state on process exit.
    }
    public static void OpenAccount() { if (!IsAvailable) throw new InvalidOperationException("A integração Samsung Account não está incluída nesta versão do Buds."); OpenAccountNative(); }
    public static void OpenSwitch(string? address, string? name) { OpenSwitchNative(address ?? "", name ?? "Galaxy Buds"); }
    public static void ShowConnected(string address, string name) { if (IsAvailable) ShowConnectedNative(address, name, 0); }
    public static void Shutdown() { if (IsAvailable) ShutdownNative(); }
}
