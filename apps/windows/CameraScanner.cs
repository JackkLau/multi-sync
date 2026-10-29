using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Media.Capture;
using Windows.Media.MediaProperties;
using Windows.Storage.Streams;

namespace MultiSync.Windows;

internal static class CameraScanner
{
    public static async Task<string[]?> ScanAsync(XamlRoot root)
    {
        var status = new TextBlock { Text = "点击开启摄像头，再将接收二维码放入画面。画面仅在本机识别。", TextWrapping = TextWrapping.Wrap };
        var preview = new Image { Height = 280, Stretch = Microsoft.UI.Xaml.Media.Stretch.Uniform };
        var content = new StackPanel { Spacing = 14, Width = 420 };
        content.Children.Add(status); content.Children.Add(preview);
        var dialog = new ContentDialog { XamlRoot = root, Title = "扫描接收二维码", Content = content,
            PrimaryButtonText = "开启摄像头", CloseButtonText = "取消", DefaultButton = ContentDialogButton.Close };
        using var cancellation = new CancellationTokenSource();
        Task? scanning = null;
        string[]? found = null;
        dialog.PrimaryButtonClick += (_, args) => {
            args.Cancel = true;
            if (scanning is { IsCompleted: false }) return;
            dialog.IsPrimaryButtonEnabled = false;
            scanning = CaptureAsync();
        };
        dialog.Closing += (_, _) => cancellation.Cancel();
        await dialog.ShowAsync();
        if (scanning is not null) await scanning;
        return found;

        async Task CaptureAsync()
        {
            using var capture = new MediaCapture();
            try
            {
                await capture.InitializeAsync(new MediaCaptureInitializationSettings { StreamingCaptureMode = StreamingCaptureMode.Video, MemoryPreference = MediaCaptureMemoryPreference.Cpu });
                if (cancellation.IsCancellationRequested) return;
                status.Text = "正在扫描，请保持二维码完整、清晰。";
                while (!cancellation.IsCancellationRequested)
                {
                    using var stream = new InMemoryRandomAccessStream();
                    await capture.CapturePhotoToStreamAsync(ImageEncodingProperties.CreateJpeg(), stream);
                    if (cancellation.IsCancellationRequested) return;
                    stream.Seek(0);
                    var image = new Microsoft.UI.Xaml.Media.Imaging.BitmapImage();
                    await image.SetSourceAsync(stream);
                    preview.Source = image;
                    var values = await QrImages.ReadAsync(stream);
                    if (values.Any(v => v.StartsWith("msync1:", StringComparison.Ordinal)))
                    {
                        found = values; dialog.Hide(); return;
                    }
                    await Task.Delay(350, cancellation.Token);
                }
            }
            catch (OperationCanceledException) { }
            catch (Exception error)
            {
                if (cancellation.IsCancellationRequested) return;
                status.Text = "摄像头不可用。请检查 Windows 相机隐私设置或关闭占用相机的应用；也可以从二维码图片识别。\n" + error.Message;
                dialog.IsPrimaryButtonEnabled = true;
            }
        }
    }
}
