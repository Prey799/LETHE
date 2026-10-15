using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Globalization;
using System.IO;
using System.Management.Automation;
using System.Management.Automation.Host;
using System.Management.Automation.Runspaces;
using System.Reflection;
using System.Security;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
[assembly: AssemblyTitle("LETHE ONE")]
[assembly: AssemblyProduct("LETHE ONE VPN")]
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8", FrameworkDisplayName=".NET Framework 4.8")]
[assembly: AssemblyVersion("0.7.2.0")]
[assembly: AssemblyFileVersion("0.7.2.0")]
namespace Lethe {
    // Windows GUI executable; the Windows PowerShell engine runs in-process.
    internal static class App {
        [STAThread] static int Main(string[] args) {
            bool gui = args.Length == 0;
            string root = AppDomain.CurrentDomain.BaseDirectory;
            string logDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "LETHE-One", "logs");
            try {
                Directory.CreateDirectory(logDir);
                string script = Path.Combine(root, "LETHE-One.ps1");
                var parameters = new Dictionary<string, object>();
                if (!gui) {
                    if (args.Length == 2 && args[0] == "--action" && Array.IndexOf(new[] {"start", "stop", "status"}, args[1]) >= 0) {
                        script = Path.Combine(root, "scripts", "Entry-One.ps1"); parameters.Add("Action", args[1]);
                    } else if (args.Length == 1 && args[0] == "--guardian") {
                        script = Path.Combine(root, "scripts", "Guardian-One.ps1");
                    } else if ((args.Length == 3 || args.Length == 5) && args[0] == "--deploy" &&
                        Array.IndexOf(new[] {"status", "install", "remove-plan", "remove"}, args[1]) >= 0 && Regex.IsMatch(args[2], "^[a-f0-9]{32}$")) {
                        script = Path.Combine(root, "scripts", "Deploy-Worker.ps1");
                        parameters.Add("Action", args[1]); parameters.Add("JobId", args[2]);
                        if (args[1] == "remove") {
                            if (args.Length != 5 || !Regex.IsMatch(args[3], "^[a-f0-9]{64}$") || !Regex.IsMatch(args[4], "^[A-Za-z0-9.-]{1,253}$")) return 2;
                            parameters.Add("PlanToken", args[3]); parameters.Add("ConfirmDomain", args[4]);
                        } else if (args.Length != 3) return 2;
                    } else return 2;
                }
                if (!File.Exists(script)) throw new FileNotFoundException("Распакуйте архив целиком: рядом с LETHE.exe должны быть скрипты и папки engine, lib.");
                var host = new AppHost();
                var state = InitialSessionState.CreateDefault();
                // Process scope only; machine/user Group Policy still takes precedence.
                Environment.SetEnvironmentVariable("PSExecutionPolicyPreference", "Bypass", EnvironmentVariableTarget.Process);
                using (var runspace = RunspaceFactory.CreateRunspace(host, state)) {
                    runspace.ApartmentState = ApartmentState.STA;
                    runspace.ThreadOptions = PSThreadOptions.UseCurrentThread;
                    runspace.Open();
                    Runspace.DefaultRunspace = runspace;
                    using (var shell = PowerShell.Create()) {
                        shell.Runspace = runspace; shell.AddCommand(script);
                        foreach (var p in parameters) shell.AddParameter(p.Key, p.Value);
                        shell.Invoke();
                        if (host.ExitCode != 0) return host.ExitCode;
                        if (shell.InvocationStateInfo.State == PSInvocationState.Failed)
                            throw shell.InvocationStateInfo.Reason ?? new InvalidOperationException("Операция LETHE не выполнена.");
                    }
                }
                return host.ExitCode;
            } catch (Exception ex) {
                string safe = Regex.Replace(ex.Message, @"(?i)https://[^\s@]+@", "https://[REDACTED]@");
                try { File.WriteAllText(Path.Combine(logDir, "app-startup.log"), ex.GetType().Name + ": " + safe, Encoding.UTF8); } catch { }
                if (gui) MessageBox.Show("LETHE не запустился. " + safe + "\n\nЖурнал: " + Path.Combine(logDir, "app-startup.log"), "LETHE", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
    internal sealed class AppHost : PSHost {
        readonly Guid id = Guid.NewGuid(); readonly SilentUI ui = new SilentUI(); public int ExitCode;
        public override Guid InstanceId { get { return id; } }
        public override string Name { get { return "LETHE"; } }
        public override Version Version { get { return new Version(0, 7, 2); } }
        public override PSHostUserInterface UI { get { return ui; } }
        public override CultureInfo CurrentCulture { get { return CultureInfo.CurrentCulture; } }
        public override CultureInfo CurrentUICulture { get { return CultureInfo.CurrentUICulture; } }
        public override void SetShouldExit(int code) { ExitCode = code; }
        public override void EnterNestedPrompt() { throw new NotSupportedException(); }
        public override void ExitNestedPrompt() { }
        public override void NotifyBeginApplication() { }
        public override void NotifyEndApplication() { }
    }
    internal sealed class SilentUI : PSHostUserInterface {
        readonly SilentRawUI raw = new SilentRawUI();
        public override PSHostRawUserInterface RawUI { get { return raw; } }
        public override string ReadLine() { throw new NotSupportedException("Используйте интерфейс LETHE."); }
        public override SecureString ReadLineAsSecureString() { throw new NotSupportedException(); }
        public override void Write(string value) { }
        public override void Write(ConsoleColor foregroundColor, ConsoleColor backgroundColor, string value) { }
        public override void WriteLine(string value) { }
        public override void WriteErrorLine(string value) { }
        public override void WriteDebugLine(string value) { }
        public override void WriteProgress(long sourceId, ProgressRecord record) { }
        public override void WriteVerboseLine(string value) { }
        public override void WriteWarningLine(string value) { }
        public override Dictionary<string, PSObject> Prompt(string caption, string message, Collection<FieldDescription> descriptions) { throw new NotSupportedException(); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName) { throw new NotSupportedException(); }
        public override PSCredential PromptForCredential(string caption, string message, string userName, string targetName, PSCredentialTypes allowedCredentialTypes, PSCredentialUIOptions options) { throw new NotSupportedException(); }
        public override int PromptForChoice(string caption, string message, Collection<ChoiceDescription> choices, int defaultChoice) { throw new NotSupportedException(); }
    }
    internal sealed class SilentRawUI : PSHostRawUserInterface {
        public SilentRawUI() { BackgroundColor=ConsoleColor.Black; ForegroundColor=ConsoleColor.Gray; BufferSize=new Size(120,3000); WindowSize=new Size(120,40); CursorSize=1; WindowTitle="LETHE"; }
        public override ConsoleColor BackgroundColor { get; set; }
        public override ConsoleColor ForegroundColor { get; set; }
        public override Size BufferSize { get; set; }
        public override Coordinates CursorPosition { get; set; }
        public override int CursorSize { get; set; }
        public override bool KeyAvailable { get { return false; } }
        public override Size MaxPhysicalWindowSize { get { return new Size(120,40); } }
        public override Size MaxWindowSize { get { return new Size(120,40); } }
        public override Coordinates WindowPosition { get; set; }
        public override Size WindowSize { get; set; }
        public override string WindowTitle { get; set; }
        public override void FlushInputBuffer() { }
        public override BufferCell[,] GetBufferContents(Rectangle rectangle) { return new BufferCell[1,1]; }
        public override KeyInfo ReadKey(ReadKeyOptions options) { throw new NotSupportedException("Используйте интерфейс LETHE."); }
        public override void ScrollBufferContents(Rectangle source, Coordinates destination, Rectangle clip, BufferCell fill) { }
        public override void SetBufferContents(Coordinates origin, BufferCell[,] contents) { }
        public override void SetBufferContents(Rectangle rectangle, BufferCell fill) { }
    }
}
