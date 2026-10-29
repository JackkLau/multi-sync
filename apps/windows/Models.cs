using System.Text.Json;
using System.Text.Json.Serialization;

namespace MultiSync.Windows;

public sealed class SendRecord
{
    public string Id { get; set; } = Guid.NewGuid().ToString();
    public string Source { get; set; } = "";
    public string Name { get; set; } = "";
    public string Journal { get; set; } = "";
    public string Phase { get; set; } = "queued";
    public long Offset { get; set; }
    public long Size { get; set; }
    public string? Error { get; set; }
    [JsonIgnore] public string? Handle { get; set; }
    [JsonIgnore] public string? PendingTicket { get; set; }
    [JsonIgnore] public double Percent => Size == 0 ? (Phase == "completed" ? 100 : 0) : Math.Clamp(100.0 * Offset / Size, 0, 100);
    [JsonIgnore] public string Label => Phase switch {
        "queued" => "等待发送", "hashing" => "正在检查源文件", "waiting" => "等待对方接受",
        "progress" => "正在发送", "verifying" => "对方正在校验并保存", "completed" => "已送达 · 校验一致",
        "paused" => "已暂停，可继续", "failed" => "未完成，可重试", _ => "未知状态，请升级应用"
    };
    public void Apply(JsonElement value)
    {
        var phase = value.GetProperty("event").GetString();
        if (phase is "hashing" or "waiting" or "progress" or "verifying" or "completed") Phase = phase;
        if (phase == "stopped" && Phase != "completed" && Phase != "failed") Phase = "paused";
        if (phase == "error") { Phase = "failed"; Error = value.TryGetProperty("message", out var message) ? message.GetString() : "传输失败，请重试。"; }
        if (value.TryGetProperty("offset", out var offset)) Offset = offset.GetInt64();
        if (value.TryGetProperty("size", out var size)) Size = size.GetInt64();
    }
}

public sealed class HistoryStore(string path)
{
    private readonly SemaphoreSlim _writer = new(1, 1);
    public List<SendRecord> Load()
    {
        if (!File.Exists(path)) return [];
        var records = JsonSerializer.Deserialize<List<SendRecord>>(File.ReadAllText(path))
            ?? throw new InvalidDataException("历史记录不是有效队列。原记录已保留，请先备份后修复。");
        foreach (var record in records)
            if (record.Phase != "completed" && record.Phase != "failed") record.Phase = "paused";
        return records;
    }
    public async Task SaveAsync(IEnumerable<SendRecord> records)
    {
        var bytes = JsonSerializer.SerializeToUtf8Bytes(records);
        await _writer.WaitAsync().ConfigureAwait(false);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var temporary = path + ".new";
            await File.WriteAllBytesAsync(temporary, bytes).ConfigureAwait(false);
            File.Move(temporary, path, true);
        }
        finally { _writer.Release(); }
    }
}

public static class AddressRules
{
    public static bool IsLocal(string text)
    {
        var pieces = text.Split('.');
        if (pieces.Length != 4 || pieces.Any(p => !byte.TryParse(p, out _))) return false;
        var values = pieces.Select(byte.Parse).ToArray();
        return values[0] == 10 || (values[0] == 172 && values[1] is >= 16 and <= 31)
            || (values[0] == 192 && values[1] == 168) || (values[0] == 169 && values[1] == 254);
    }
}
