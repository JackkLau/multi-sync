using System.Text.Json;
using MultiSync.Windows;

static void Check(bool value, string reason) { if (!value) throw new Exception(reason); }
var folder = Path.Combine(Path.GetTempPath(), "multisync-model-checks-" + Guid.NewGuid());
Directory.CreateDirectory(folder);
try
{
    var path = Path.Combine(folder, "history.json");
    var store = new HistoryStore(path);
    var record = new SendRecord { Name = "照片.jpg", Phase = "progress", Offset = 6, Size = 10, Journal = "kept.json", Source = "kept.jpg" };
    await store.SaveAsync(new[] { record });
    var recovered = store.Load().Single();
    Check(recovered.Phase == "paused" && recovered.Offset == 6 && recovered.Source == "kept.jpg" && recovered.Journal == "kept.json", "Restart must preserve bytes/source/journal and pause unfinished work");
    using (var value = JsonDocument.Parse("{\"event\":\"progress\",\"offset\":10,\"size\":10}")) recovered.Apply(value.RootElement);
    Check(recovered.Phase == "progress" && recovered.Percent == 100, "100 percent bytes must not imply completion");
    using (var value = JsonDocument.Parse("{\"event\":\"completed\",\"offset\":10,\"size\":10}")) recovered.Apply(value.RootElement);
    await store.SaveAsync(new[] { recovered });
    Check(store.Load().Single().Phase == "completed", "Confirmed completion survives restart");
    using (var value = JsonDocument.Parse("{\"event\":\"error\",\"message\":\"disk full\"}")) record.Apply(value.RootElement);
    Check(record.Phase == "failed" && record.Error == "disk full", "Failure must preserve actionable reason");
    await File.WriteAllTextAsync(path, "invalid history");
    bool rejected = false;
    try { store.Load(); } catch (JsonException) { rejected = true; }
    Check(rejected && await File.ReadAllTextAsync(path) == "invalid history", "Invalid history must not be silently overwritten");
    Check(AddressRules.IsLocal("192.168.1.4") && AddressRules.IsLocal("172.16.0.2") && !AddressRules.IsLocal("8.8.8.8") && !AddressRules.IsLocal("0.0.0.0") && !AddressRules.IsLocal("127.0.0.1"), "UI must advertise usable LAN addresses only");
    Console.WriteLine("PASS: restart, explicit completion, error preservation, corrupt-history preservation, LAN address rules");
}
finally { Directory.Delete(folder, true); }
