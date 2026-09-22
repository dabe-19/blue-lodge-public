using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

public class Program {
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    private static extern bool ShowWindowAsync(IntPtr hWnd, int nCmdShow);

    private const int SW_MINIMIZE = 6;

    public static void Main(string[] args) {
        if (args.Length == 0) return;

        IntPtr fg = GetForegroundWindow();

        string wtArgs = "";
        for (int i = 0; i < args.Length; i++) {
            string a = args[i];
            if (a.Contains(" ") || a.Contains("\"")) {
                wtArgs += "\"" + a.Replace("\"", "\\\"") + "\" ";
            } else {
                wtArgs += a + " ";
            }
        }

        ProcessStartInfo psi = new ProcessStartInfo {
            FileName = "wt.exe",
            Arguments = wtArgs.Trim(),
            UseShellExecute = true
        };

        try {
            Process.Start(psi);
        } catch (Exception) {
            return;
        }

        string targetTitle = "";
        for (int i = 0; i < args.Length; i++) {
            if ((args[i] == "--title" || args[i] == "-t") && i + 1 < args.Length) {
                targetTitle = args[i + 1];
                break;
            }
        }

        for (int i = 0; i < 40; i++) {
            Thread.Sleep(50);
            Process[] wts = Process.GetProcessesByName("WindowsTerminal");
            bool found = false;
            foreach (Process w in wts) {
                if (w.MainWindowHandle != IntPtr.Zero && w.MainWindowHandle != fg) {
                    if (string.IsNullOrEmpty(targetTitle) || w.MainWindowTitle.IndexOf(targetTitle, StringComparison.OrdinalIgnoreCase) >= 0) {
                        ShowWindowAsync(w.MainWindowHandle, SW_MINIMIZE);
                        if (fg != IntPtr.Zero) {
                            SetForegroundWindow(fg);
                        }
                        found = true;
                        break;
                    }
                }
            }
            if (found) break;
        }

        if (fg != IntPtr.Zero) {
            SetForegroundWindow(fg);
        }
    }
}
