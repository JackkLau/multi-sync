using System.Runtime.InteropServices;
using System.Text.Json;

namespace MultiSync.Windows;

internal static class Bridge
{
    [DllImport("multi_sync_bridge", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr multisync_call([MarshalAs(UnmanagedType.LPUTF8Str)] string request);
    [DllImport("multi_sync_bridge", CallingConvention = CallingConvention.Cdecl)]
    private static extern void multisync_free(IntPtr response);

    public static Task<JsonElement> CallAsync(object request) => Task.Run(() => Call(request));
    public static JsonElement Call(object request)
    {
        IntPtr pointer = IntPtr.Zero;
        try
        {
            pointer = multisync_call(JsonSerializer.Serialize(request));
            if (pointer == IntPtr.Zero) throw new InvalidOperationException("传输引擎没有返回结果，请重启应用。");
            using var document = JsonDocument.Parse(Marshal.PtrToStringUTF8(pointer) ?? "{}");
            var root = document.RootElement;
            if (!root.TryGetProperty("ok", out var ok) || !ok.GetBoolean())
                throw new InvalidOperationException(root.TryGetProperty("error", out var error) ? error.GetString() : "传输操作未完成。");
            return root.Clone();
        }
        catch (DllNotFoundException)
        {
            throw new InvalidOperationException("传输引擎缺失。请完整解压构建包，并保留 multi_sync_bridge.dll。");
        }
        finally { if (pointer != IntPtr.Zero) multisync_free(pointer); }
    }
}
