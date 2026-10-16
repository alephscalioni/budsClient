using System;
using System.IO;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Automation;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Interactivity;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using GalaxyBudsClient.Platform;

namespace GalaxyBudsClient.Interface.Controls;

/// <summary>Native state drives this panel; artwork and cloud identity never imply a device connection.</summary>
public partial class BudsIntegrationPanel : UserControl
{
    private readonly DispatcherTimer _timer;
    private bool _rendering = true;
    private bool _lastIdentity;
    private bool _canControl, _canRefreshDevice;
    private string _lastError = "";
    private string? _actionFailure;
    private string _noiseMode = "";
    private bool? _touchEnabled;
    private int? _equalizerPreset;
    private int _avatarRevision = -1;
    private Bitmap? _avatar;
    private Choice[] _buds = [], _phones = [];
    private static readonly Preset[] Presets =
    [
        new(0, "Normal"), new(1, "Graves"), new(2, "Suave"),
        new(3, "Dinâmico"), new(4, "Nítido"), new(5, "Agudos")
    ];
    private sealed record Choice(string Id, string Name) { public override string ToString() => Name; }
    private sealed record Preset(int Id, string Name) { public override string ToString() => Name; }

    public BudsIntegrationPanel()
    {
        InitializeComponent();
        Equalizer.ItemsSource = Presets;
        _rendering = false;
        IsVisible = NativeBudsIntegration.IsAvailable;
        _timer = new DispatcherTimer(TimeSpan.FromMilliseconds(600), DispatcherPriority.Background, (_, _) => RefreshState());
        _timer.Stop();
        AttachedToVisualTree += (_, _) => { if (IsVisible) { RefreshState(); _timer.Start(); } };
        DetachedFromVisualTree += (_, _) => _timer.Stop();
    }

    public void ExpandSwitching() => SwitchExpander.IsExpanded = true;

    private void RefreshState()
    {
        if (!NativeBudsIntegration.IsAvailable) return;
        _rendering = true;
        try
        {
            using var document = NativeBudsIntegration.ReadState(_avatarRevision);
            var root = document.RootElement;
            var account = Property(root, "account");
            var connected = Flag(account, "connected");
            AccountName.Text = Fallback(Text(account, "name"), "Samsung Account");
            AccountSummary.Text = connected ? "Conta conectada · registros na nuvem" : "Entre para consultar seus registros";
            AccountStatus.Text = Text(account, "status");
            Initials.Text = Fallback(Text(account, "initials"), "SA");
            UpdateAvatar(account);
            SignIn.Content = connected ? "Entrar novamente" : "Entrar na conta";
            SignIn.IsEnabled = Flag(account, "can_sign_in");
            Sync.IsEnabled = Flag(account, "can_sync");
            CheckContinuity.IsEnabled = Flag(account, "can_prepare_certificate");
            Cancel.IsVisible = Flag(account, "can_cancel");
            var needsIdentity = Flag(account, "needs_identity");
            IdentityPanel.IsVisible = needsIdentity;
            ConfirmIdentity.IsEnabled = Flag(account, "can_confirm_identity");
            if (needsIdentity)
            {
                AccountSummary.Text = "Confirme sua identidade para concluir";
                AccountExpander.IsExpanded = true;
                if (!_lastIdentity) Dispatcher.UIThread.Post(() => Identity.Focus());
            }
            else if (Flag(account, "can_cancel")) AccountSummary.Text = "Autorização em andamento…";
            if (_lastIdentity && !needsIdentity) Identity.Text = "";
            _lastIdentity = needsIdentity;

            var switching = Property(root, "switching");
            var hasSwitchState = switching.ValueKind == JsonValueKind.Object;
            var enabled = Flag(switching, "enabled");
            var busy = Flag(switching, "busy");
            var starting = Flag(switching, "starting");
            var recoveryPending = Flag(switching, "recovery_pending");
            var settling = Flag(switching, "settling");
            Enabled.IsChecked = enabled || starting;
            Enabled.IsEnabled = enabled || starting || (!busy && !recoveryPending && !settling && Flag(switching, "ready"));
            Stop.IsVisible = enabled || starting;
            Stop.Content = busy || starting ? "Cancelar conexão" : "Pausar alternância";
            Refresh.IsEnabled = hasSwitchState && !enabled && !starting && !busy && !recoveryPending && !settling;
            Refresh.Content = busy ? "Verificando…" : "Verificar dispositivos";
            Buds.IsEnabled = Phone.IsEnabled = hasSwitchState && !enabled && !starting && !busy && !recoveryPending && !settling;
            UpdateChoices(Buds, ref _buds, Property(switching, "buds"), Text(switching, "selected_buds"));
            UpdateChoices(Phone, ref _phones, Property(switching, "phones"), Text(switching, "selected_phone"));
            PhoneLabel.IsVisible = Phone.IsVisible = _phones.Length > 0;
            SwitchError.Text = Text(switching, "error");
            SwitchError.IsVisible = !string.IsNullOrWhiteSpace(SwitchError.Text);
            RecoveryPanel.IsVisible = recoveryPending;
            SwitchSummary.Text = recoveryPending ? "Restaurando o som automaticamente…" : settling ? "Concluindo cancelamento…" : starting ? "Preparando conexão…" : enabled && busy ? "Conectando…" : enabled ? (SwitchError.IsVisible ? "Ativada · com aviso" : "Ativada · Bluetooth nativo") : busy ? "Restaurando o som…" : SwitchError.IsVisible ? "Interrompida · verifique a conexão" : switching.ValueKind != JsonValueKind.Object ? "Estado indisponível" : "Desativada";
            if (SwitchError.IsVisible && _lastError != SwitchError.Text) SwitchExpander.IsExpanded = true;
            _lastError = SwitchError.Text ?? "";
            DeviceName.Text = Fallback(Text(switching, "device_name"), "Galaxy Buds");
            RenderBattery(Property(switching, "battery"));
            RenderDevice(Property(root, "device"));
            if (_actionFailure == null) BridgeError.IsVisible = false;
        }
        catch (Exception ex) when (ex is JsonException or KeyNotFoundException or InvalidOperationException or DllNotFoundException or EntryPointNotFoundException or FormatException or ArgumentException or IOException or NotSupportedException)
        {
            if (_actionFailure == null)
            {
                BridgeError.Text = "Não foi possível atualizar a integração. Tentando novamente…";
                BridgeError.IsVisible = true;
            }
            SignIn.IsEnabled = Sync.IsEnabled = CheckContinuity.IsEnabled = ConfirmIdentity.IsEnabled = Enabled.IsEnabled = Refresh.IsEnabled = false;
            Buds.IsEnabled = Phone.IsEnabled = false;
            RenderDevice(default);
            RenderBattery(default);
            ConnectionSummary.Text = "Estado indisponível";
            // Preserve visible cancel/recovery actions. A transient read failure must
            // not stop polling or strand an in-progress authorization/switch.
        }
        finally { _rendering = false; }
    }

    private void UpdateAvatar(JsonElement account)
    {
        if (account.ValueKind != JsonValueKind.Object || !account.TryGetProperty("avatar", out var picture)) return; // Omitted when its revision is unchanged.
        Bitmap? next = null;
        try
        {
            var encoded = picture.ValueKind == JsonValueKind.String ? picture.GetString() : null;
            if (!string.IsNullOrEmpty(encoded))
            {
                using var stream = new MemoryStream(Convert.FromBase64String(encoded));
                next = Bitmap.DecodeToWidth(stream, 96);
            }
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException or IOException or NotSupportedException)
        {
            // An unavailable profile image must not disable account or device actions.
        }
        Avatar.Source = next;
        _avatar?.Dispose(); _avatar = next;
        Avatar.IsVisible = next != null;
        Initials.IsVisible = next == null;
        _avatarRevision = Integer(account, "avatar_revision") ?? -1;
    }

    private void RenderBattery(JsonElement battery)
    {
        var left = Percentage(battery, "left");
        var right = Percentage(battery, "right");
        var chargingCase = Percentage(battery, "case");
        SetBattery(LeftBattery, left, "fone esquerdo");
        SetBattery(RightBattery, right, "fone direito");
        SetBattery(CaseBattery, chargingCase, "estojo");
        var hasReading = left.HasValue || right.HasValue || chargingCase.HasValue;
        var observed = Observation(Property(battery, "observed_at"));
        var stamp = observed?.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
        var old = observed.HasValue && DateTimeOffset.UtcNow - observed.Value > TimeSpan.FromMinutes(5);
        BatteryObservation.Text = !hasReading ? "Sem leitura de bateria" : observed.HasValue
            ? $"{(old ? "Última leitura" : "Bateria lida em")} · {stamp}"
            : "Horário da leitura indisponível";
        ToolTip.SetTip(BatteryObservation, !hasReading ? "A integração ainda não informou a carga dos Buds e do estojo." : old
            ? "Leitura com mais de 5 minutos; a carga atual pode ter mudado."
            : "Cada percentual é a última leitura recebida. Um traço indica bateria sem leitura.");
    }

    private static void SetBattery(TextBlock label, int? percentage, string part)
    {
        label.Text = percentage.HasValue ? $"{percentage}%" : "—";
        AutomationProperties.SetName(label, percentage.HasValue ? $"Bateria do {part}: {percentage}%" : $"Bateria do {part} desconhecida");
    }

    private void RenderDevice(JsonElement device)
    {
        var present = device.ValueKind == JsonValueKind.Object;
        var availability = Boolean(device, "available");
        var busyState = Boolean(device, "busy");
        var busy = busyState == true;
        var connected = Boolean(device, "connected");
        _canRefreshDevice = availability == true && busyState == false && (Boolean(device, "can_refresh") ?? Flag(device, "can_control"));
        _canControl = _canRefreshDevice && connected == true && Flag(device, "can_control");
        NoiseControls.IsEnabled = Equalizer.IsEnabled = _canControl;
        Touch.IsEnabled = _canControl && (Boolean(device, "can_touch") ?? true);
        DeviceRefresh.IsEnabled = _canRefreshDevice;
        ConnectionSummary.Text = !present ? "Aguardando estado dos Buds" : availability == false ? "Integração do dispositivo indisponível"
            : connected == true ? (busy ? "Conectados · atualizando…" : "Conectados ao Mac")
            : connected == false ? "Buds desconectados" : "Conexão sem leitura";
        var status = Text(device, "status");
        DeviceStatus.Text = Fallback(status, !present ? "Aguardando disponibilidade dos controles."
            : availability == false ? "Controles indisponíveis nesta conexão."
            : !availability.HasValue || !busyState.HasValue ? "Aguardando disponibilidade dos controles."
            : busy ? "Atualizando estado dos Buds…"
            : connected != true ? "Conecte os Buds ao Mac para usar os controles."
            : !_canControl ? "A integração ainda não liberou os controles." : "Controles disponíveis pelo Bluetooth.");
        DeviceError.Text = Text(device, "error");
        DeviceError.IsVisible = !string.IsNullOrWhiteSpace(DeviceError.Text);
        _noiseMode = Text(device, "noise_mode");
        NoiseOff.IsChecked = _noiseMode == "off";
        NoiseAnc.IsChecked = _noiseMode == "anc";
        NoiseAmbient.IsChecked = _noiseMode == "ambient";
        NoiseAdaptive.IsChecked = _noiseMode == "adaptive";
        NoiseSummary.Text = _noiseMode switch { "off" => "Desligado", "anc" => "Cancelamento", "ambient" => "Som ambiente", "adaptive" => "Adaptável", _ => "Sem leitura" };
        _equalizerPreset = Integer(device, "equalizer");
        Equalizer.SelectedItem = Presets.FirstOrDefault(p => p.Id == _equalizerPreset);
        _touchEnabled = Boolean(device, "touch_enabled");
        Touch.IsChecked = _touchEnabled == true;
        TouchSummary.Text = _touchEnabled switch { true => "Ativados", false => "Desativados", _ => "Sem leitura" };
        var level = Integer(device, "ambient_level");
        AmbientLevel.Text = level is >= 0 ? $"Nível {level}" : "—";
        AutomationProperties.SetName(AmbientLevel, level is >= 0 ? $"Nível de som ambiente: {level}" : "Nível de som ambiente desconhecido");
    }

    private static JsonElement Property(JsonElement value, string key)
        => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(key, out var item) ? item : default;
    private static string Text(JsonElement value, string key)
        => Property(value, key) is var item && item.ValueKind == JsonValueKind.String ? item.GetString() ?? "" : "";
    private static bool? Boolean(JsonElement value, string key)
        => Property(value, key).ValueKind switch { JsonValueKind.True => true, JsonValueKind.False => false, _ => null };
    private static bool Flag(JsonElement value, string key) => Boolean(value, key) == true;
    private static int? Integer(JsonElement value, string key)
        => Property(value, key) is var item && item.ValueKind == JsonValueKind.Number && item.TryGetInt32(out var number) ? number : null;
    private static int? Percentage(JsonElement value, string key)
    {
        var number = Integer(value, key);
        return number is >= 0 and <= 100 ? number : null;
    }
    private static string Fallback(string value, string fallback) => string.IsNullOrWhiteSpace(value) ? fallback : value;
    private static DateTimeOffset? Observation(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.String && DateTimeOffset.TryParse(value.GetString(), CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var date)) return date;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var seconds) && seconds is >= -62135596800 and <= 253402300799)
            return DateTimeOffset.FromUnixTimeSeconds(seconds);
        return null;
    }
    private static void UpdateChoices(ComboBox combo, ref Choice[] current, JsonElement list, string selected)
    {
        Choice[] choices = list.ValueKind == JsonValueKind.Array
            ? list.EnumerateArray().Where(item => !string.IsNullOrWhiteSpace(Text(item, "id")))
                .Select(item => new Choice(Text(item, "id"), Fallback(Text(item, "name"), "Dispositivo sem nome"))).ToArray()
            : [];
        if (!current.SequenceEqual(choices)) { current = choices; combo.ItemsSource = current; }
        combo.SelectedItem = current.FirstOrDefault(item => item.Id == selected);
    }
    private async void Perform(object request)
    {
        if (_rendering || !NativeBudsIntegration.IsAvailable) return;
        ClearActionFailure();
        try { await NativeBudsIntegration.PerformAsync(request); }
        catch (Exception ex) when (ex is DllNotFoundException or EntryPointNotFoundException or InvalidOperationException or IOException)
        { ShowActionFailure("A ação não foi concluída. Verifique o estado da integração e tente novamente."); }
    }
    private void ShowActionFailure(string message)
    {
        _actionFailure = message;
        BridgeError.Text = message;
        BridgeError.IsVisible = true;
        Dispatcher.UIThread.Post(() => { BridgeError.BringIntoView(); BridgeError.Focus(); });
    }
    private void ClearActionFailure()
    {
        _actionFailure = null;
        BridgeError.IsVisible = false;
    }
#if DEBUG
    // Presentation-only fixture: no bridge actions, account changes or devices.
    internal async Task<bool> VerifyPersistentActionFailureAsync()
    {
        var previous = _actionFailure;
        var text = BridgeError.Text;
        var visible = BridgeError.IsVisible;
        const string fixture = "Verificação de interface: ação não concluída.";
        try
        {
            ShowActionFailure(fixture);
            await Task.Delay(1500); // Several successful state polls must retain it.
            var retained = BridgeError.IsVisible && BridgeError.Text == fixture;
            ClearActionFailure();
            return retained && !BridgeError.IsVisible;
        }
        finally
        {
            _actionFailure = previous;
            BridgeError.Text = text;
            BridgeError.IsVisible = visible;
        }
    }
#endif
    private void OnSignIn(object? sender, RoutedEventArgs e) => Perform(new { action = "account.sign_in" });
    private void OnCancel(object? sender, RoutedEventArgs e) => Perform(new { action = "account.cancel" });
    private void OnCheckContinuity(object? sender, RoutedEventArgs e) => Perform(new { action = "account.enroll_continuity" });
    private void OnSync(object? sender, RoutedEventArgs e) => Perform(new { action = "account.sync" });
    private void OnConfirmIdentity(object? sender, RoutedEventArgs e) => Perform(new { action = "account.identity", identity = Identity.Text ?? "" });
    private void OnRefresh(object? sender, RoutedEventArgs e) => Perform(new { action = "switch.refresh" });
    private void OnRestore(object? sender, RoutedEventArgs e) => Perform(new { action = "switch.stop" });
    private void OnEnabledChanged(object? sender, RoutedEventArgs e) => Perform(new { action = Enabled.IsChecked == true ? "switch.start" : "switch.stop" });
    private void OnSelectionChanged(object? sender, SelectionChangedEventArgs e)
        => Perform(new { action = "switch.configure", buds = (Buds.SelectedItem as Choice)?.Id, phone = (Phone.SelectedItem as Choice)?.Id });
    private void OnDeviceRefresh(object? sender, RoutedEventArgs e)
    { if (_canRefreshDevice) Perform(new { action = "device.refresh" }); }
    private void OnNoise(object? sender, RoutedEventArgs e)
    {
        if (_rendering || !_canControl || sender is not ToggleButton button || button.Tag is not string mode) return;
        Perform(new { action = "device.noise", mode });
        // Selection always represents confirmed state, never an optimistic command result.
        _rendering = true;
        NoiseOff.IsChecked = _noiseMode == "off"; NoiseAnc.IsChecked = _noiseMode == "anc";
        NoiseAmbient.IsChecked = _noiseMode == "ambient"; NoiseAdaptive.IsChecked = _noiseMode == "adaptive";
        _rendering = false;
    }
    private void OnEqualizerChanged(object? sender, SelectionChangedEventArgs e)
    {
        if (_rendering || !_canControl || Equalizer.SelectedItem is not Preset preset) return;
        Perform(new { action = "device.equalizer", preset = preset.Id });
        _rendering = true;
        Equalizer.SelectedItem = Presets.FirstOrDefault(p => p.Id == _equalizerPreset);
        _rendering = false;
    }
    private void OnTouchChanged(object? sender, RoutedEventArgs e)
    {
        if (_rendering || !_canControl) return;
        Perform(new { action = "device.touch", enabled = Touch.IsChecked == true });
        _rendering = true; Touch.IsChecked = _touchEnabled == true; _rendering = false;
    }
}
