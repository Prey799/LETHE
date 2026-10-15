using System;
using System.IO;
using System.Text;
using System.Diagnostics;
using System.Security.Cryptography;
using Renci.SshNet;
using Renci.SshNet.Common;

namespace Lethe {
    // Event handlers run on SSH.NET threads; no PowerShell callbacks on those threads.
    public sealed class SshTransport : IDisposable {
        private SshClient ssh;
        private SftpClient sftp;
        private PrivateKeyFile privateKey;
        private readonly string expected;
        public string Fingerprint { get; private set; }
        public string KeyType { get; private set; }
        public bool HostKeyMismatch { get; private set; }
        public SshTransport(string host, int port, string user, string password,
                            string keyPath, string passphrase, string fingerprint) {
            expected = (fingerprint ?? "").Trim();
            AuthenticationMethod method;
            if (expected.Length == 0) method = new NoneAuthenticationMethod(user);
            else if (!String.IsNullOrEmpty(keyPath)) {
                privateKey = String.IsNullOrEmpty(passphrase) ? new PrivateKeyFile(keyPath) : new PrivateKeyFile(keyPath, passphrase);
                method = new PrivateKeyAuthenticationMethod(user, privateKey);
            } else method = new PasswordAuthenticationMethod(user, password ?? "");
            var info = new ConnectionInfo(host, port, user, method);
            info.Timeout = TimeSpan.FromSeconds(15);
            ssh = new SshClient(info); sftp = new SftpClient(info);
            ssh.KeepAliveInterval = TimeSpan.FromSeconds(15);
            sftp.OperationTimeout = TimeSpan.FromSeconds(30);
            ssh.HostKeyReceived += OnHostKey;
            sftp.HostKeyReceived += OnHostKey;
        }
        private void OnHostKey(object sender, HostKeyEventArgs e) {
            using (var sha = SHA256.Create()) {
                Fingerprint = "SHA256:" + Convert.ToBase64String(sha.ComputeHash(e.HostKey)).TrimEnd('=');
            }
            KeyType = e.HostKeyName;
            e.CanTrust = expected.Length > 0 && String.Equals(expected, Fingerprint, StringComparison.Ordinal);
            HostKeyMismatch = expected.Length > 0 && !e.CanTrust;
        }
        public void Connect() { ssh.Connect(); }
        public void Probe() {
            try { ssh.Connect(); } catch { if (Fingerprint == null) throw; }
            // Authentication is never sent for an unpinned host (host key is rejected above).
        }
        public string Execute(string command, int seconds) {
            using (var cmd = ssh.CreateCommand(command)) {
                cmd.CommandTimeout = TimeSpan.FromSeconds(seconds);
                string result = cmd.Execute();
                if (cmd.ExitStatus != 0) throw new InvalidOperationException("Remote command failed.");
                return result;
            }
        }
        public int ExecuteLogged(string command, string logPath, int seconds) {
            using (var cmd = ssh.CreateCommand(command)) {
                cmd.CommandTimeout = TimeSpan.FromSeconds(seconds);
                var task = cmd.BeginExecute();
                using (var reader = new StreamReader(cmd.OutputStream, Encoding.UTF8))
                using (var log = new StreamWriter(logPath, true, new UTF8Encoding(false))) {
                    log.AutoFlush = true;
                    string line;
                    int count = 0;
                    var clock = Stopwatch.StartNew();
                    while (true) {
                        var read = reader.ReadLineAsync();
                        double remaining = seconds - clock.Elapsed.TotalSeconds;
                        if (remaining <= 0 || !read.Wait(TimeSpan.FromSeconds(remaining)))
                            throw new TimeoutException("Remote operation timed out.");
                        line = read.Result;
                        if (line == null) break;
                        if (++count > 2000 || line.Length > 16384) throw new InvalidOperationException("Remote output limit.");
                        // Only the installer's structured protocol is retained, no raw SSH stderr.
                        if (line.StartsWith("{\"event\":", StringComparison.Ordinal)) log.WriteLine(line);
                    }
                }
                cmd.EndExecute(task);
                return cmd.ExitStatus == 0 ? 0 : 1;
            }
        }
        public void Upload(byte[] bytes, string remotePath) {
            if (!sftp.IsConnected) sftp.Connect();
            using (var stream = new MemoryStream(bytes, false)) sftp.UploadFile(stream, remotePath, false);
            sftp.ChangePermissions(remotePath, 600); // SSH.NET takes octal digits (600), not the bitmask (384).
        }
        public void Dispose() {
            if (sftp != null) sftp.Dispose();
            if (ssh != null) ssh.Dispose();
            if (privateKey != null) privateKey.Dispose();
        }
    }
}
