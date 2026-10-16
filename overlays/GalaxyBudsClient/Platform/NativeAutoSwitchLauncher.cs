using System;
using System.Diagnostics;
using System.IO;
using System.Threading.Tasks;

namespace GalaxyBudsClient.Platform;

/// <summary>Opens the optional native settings app; switching remains controlled by that app.</summary>
internal static class NativeAutoSwitchLauncher
{
    private const string AppName = "Galaxy Buds Auto Switch.app";

    public static async Task<bool> OpenAsync(string? budsAddress, string? budsName)
    {
        if (!PlatformUtils.IsOSX)
            throw new PlatformNotSupportedException();

        if (NativeBudsIntegration.IsAvailable)
        {
            NativeBudsIntegration.OpenSwitch(budsAddress, budsName);
            return true;
        }

        var appPath = FindHelperApp(AppContext.BaseDirectory, Environment.CurrentDirectory);
        if (appPath == null)
            return false;

        using var process = Process.Start(CreateStartInfo(appPath, budsAddress, budsName))
                            ?? throw new InvalidOperationException("Could not start /usr/bin/open.");
        var stderr = process.StandardError.ReadToEndAsync();
        await process.WaitForExitAsync();
        var details = await stderr;
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"/usr/bin/open exited with code {process.ExitCode}: {details}");
        return true;
    }

    internal static ProcessStartInfo CreateStartInfo(string appPath, string? budsAddress, string? budsName)
    {
        var startInfo = new ProcessStartInfo("/usr/bin/open")
        {
            UseShellExecute = false,
            RedirectStandardError = true
        };
        startInfo.ArgumentList.Add("-a");
        startInfo.ArgumentList.Add(appPath);
        startInfo.ArgumentList.Add("--args");
        if (!string.IsNullOrWhiteSpace(budsAddress))
        {
            startInfo.ArgumentList.Add("--buds-address");
            startInfo.ArgumentList.Add(budsAddress);
        }
        if (!string.IsNullOrWhiteSpace(budsName))
        {
            startInfo.ArgumentList.Add("--buds-name");
            startInfo.ArgumentList.Add(budsName);
        }

        return startInfo;
    }

    internal static string? FindHelperApp(string baseDirectory, string workingDirectory)
    {
        var bundledPath = Path.Combine(baseDirectory, "AutoSwitch", AppName);
        if (Directory.Exists(bundledPath))
            return bundledPath;

        // Covers dotnet run, IDE output directories, and a launch from the source checkout.
        return FindInParents(baseDirectory) ?? FindInParents(workingDirectory);
    }

    private static string? FindInParents(string startPath)
    {
        for (var directory = new DirectoryInfo(startPath); directory != null; directory = directory.Parent)
        {
            var candidate = Path.Combine(directory.FullName, "macOSAutoSwitch", "dist", AppName);
            if (Directory.Exists(candidate))
                return candidate;
        }
        return null;
    }
}
