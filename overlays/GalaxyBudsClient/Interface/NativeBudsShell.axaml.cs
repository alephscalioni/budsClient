using Avalonia.Controls;
namespace GalaxyBudsClient.Interface;

/// <summary>Compact native-only host. Does not construct legacy pages or device viewmodels.</summary>
public partial class NativeBudsShell : UserControl
{
    public NativeBudsShell()
    {
        InitializeComponent();
    }
}
