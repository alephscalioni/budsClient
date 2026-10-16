using System;
using System.IO;
using System.Text.Json;
using GalaxyBudsClient.Message;
using GalaxyBudsClient.Message.Decoder;
using GalaxyBudsClient.Model.Config;

namespace GalaxyBudsClient.Platform;

/// <summary>Shares the existing status decoder and icon selection with the native companion.</summary>
internal static class NativeBudsStatusPublisher
{
    private static readonly object Gate = new();
    public static void Publish(IBasicStatusUpdate status)
    {
        if (!OperatingSystem.IsMacOS() || !BluetoothImpl.Instance.IsConnected || BluetoothImpl.Instance.Device.Current is not { } device)
            return;
        // Same color precedence as EarbudIcon; no second icon catalogue.
        var color = Settings.Data.ColorOverride ?? device.DeviceColor ?? DeviceMessageCache.Instance.ExtendedStatusUpdate?.DeviceColor;
        int? Battery(int value) => value is > 0 and <= 100 ? value : null;
        var data = JsonSerializer.SerializeToUtf8Bytes(new
        {
            address = device.MacAddress, name = device.Name, model = device.Model.ToString(), icon = color?.ToString(),
            left = Battery(status.BatteryL), right = Battery(status.BatteryR), case_percent = Battery(status.BatteryCase),
            observed_at = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0
        });
        lock (Gate)
        {
            string? temporary = null;
            try
            {
                var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Library", "Application Support", "BudsAutoSwitch");
                Directory.CreateDirectory(directory);
                temporary = Path.Combine(directory, $".battery-{Guid.NewGuid():N}.tmp");
                File.WriteAllBytes(temporary, data);
                File.SetUnixFileMode(temporary, UnixFileMode.UserRead | UnixFileMode.UserWrite);
                File.Move(temporary, Path.Combine(directory, "battery-status.json"), true);
            }
            catch (IOException) { /* Optional presentation must not interrupt Bluetooth. */ }
            catch (UnauthorizedAccessException) { }
            finally
            {
                try { if (temporary != null && File.Exists(temporary)) File.Delete(temporary); }
                catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
        }
    }
}
