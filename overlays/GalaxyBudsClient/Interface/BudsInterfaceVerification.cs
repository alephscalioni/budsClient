#if DEBUG
using System;
using System.IO;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media.Imaging;
using Avalonia.VisualTree;
using GalaxyBudsClient.Interface.Controls;
using GalaxyBudsClient.Platform;

namespace GalaxyBudsClient.Interface;

/// <summary>Host-invoked, read-only UI QA. Own-control renders exclude the desktop and window decorations.</summary>
internal static class BudsInterfaceVerification
{
    internal static async Task RunAsync()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "samsung audio", "reports", "buds-single-window-review");
        Directory.CreateDirectory(directory);
        var stage = "waiting_for_layout";
        try
        {
            await Task.Delay(1800);
            if (NativeBudsIntegration.NativeOnlyMode)
            {
                NativeBudsMenuBar.SetReviewStage(2);
                await Task.Delay(1800);
                var retained = NativeBudsMenuBar.SetReviewStage(3);
                NativeBudsMenuBar.SetReviewStage(0);
                if (int.TryParse(Environment.GetEnvironmentVariable("BUDS_VERIFY_REVIEW_STAGE"), out var reviewStage))
                    NativeBudsMenuBar.SetReviewStage(reviewStage);
                await WriteAsync(directory, new { surface = "NSStatusItem / NSPopover / NSHostingController / SwiftUI",
                    action_failure_retained_across_polling = retained, window_capture_by_cua = true,
                    device_actions_performed = false, runtime_behavior_verified = false });
                return;
            }
            stage = "finding_shell";
            var shell = MainWindow.Instance.GetVisualDescendants().OfType<NativeBudsShell>().FirstOrDefault();
            if (shell == null)
            {
                await WriteAsync(directory, new { verification_failed = true, reason = "NativeBudsShell is not mounted; no legacy navigation was attempted." });
                return;
            }
            stage = "finding_panel";
            var panel = shell.FindControl<BudsIntegrationPanel>("Integration")
                ?? shell.GetVisualDescendants().OfType<BudsIntegrationPanel>().FirstOrDefault()
                ?? throw new InvalidOperationException("Native integration panel is not mounted.");
            var bounds = shell.Bounds;
            if (bounds.Width <= 0 || bounds.Height <= 0) throw new InvalidOperationException("Native shell has no layout bounds.");
            var expanders = panel.GetVisualDescendants().OfType<Expander>().ToArray();
            var expansion = expanders.Select(expander => expander.IsExpanded).ToArray();
            try
            {
                // This is the actual mounted native shell, including its scrolling viewport.
                stage = "rendering_collapsed";
                Render(shell, bounds, Path.Combine(directory, "native-buds-panel-render.png"));
                stage = "expanding_details";
                foreach (var expander in expanders) expander.IsExpanded = true;
                await Task.Delay(250);
                if (Environment.GetEnvironmentVariable("BUDS_VERIFY_HOLD_DETAILS") == "1")
                {
                    await WriteAsync(directory, new { stage = "expanded_ready", window_capture_by_host = true, device_actions_performed = false });
                    await Task.Delay(20000);
                }
                stage = "rendering_expanded";
                // A second own-control render exposes all disclosure content at the same width.
                shell.Measure(new Size(bounds.Width, double.PositiveInfinity));
                var expanded = new Rect(new Size(bounds.Width, Math.Max(bounds.Height, shell.DesiredSize.Height)));
                shell.Arrange(expanded);
                Render(shell, expanded, Path.Combine(directory, "native-buds-details-render.png"));
                var actionFailureRetained = await panel.VerifyPersistentActionFailureAsync();
                if (Environment.GetEnvironmentVariable("BUDS_VERIFY_NATIVE_STAGES") == "1")
                {
                    var originalHeight = MainWindow.Instance.Height;
                    try
                    {
                        MainWindow.Instance.Height = MainWindow.Instance.MinHeight;
                        MainWindow.Instance.Activate();
                        await Task.Delay(400);
                        await WriteAsync(directory, new { stage = "minimum_height_ready", window_capture_by_host = true,
                            minimum_height = MainWindow.Instance.MinHeight, actual_height = MainWindow.Instance.Bounds.Height,
                            device_actions_performed = false });
                        await Task.Delay(10000);
                    }
                    finally { MainWindow.Instance.Height = originalHeight; }
                }
                await WriteAsync(directory, new
                {
                    action_failure_retained_across_polling = actionFailureRetained,
                    surface = nameof(NativeBudsShell),
                    screenshot_kind = "own-control render; not a desktop screenshot; excludes native window decorations",
                    panel_width = bounds.Width,
                    panel_height = bounds.Height,
                    details_height = expanded.Height,
                    captures = new[] { "native-buds-panel-render.png", "native-buds-details-render.png" },
                    has_account_controls = Has(panel, "SignIn") && Has(panel, "Sync") && Has(panel, "Cancel") && Has(panel, "ConfirmIdentity"),
                    has_switch_controls = Has(panel, "Enabled") && Has(panel, "Refresh") && Has(panel, "Restore") && Has(panel, "Buds") && Has(panel, "Phone"),
                    has_device_controls = Has(panel, "NoiseControls") && Has(panel, "Equalizer") && Has(panel, "Touch") && Has(panel, "DeviceRefresh"),
                    has_bilateral_and_case_battery = Has(panel, "LeftBattery") && Has(panel, "RightBattery") && Has(panel, "CaseBattery"),
                    text_brushes = panel.GetVisualDescendants().OfType<TextBlock>().Select(t => t.Foreground?.ToString()).Distinct().ToArray(),
                    laid_out_text_count = panel.GetVisualDescendants().OfType<TextBlock>().Count(t => t.IsVisible && t.Bounds.Width > 0 && t.Bounds.Height > 0),
                    device_actions_performed = false,
                    runtime_behavior_verified = false
                });
            }
            finally
            {
                for (var index = 0; index < expanders.Length; index++) expanders[index].IsExpanded = expansion[index];
                shell.Measure(bounds.Size);
                shell.Arrange(bounds);
                shell.InvalidateMeasure();
            }
        }
        catch (Exception ex)
        {
            await WriteAsync(directory, new { verification_failed = true, stage, exception_type = ex.GetType().Name, exception_message = ex.Message });
        }
    }

    private static bool Has(Control root, string name) => root.GetVisualDescendants().Any(v => v.Name == name);
    private static Task WriteAsync(string directory, object result)
        => File.WriteAllTextAsync(Path.Combine(directory, "verification.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
    private static void Render(Control control, Rect bounds, string path)
    {
        control.Arrange(new Rect(bounds.Size));
        try
        {
            using var image = new RenderTargetBitmap(new PixelSize((int)Math.Ceiling(bounds.Width * 2), (int)Math.Ceiling(bounds.Height * 2)), new Vector(192, 192));
            image.Render(control);
            image.Save(path);
        }
        finally { control.Arrange(bounds); }
    }
}
#endif
