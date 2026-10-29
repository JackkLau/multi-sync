using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text.Json;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.System;

namespace MultiSync.Windows;

public sealed class MainWindow : Window
{
    private static readonly SolidColorBrush Accent = new(global::Windows.UI.Color.FromArgb(255, 9, 108, 116));
    private static readonly SolidColorBrush Ink = new(global::Windows.UI.Color.FromArgb(255, 24, 50, 56));
    private static readonly SolidColorBrush Canvas = new(global::Windows.UI.Color.FromArgb(255, 244, 248, 249));
    private readonly string _state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MultiSync");
    private string _inbox = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "MultiSync");
    private readonly HistoryStore _history;
    private readonly List<SendRecord> _outgoing;
    private readonly Dictionary<string, (TextBlock Text, ProgressBar Bar, Button Action)> _rows = [];
    private readonly InfoBar _notice = new() { IsClosable = true, IsOpen = false };
    private readonly PasswordBox _ticket = new() { Header = "对方的接收码（扫码自动填入）", PlaceholderText = "扫码连接，或点击从剪贴板粘贴", PasswordRevealMode = PasswordRevealMode.Peek };
    private readonly TextBlock _destination = Text("尚未连接接收设备");
    private readonly TextBlock _inboxLabel = Text("");
    private readonly TextBlock _receiverLabel = Text("接收未开启");
    private readonly ComboBox _addresses = new() { Header = "本机局域网地址", MinWidth = 240, HorizontalAlignment = HorizontalAlignment.Stretch };
    private readonly StackPanel _sendRows = new() { Spacing = 12 };
    private readonly StackPanel _receiveRows = new() { Spacing = 12 };
    private readonly Image _qr = new() { Width = 300, Height = 300, Stretch = Stretch.Uniform };
    private readonly NativeShare _share = new();
    private readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    private readonly Button _receiverButton;
    private readonly Button _folderButton;
    private readonly Button _copyButton;
    private readonly Button _shareButton;
    private readonly Button _saveQrButton;
    private readonly Button _sendButton;
    private readonly Button _pickButton;
    private string? _receiver;
    private string _receivingTicket = "";
    private byte[]? _qrPng;
    private bool _polling, _closing, _queueWritable = true;
    private string _incomingSnapshot = "";
    private SendRecord? _active;

    public MainWindow()
    {
        Title = "MultiSync";
        _history = new HistoryStore(Path.Combine(_state, "outgoing.json"));
        try { _outgoing = _history.Load(); }
        catch (Exception error) { _outgoing = []; _queueWritable = false; Notify("无法读取历史记录，已停止新队列写入。原文件已保留。\n" + error.Message, true); }
        var settingPath = Path.Combine(_state, "inbox.txt");
        try { if (File.Exists(settingPath)) _inbox = File.ReadAllText(settingPath).Trim(); }
        catch (Exception error) { Notify("无法读取接收目录设置，请重新选择目录。\n" + error.Message, true); }
        if (!Path.IsPathFullyQualified(_inbox)) _inbox = Path.Combine(_state, "Inbox");
        _inboxLabel.Text = _inbox;

        _receiverButton = ActionButton("开启接收", ToggleReceiverAsync, true);
        _folderButton = ActionButton("选择接收目录…", PickInboxAsync);
        _copyButton = ActionButton("复制接收码", CopyTicketAsync);
        _shareButton = ActionButton("分享二维码", ShareQrAsync);
        _saveQrButton = ActionButton("保存二维码图片…", SaveQrAsync);
        _sendButton = ActionButton("发送等待中的文件", SendQueuedAsync, true);
        _pickButton = ActionButton("选择文件…", PickFilesAsync);
        AutomationProperties.SetName(_qr, "本机接收二维码，包含连接凭据");
        RefreshAddresses();

        var send = Column();
        send.Children.Add(Text("把文件送到另一台设备", 27, true));
        send.Children.Add(Text("选择原文件，再扫描接收设备的二维码。传输后原文件始终保留。"));
        send.Children.Add(Row(
            ActionButton("扫码连接", ScanAsync),
            ActionButton("从二维码图片识别…", ImportQrAsync),
            ActionButton("从剪贴板粘贴", PasteTicketAsync)));
        send.Children.Add(_destination);
        send.Children.Add(_ticket);
        send.Children.Add(Row(_pickButton, _sendButton));
        send.Children.Add(Text("发送任务", 20, true));
        send.Children.Add(_sendRows);
        RenderOutgoing();

        var receive = Column();
        receive.Children.Add(Text("让设备扫描这里", 27, true));
        receive.Children.Add(Text("开启接收后自动生成二维码。无需粘贴任何内容；每份文件仍需你确认接收。"));
        receive.Children.Add(_addresses);
        receive.Children.Add(ActionButton("刷新网络地址", () => { RefreshAddresses(); return Task.CompletedTask; }));
        receive.Children.Add(_inboxLabel);
        receive.Children.Add(Row(_folderButton, _receiverButton, ActionButton("打开接收目录", OpenInboxAsync)));
        receive.Children.Add(_receiverLabel);
        receive.Children.Add(new Border { Child = _qr, Background = new SolidColorBrush(Colors.White), Padding = new Thickness(16), HorizontalAlignment = HorizontalAlignment.Left });
        receive.Children.Add(Row(_copyButton, _shareButton, _saveQrButton));
        receive.Children.Add(Text("两台设备需连接同一 Wi-Fi、热点或路由器。关闭应用或电脑休眠后将停止接收，已记录的任务可以继续。"));
        receive.Children.Add(Text("收到的文件", 20, true));
        _receiveRows.Children.Add(Text("还没有收到文件。开启接收后，让发送设备扫描二维码。"));
        receive.Children.Add(_receiveRows);

        var tabs = new Pivot();
        tabs.Items.Add(new PivotItem { Header = "发送文件", Content = new ScrollViewer { Content = send, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        tabs.Items.Add(new PivotItem { Header = "接收文件", Content = new ScrollViewer { Content = receive, VerticalScrollBarVisibility = ScrollBarVisibility.Auto } });
        var shell = new Grid { Background = Canvas, Padding = new Thickness(22), RequestedTheme = ElementTheme.Light };
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        shell.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        shell.Children.Add(Text("MultiSync · 个人设备收发空间", 21, true));
        Grid.SetRow(_notice, 1); shell.Children.Add(_notice);
        Grid.SetRow(tabs, 2); shell.Children.Add(tabs);
        Content = shell;
        AppWindow.Resize(new global::Windows.Graphics.SizeInt32(1040, 850));
        AppWindow.Changed += (window, change) => {
            if (change.DidSizeChange && (window.Size.Width < 860 || window.Size.Height < 620))
                window.Resize(new global::Windows.Graphics.SizeInt32(Math.Max(860, window.Size.Width), Math.Max(620, window.Size.Height)));
        };
        UpdateControls();
        _timer.Tick += async (_, _) => await PollAsync();
        _timer.Start();
        Closed += (_, _) => {
            _closing = true; _timer.Stop();
            // Stop before the desktop process exits. Durable checkpoints remain in the Rust store.
            if (_receiver is not null) { try { Bridge.Call(new { op = "stop", handle = _receiver }); } catch { } }
            foreach (var record in _outgoing.Where(r => r.Handle is not null)) {
                try { Bridge.Call(new { op = "stop", handle = record.Handle }); } catch { }
                if (record.Phase != "completed") record.Phase = "paused";
            }
            if (_queueWritable) { try { _history.SaveAsync(_outgoing).GetAwaiter().GetResult(); } catch { } }
        };
    }

    private static TextBlock Text(string value, double size = 15, bool bold = false) => new() {
        Text = value, FontSize = size, TextWrapping = TextWrapping.Wrap, Foreground = Ink,
        FontWeight = bold ? global::Windows.UI.Text.FontWeights.SemiBold : global::Windows.UI.Text.FontWeights.Normal
    };
    private static StackPanel Column() => new() { Spacing = 16, Margin = new Thickness(4, 14, 4, 24), MaxWidth = 900, HorizontalAlignment = HorizontalAlignment.Stretch };
    private static StackPanel Row(params UIElement[] items)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        foreach (var item in items) row.Children.Add(item);
        return row;
    }
    private Button ActionButton(string text, Func<Task> action, bool primary = false)
    {
        var button = new Button { Content = text, MinHeight = 36 };
        if (primary) { button.Background = Accent; button.Foreground = new SolidColorBrush(Colors.White); }
        button.Click += async (_, _) => {
            button.IsEnabled = false;
            try { await action(); }
            catch (Exception error) { Notify(error.Message, true); }
            finally { button.IsEnabled = true; UpdateControls(); }
        };
        return button;
    }
    private void Notify(string text, bool error = false) { _notice.Message = text; _notice.Severity = error ? InfoBarSeverity.Error : InfoBarSeverity.Informational; _notice.IsOpen = true; }
    private IntPtr WindowHandle => WinRT.Interop.WindowNative.GetWindowHandle(this);
    private void RefreshAddresses()
    {
        if (_receiver is not null) return;
        var previous = _addresses.SelectedItem as string;
        var values = NetworkInterface.GetAllNetworkInterfaces().Where(i => i.OperationalStatus == OperationalStatus.Up)
            .SelectMany(i => i.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
            .Select(a => a.Address.ToString()).Where(AddressRules.IsLocal).Distinct().ToList();
        _addresses.ItemsSource = values;
        _addresses.SelectedItem = values.Contains(previous ?? "") ? previous : values.FirstOrDefault();
        if (values.Count == 0) _receiverLabel.Text = "未发现局域网地址，请先连接 Wi-Fi、热点或路由器，再刷新。";
    }
    private void UpdateControls()
    {
        _copyButton.IsEnabled = _shareButton.IsEnabled = _saveQrButton.IsEnabled = _receivingTicket.Length > 0;
        _qr.Visibility = _qrPng is null ? Visibility.Collapsed : Visibility.Visible;
        _folderButton.IsEnabled = _addresses.IsEnabled = _receiver is null;
        _receiverButton.Content = _receiver is null ? "开启接收" : "停止接收";
        _receiverButton.IsEnabled = _receiver is not null || _addresses.SelectedItem is string;
        _pickButton.IsEnabled = _queueWritable;
        _sendButton.IsEnabled = _queueWritable && _active is null && _outgoing.Any(r => r.Phase == "queued");
    }
    private async Task PickInboxAsync()
    {
        if (_receiver is not null) return;
        var picker = new FolderPicker(); picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
        var folder = await picker.PickSingleFolderAsync(); if (folder is null) return;
        _inbox = folder.Path; _inboxLabel.Text = _inbox; _incomingSnapshot = "";
        Directory.CreateDirectory(_state); await File.WriteAllTextAsync(Path.Combine(_state, "inbox.txt"), _inbox);
        await RefreshIncomingAsync();
    }
    private async Task ToggleReceiverAsync()
    {
        if (_receiver is not null) {
            await Bridge.CallAsync(new { op = "stop", handle = _receiver });
            _receiverLabel.Text = "正在停止接收…"; return;
        }
        if (_addresses.SelectedItem is not string address) throw new InvalidOperationException("请先连接局域网并选择本机地址。");
        var result = await Bridge.CallAsync(new { op = "start_receive", inbox = _inbox, host = address, port = 53318 });
        _receiver = result.GetProperty("handle").GetString();
        _receiverLabel.Text = "正在开启接收并生成接收码…";
        UpdateControls();
    }
    private Task CopyTicketAsync()
    {
        if (_receivingTicket.Length == 0) return Task.CompletedTask;
        var package = new DataPackage(); package.SetText(_receivingTicket); Clipboard.SetContent(package); Clipboard.Flush();
        Notify("接收码已复制，可直接分享给要发送文件的设备。"); return Task.CompletedTask;
    }
    private async Task ShareQrAsync()
    {
        if (_qrPng is null) return;
        var directory = Path.Combine(_state, "Share"); Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, "MultiSync-receive.png"); await File.WriteAllBytesAsync(path, _qrPng);
        _share.Show(WindowHandle, await StorageFile.GetFileFromPathAsync(path), "MultiSync 接收二维码");
    }
    private async Task SaveQrAsync()
    {
        if (_qrPng is null) return;
        var picker = new FileSavePicker { SuggestedFileName = "MultiSync-接收二维码" };
        picker.FileTypeChoices.Add("PNG 二维码", new List<string> { ".png" });
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
        var file = await picker.PickSaveFileAsync(); if (file is not null) { await FileIO.WriteBytesAsync(file, _qrPng); Notify("二维码已保存，可直接分享这张图片。"); }
    }
    private async Task ImportQrAsync()
    {
        var picker = new FileOpenPicker();
        foreach (var type in new[] { ".png", ".jpg", ".jpeg", ".bmp" }) picker.FileTypeFilter.Add(type);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
        var file = await picker.PickSingleFileAsync(); if (file is null) return;
        await AcceptCodesAsync(await QrImages.ReadFileAsync(file));
    }
    private async Task ScanAsync()
    {
        var codes = await CameraScanner.ScanAsync(((FrameworkElement)Content).XamlRoot);
        if (codes is not null) await AcceptCodesAsync(codes);
    }
    private async Task AcceptCodesAsync(IEnumerable<string> codes)
    {
        var valid = new List<string>();
        foreach (var value in codes.Select(v => v.Trim()).Distinct()) {
            if (!value.StartsWith("msync1:", StringComparison.Ordinal)) continue;
            try { await Bridge.CallAsync(new { op = "validate_ticket", ticket = value }); valid.Add(value); }
            catch (InvalidOperationException) { }
        }
        if (valid.Count == 0) throw new InvalidOperationException("没有识别到有效的 MultiSync 接收码。请使用完整清晰的二维码。");
        if (valid.Count > 1) throw new InvalidOperationException("发现多个不同接收码，请只保留要连接的设备二维码。");
        _ticket.Password = valid[0];
        var peer = await Bridge.CallAsync(new { op = "validate_ticket", ticket = valid[0] });
        _destination.Text = "接收设备：" + peer.GetProperty("host").GetString();
        Notify("已识别接收设备。选择文件后点击发送，对方仍需确认接收。");
    }
    private async Task PasteTicketAsync()
    {
        var content = Clipboard.GetContent();
        if (!content.Contains(StandardDataFormats.Text)) throw new InvalidOperationException("剪贴板没有接收码。你也可以直接扫码连接。");
        await AcceptCodesAsync(new[] { await content.GetTextAsync() });
    }
    private async Task PickFilesAsync()
    {
        if (!_queueWritable) return;
        var picker = new FileOpenPicker(); picker.FileTypeFilter.Add("*");
        WinRT.Interop.InitializeWithWindow.Initialize(picker, WindowHandle);
        var files = await picker.PickMultipleFilesAsync();
        foreach (var file in files) {
            var record = new SendRecord { Name = file.Name };
            var directory = Path.Combine(_state, "Sources", record.Id); Directory.CreateDirectory(directory);
            record.Source = Path.Combine(directory, file.Name);
            record.Journal = Path.Combine(_state, "Journals", record.Id + ".json");
            await Task.Run(() => File.Copy(file.Path, record.Source, false));
            record.Size = new FileInfo(record.Source).Length;
            _outgoing.Add(record);
            await _history.SaveAsync(_outgoing);
        }
        RenderOutgoing(); UpdateControls();
    }
    private async Task SendQueuedAsync()
    {
        if (_active is not null || !_queueWritable) return;
        foreach (var item in _outgoing.Where(r => r.Phase == "queued" && r.PendingTicket is null))
            item.PendingTicket = _ticket.Password.Trim();
        var next = _outgoing.FirstOrDefault(r => r.Phase == "queued");
        if (next is not null) await StartSendAsync(next);
    }
    private async Task StartSendAsync(SendRecord record)
    {
        if (_active is not null || !_queueWritable) return;
        _active = record; record.Error = null; record.Phase = "hashing"; UpdateRow(record); UpdateControls();
        try {
            JsonElement result;
            if (File.Exists(record.Journal)) result = await Bridge.CallAsync(new { op = "send", journal = record.Journal });
            else {
                var invitation = record.PendingTicket ?? _ticket.Password.Trim();
                await Bridge.CallAsync(new { op = "validate_ticket", ticket = invitation });
                result = await Bridge.CallAsync(new { op = "send", source = record.Source, journal = record.Journal, ticket = invitation });
            }
            record.Handle = result.GetProperty("handle").GetString();
            await _history.SaveAsync(_outgoing);
        } catch (Exception error) {
            if (record.Handle is not null) { try { await Bridge.CallAsync(new { op = "release", handle = record.Handle }); } catch { } }
            record.Handle = null; _active = null; record.Phase = "failed"; record.Error = error.Message;
            throw;
        }
        finally { UpdateRow(record); UpdateControls(); }
    }
    private void RenderOutgoing()
    {
        _sendRows.Children.Clear(); _rows.Clear();
        if (_outgoing.Count == 0) _sendRows.Children.Add(Text("还没有发送任务。选择文件后会出现在这里。"));
        foreach (var record in _outgoing) {
            var label = Text(""); var bar = new ProgressBar { Minimum = 0, Maximum = 100, Height = 5 };
            var action = ActionButton("继续", async () => {
                if (record.Handle is not null) { await Bridge.CallAsync(new { op = "stop", handle = record.Handle }); return; }
                await StartSendAsync(record);
            });
            var item = new StackPanel { Spacing = 8 }; item.Children.Add(Text(record.Name, 17, true)); item.Children.Add(label); item.Children.Add(bar); item.Children.Add(action);
            _sendRows.Children.Add(new Border { Background = new SolidColorBrush(Colors.White), CornerRadius = new CornerRadius(14), Padding = new Thickness(18), Child = item });
            _rows[record.Id] = (label, bar, action); UpdateRow(record);
        }
    }
    private void UpdateRow(SendRecord record)
    {
        if (!_rows.TryGetValue(record.Id, out var row)) return;
        row.Text.Text = record.Label + $" · {record.Offset:N0} / {record.Size:N0} 字节" + (record.Error is null ? "" : "\n" + record.Error);
        row.Bar.Value = record.Percent; row.Bar.IsIndeterminate = record.Phase is "hashing" or "verifying";
        row.Action.Content = record.Handle is not null ? "暂停" : record.Phase == "failed" ? "重试" : "继续";
        row.Action.Visibility = record.Phase == "completed" ? Visibility.Collapsed : Visibility.Visible;
        row.Action.IsEnabled = _queueWritable && (record.Handle is not null || _active is null);
    }
    private async Task PollAsync()
    {
        if (_polling || _closing) return; _polling = true;
        try {
            if (_receiver is not null) {
                var handle = _receiver;
                var result = await Bridge.CallAsync(new { op = "poll", handle });
                foreach (var value in result.GetProperty("events").EnumerateArray()) {
                    var type = value.GetProperty("event").GetString();
                    if (type == "ready") {
                        _receivingTicket = value.GetProperty("ticket").GetString()!;
                        _qrPng = QrImages.Encode(_receivingTicket); _qr.Source = await QrImages.DisplayAsync(_qrPng);
                        _receiverLabel.Text = "接收已开启 · " + value.GetProperty("address").GetString();
                    }
                    if (type == "error") Notify(value.GetProperty("message").GetString() ?? "接收失败", true);
                }
                if (result.GetProperty("finished").GetBoolean()) {
                    await Bridge.CallAsync(new { op = "release", handle }); _receiver = null; _receivingTicket = ""; _qrPng = null; _qr.Source = null;
                    _receiverLabel.Text = "接收已停止，任务已保留。";
                }
            }
            if (_active is not null && _active.Handle is not null) {
                var record = _active; var handle = record.Handle;
                var result = await Bridge.CallAsync(new { op = "poll", handle });
                foreach (var value in result.GetProperty("events").EnumerateArray()) record.Apply(value);
                if (result.GetProperty("finished").GetBoolean()) {
                    await Bridge.CallAsync(new { op = "release", handle }); record.Handle = null; _active = null;
                    if (record.Phase is not "completed" and not "failed") record.Phase = "paused";
                    await _history.SaveAsync(_outgoing);
                    if (record.Phase == "completed") await SendQueuedAsync();
                }
                UpdateRow(record);
            }
            if (_receiver is not null || Directory.Exists(Path.Combine(_inbox, ".multisync"))) await RefreshIncomingAsync();
            foreach (var record in _outgoing) UpdateRow(record);
            UpdateControls();
        }
        catch (Exception error) { Notify(error.Message, true); }
        finally { _polling = false; }
    }
    private async Task RefreshIncomingAsync()
    {
        var inbox = _inbox;
        var result = await Bridge.CallAsync(new { op = "jobs", inbox });
        if (inbox != _inbox) return;
        var values = result.GetProperty("jobs"); var serialized = values.GetRawText();
        if (serialized == _incomingSnapshot) return; _incomingSnapshot = serialized; _receiveRows.Children.Clear();
        if (values.GetArrayLength() == 0) _receiveRows.Children.Add(Text("尚未收到文件请求。让发送设备扫描上面的二维码。"));
        foreach (var value in values.EnumerateArray()) {
            var job = value.Clone(); string id = job.GetProperty("id").GetString()!;
            string name = job.GetProperty("name").GetString()!, state = job.GetProperty("state").GetString()!;
            var box = new StackPanel { Spacing = 8 }; box.Children.Add(Text(name, 17, true));
            var label = state switch { "pending" => "等待你确认", "receiving" => "已接受 · 等待或接收数据", "committing" => "正在校验并保存", "completed" => "已接收 · 校验一致", "cancelled" => "已拒绝", _ => "未知状态，请升级应用" };
            box.Children.Add(Text(label + $" · {job.GetProperty("offset").GetInt64():N0} / {job.GetProperty("size").GetInt64():N0} 字节"));
            if (state == "pending") box.Children.Add(Row(ActionButton("接受", () => DecideAsync("approve", id), true), ActionButton("拒绝", () => DecideAsync("reject", id))));
            if (state == "completed" && job.TryGetProperty("final_name", out var final) && final.ValueKind == JsonValueKind.String) {
                var path = Path.Combine(inbox, final.GetString()!);
                box.Children.Add(Row(ActionButton("打开文件", async () => { await Launcher.LaunchFileAsync(await StorageFile.GetFileFromPathAsync(path)); }),
                    ActionButton("分享文件", async () => { _share.Show(WindowHandle, await StorageFile.GetFileFromPathAsync(path), name); })));
            }
            _receiveRows.Children.Add(new Border { Child = box, Padding = new Thickness(18), CornerRadius = new CornerRadius(14), Background = new SolidColorBrush(Colors.White) });
        }
    }
    private async Task DecideAsync(string operation, string id) { await Bridge.CallAsync(new { op = operation, inbox = _inbox, id }); await RefreshIncomingAsync(); }
    private async Task OpenInboxAsync() { Directory.CreateDirectory(_inbox); await Launcher.LaunchFolderAsync(await StorageFolder.GetFolderFromPathAsync(_inbox)); }
}
