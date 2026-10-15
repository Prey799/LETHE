using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;
namespace Lethe {
    // Child engines inherit file handles directly, so logging survives the short-lived START worker.
    public static class NativeProcess {
        public sealed class Result { public int ExitCode; public string Output; }
        public static Result Run(string file, string arguments, int timeoutMilliseconds) {
            var info=new System.Diagnostics.ProcessStartInfo(file,arguments) { UseShellExecute=false, CreateNoWindow=true, RedirectStandardOutput=true, RedirectStandardError=true };
            using(var process=new System.Diagnostics.Process()) {
                process.StartInfo=info;process.Start();
                var output=process.StandardOutput.ReadToEndAsync();var error=process.StandardError.ReadToEndAsync();
                if(!process.WaitForExit(timeoutMilliseconds)) {
                    try {process.Kill();process.WaitForExit(5000);}catch{}
                    return new Result {ExitCode=124,Output=""};
                }
                string text=output.GetAwaiter().GetResult();error.GetAwaiter().GetResult();
                return new Result {ExitCode=process.ExitCode,Output=text};
            }
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct SecurityAttributes { public int length; public IntPtr descriptor; public int inherit; }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet=System.Runtime.InteropServices.CharSet.Unicode)]
        struct StartupInfo {
            public int cb; public string reserved, desktop, title;
            public int x,y,xSize,ySize,xCount,yCount,fill,flags;
            public short showWindow, reservedSize; public IntPtr reservedData, stdin, stdout, stderr;
        }
        [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
        struct ProcessInformation { public IntPtr process, thread; public int pid, tid; }
        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
        static extern IntPtr CreateFileW(string name,uint access,uint share,ref SecurityAttributes security,uint creation,uint flags,IntPtr template);
        [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet=System.Runtime.InteropServices.CharSet.Unicode, SetLastError=true)]
        [return:System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
        static extern bool CreateProcessW(string app,System.Text.StringBuilder command,IntPtr pa,IntPtr ta,bool inherit,uint flags,IntPtr env,string directory,ref StartupInfo start,out ProcessInformation info);
        [System.Runtime.InteropServices.DllImport("kernel32.dll")]
        static extern bool CloseHandle(IntPtr handle);
        static IntPtr Open(string path, bool write, ref SecurityAttributes sa) {
            IntPtr h=CreateFileW(path,write?0x40000000u:0x80000000u,3,ref sa,write?2u:3u,128,IntPtr.Zero);
            if(h==new IntPtr(-1))throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
            return h;
        }
        public static System.Diagnostics.Process Start(string file,string arguments,string directory,string output,string error) {
            var sa=new SecurityAttributes { length=System.Runtime.InteropServices.Marshal.SizeOf(typeof(SecurityAttributes)), inherit=1 };
            IntPtr input=IntPtr.Zero,outHandle=IntPtr.Zero,errHandle=IntPtr.Zero;
            var pi=new ProcessInformation();
            try {
                input=Open("NUL",false,ref sa);outHandle=Open(output,true,ref sa);errHandle=Open(error,true,ref sa);
                var si=new StartupInfo { cb=System.Runtime.InteropServices.Marshal.SizeOf(typeof(StartupInfo)), flags=0x100, stdin=input, stdout=outHandle, stderr=errHandle };
                var cmd=new System.Text.StringBuilder("\""+file+"\" "+arguments);
                if(!CreateProcessW(file,cmd,IntPtr.Zero,IntPtr.Zero,true,0x08000000,IntPtr.Zero,directory,ref si,out pi))
                    throw new System.ComponentModel.Win32Exception(System.Runtime.InteropServices.Marshal.GetLastWin32Error());
                return System.Diagnostics.Process.GetProcessById(pi.pid);
            } finally {
                foreach(IntPtr h in new[] {input,outHandle,errHandle,pi.thread,pi.process}) if(h!=IntPtr.Zero && h!=new IntPtr(-1))CloseHandle(h);
            }
        }
    }
    public static class Shapes {
        public static GraphicsPath Round(Rectangle r, int radius) {
            var p = new GraphicsPath(); int d = Math.Min(radius * 2, Math.Min(r.Width, r.Height));
            p.AddArc(r.Left, r.Top, d, d, 180, 90); p.AddArc(r.Right - d, r.Top, d, d, 270, 90);
            p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90); p.AddArc(r.Left, r.Bottom - d, d, d, 90, 90);
            p.CloseFigure(); return p;
        }
    }
    public sealed class RoundedField : UserControl {
        readonly TextBox input = new TextBox();
        public TextBox Input { get { return input; } }
        public RoundedField() {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw, true);
            BackColor = Color.FromArgb(18, 31, 50); ForeColor = Color.FromArgb(236, 243, 249);
            Font = new Font("Segoe UI", 10); Size = new Size(300, 42);
            input.BorderStyle = BorderStyle.None; input.BackColor = BackColor; input.ForeColor = ForeColor; input.Font = Font;
            input.TextChanged += delegate { OnTextChanged(EventArgs.Empty); };
            input.GotFocus += delegate { Invalidate(); }; input.LostFocus += delegate { Invalidate(); };
            Controls.Add(input); TabStop = false; LayoutInput();
        }
        public override string Text { get { return input.Text; } set { input.Text = value ?? ""; } }
        public bool ReadOnly { get { return input.ReadOnly; } set { input.ReadOnly = value; input.ForeColor = value ? Color.FromArgb(171, 193, 220) : ForeColor; } }
        public bool UseSystemPasswordChar { get { return input.UseSystemPasswordChar; } set { input.UseSystemPasswordChar = value; } }
        protected override void OnSizeChanged(EventArgs e) { base.OnSizeChanged(e); if (input != null) LayoutInput(); }
        protected override void OnFontChanged(EventArgs e) { base.OnFontChanged(e); if (input != null) { input.Font = Font; LayoutInput(); } }
        protected override void OnEnabledChanged(EventArgs e) { base.OnEnabledChanged(e); Invalidate(); }
        void LayoutInput() { input.SetBounds(13, Math.Max(7, (Height - input.PreferredHeight) / 2), Math.Max(10, Width - 26), input.PreferredHeight); }
        protected override void OnPaint(PaintEventArgs e) {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent == null ? Color.FromArgb(11, 21, 37) : Parent.BackColor);
            using (var path = Shapes.Round(new Rectangle(1, 1, Width - 3, Height - 3), 10))
            using (var fill = new SolidBrush(BackColor))
            using (var edge = new Pen(input.Focused ? Color.FromArgb(88, 214, 216) : Color.FromArgb(47, 68, 91), input.Focused ? 2f : 1f)) {
                e.Graphics.FillPath(fill, path); e.Graphics.DrawPath(edge, path);
            }
        }
    }
    public sealed class RoundCard : Panel {
        public RoundCard() { DoubleBuffered = true; BackColor = Color.FromArgb(11, 21, 37); SetStyle(ControlStyles.ResizeRedraw, true); }
        protected override void OnPaintBackground(PaintEventArgs e) {
            e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
            e.Graphics.Clear(Parent == null ? Color.FromArgb(2, 5, 13) : Parent.BackColor);
            using (var path = Shapes.Round(new Rectangle(0, 0, Width - 1, Height - 1), 14))
            using (var brush = new SolidBrush(BackColor)) { e.Graphics.FillPath(brush, path); }
        }
    }
}
