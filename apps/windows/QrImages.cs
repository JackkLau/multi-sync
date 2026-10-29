using Microsoft.UI.Xaml.Media.Imaging;
using QRCoder;
using Windows.Graphics.Imaging;
using Windows.Storage;
using Windows.Storage.Streams;
using ZXing;
using ZXing.Common;

namespace MultiSync.Windows;

internal static class QrImages
{
    public static byte[] Encode(string ticket)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(ticket, QRCodeGenerator.ECCLevel.M);
        using var png = new PngByteQRCode(data);
        return png.GetGraphic(6); // includes the standard four-module quiet zone
    }
    public static async Task<BitmapImage> DisplayAsync(byte[] png)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0))) { writer.WriteBytes(png); await writer.StoreAsync(); writer.DetachStream(); }
        stream.Seek(0);
        var image = new BitmapImage();
        await image.SetSourceAsync(stream);
        return image;
    }
    public static async Task<string[]> ReadFileAsync(StorageFile file)
    {
        if ((await file.GetBasicPropertiesAsync()).Size > 20 * 1024 * 1024)
            throw new InvalidOperationException("图片超过 20 MB，请选择二维码截图。");
        using var stream = await file.OpenReadAsync();
        return await ReadAsync(stream);
    }
    public static async Task<string[]> ReadAsync(IRandomAccessStream stream)
    {
        stream.Seek(0);
        var decoder = await BitmapDecoder.CreateAsync(stream);
        double ratio = Math.Min(1, 2048.0 / Math.Max(decoder.PixelWidth, decoder.PixelHeight));
        var transform = new BitmapTransform { ScaledWidth = Math.Max(1, (uint)(decoder.PixelWidth * ratio)), ScaledHeight = Math.Max(1, (uint)(decoder.PixelHeight * ratio)) };
        var provider = await decoder.GetPixelDataAsync(BitmapPixelFormat.Bgra8, BitmapAlphaMode.Ignore,
            transform, ExifOrientationMode.IgnoreExifOrientation, ColorManagementMode.DoNotColorManage);
        byte[] pixels = provider.DetachPixelData();
        return await Task.Run(() => {
            var reader = new BarcodeReaderGeneric { AutoRotate = true,
                Options = new DecodingOptions { TryHarder = true, PossibleFormats = new List<BarcodeFormat> { BarcodeFormat.QR_CODE } } };
            var values = reader.DecodeMultiple(pixels, (int)transform.ScaledWidth, (int)transform.ScaledHeight, RGBLuminanceSource.BitmapFormat.BGRA32);
            return values?.Select(v => v.Text).Distinct().ToArray() ?? [];
        });
    }
}
