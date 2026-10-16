using System;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Threading;

namespace GalaxyBudsClient.Platform;

/// <summary>One native status item and popover, sharing the existing app's transport lease.</summary>
internal static class NativeBudsMenuBar
{
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ActionCallback(IntPtr json);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_menubar_start")]
    private static extern IntPtr StartNative(ActionCallback callback);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_menubar_show")]
    private static extern void ShowNative(IntPtr controller, int toggle);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_menubar_error")]
    private static extern void ReportError(IntPtr controller, [MarshalAs(UnmanagedType.LPUTF8Str)] string message);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_set_host_action_callback")]
    private static extern void SetHostActionCallback(ActionCallback callback);
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_prepare_update_termination")]
    private static extern int PrepareUpdateTermination();
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_cancel_update_termination")]
    private static extern void CancelUpdateTermination();
    private static readonly ActionCallback Callback = DispatchAction;
    private static IntPtr _controller;
    private static IClassicDesktopStyleApplicationLifetime? _lifetime;
    private static bool _quitting;
    private static bool _cleanupComplete;

    internal static void Start(IClassicDesktopStyleApplicationLifetime lifetime)
    {
        _lifetime = lifetime;
        _controller = StartNative(Callback);
        SetHostActionCallback(Callback);
        if (_controller == IntPtr.Zero) throw new InvalidOperationException("Não foi possível abrir o Buds na barra de menus.");
        NativeBudsIntegration.StartNativeMaintenance();
        lifetime.ShutdownRequested += (_, e) =>
        {
            if (_cleanupComplete) return;
            e.Cancel = true;
            _ = QuitAsync();
        };
    }

    internal static void Show(bool toggle = false)
    {
        if (!Dispatcher.UIThread.CheckAccess()) { Dispatcher.UIThread.Post(() => Show(toggle)); return; }
        if (_controller != IntPtr.Zero) ShowNative(_controller, toggle ? 1 : 0);
    }

    private static void DispatchAction(IntPtr json)
    {
        var request = Marshal.PtrToStringUTF8(json);
        if (request == null || request.Length > 16384) return;
        Dispatcher.UIThread.Post(async () =>
        {
            try
            {
                using var document = JsonDocument.Parse(request);
                if (document.RootElement.GetProperty("action").GetString() == "app.quit") { await QuitAsync(); return; }
                if (!_quitting) await NativeBudsIntegration.PerformAsync(document.RootElement.Clone());
            }
            catch (Exception)
            {
                if (!_quitting) ReportError(_controller, "A ação não foi concluída. Verifique a conexão e tente novamente.");
            }
        });
    }

    private static async Task QuitAsync()
    {
        if (_quitting) return;
        _quitting = true;
        try
        {
            for (var attempt = 0; PrepareUpdateTermination() == 0; attempt++)
            {
                if (attempt >= 200)
                {
                    CancelUpdateTermination();
                    _quitting = false;
                    ReportError(_controller, "A atualização está aguardando o fim da reprodução ou da chamada. Tente sair novamente depois.");
                    return;
                }
                await Task.Delay(100);
            }
            await NativeBudsIntegration.ShutdownAsync();
            _cleanupComplete = true;
            _lifetime?.Shutdown();
        }
        catch
        {
            CancelUpdateTermination();
            _quitting = false;
            ReportError(_controller, "Não foi possível encerrar com segurança. Aguarde o Bluetooth concluir e tente novamente.");
        }
    }

#if DEBUG
    [DllImport("libBudsNative.dylib", EntryPoint = "buds_menubar_review_stage")]
    private static extern int ReviewStage(IntPtr controller, int stage);
    internal static bool SetReviewStage(int stage) => _controller != IntPtr.Zero && ReviewStage(_controller, stage) == 1;
#endif
}
