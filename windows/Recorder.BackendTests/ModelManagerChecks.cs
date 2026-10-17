using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using Recorder.Backend;

static class ModelManagerChecks
{
    public static async Task Run(string root, string workspace, Action<bool, string> check, Action<Action, string> reject)
    {
        await using var hub = new HubFixture();
        var catalog = Path.Combine(root, "test-models.json");
        var spec = new ModelSpec("test", "fixture", "translator", "qwen3", "tests/model", HubFixture.Revision, [new("model.gguf", hub.Data.Length, hub.Hash)]);
        File.WriteAllText(catalog, new JsonObject { ["schema_version"] = 1, ["models"] = JsonSerializer.SerializeToNode(new[] { spec }, BackendJson.Options) }.ToJsonString());
        var cacheRoot = Path.Combine(root, "hub-cache"); var options = new RuntimeConfig { TranslatorFilename = "model.gguf" };
        var progress = new InlineProgress<(string Detail, long Completed, long Total)>(_ => { });
        using (var manager = new ModelManager(cacheRoot, catalog, hub.Endpoint))
        {
            var partial = Path.Combine(cacheRoot, "models/models--tests--model/blobs/" + hub.Hash + ".incomplete"); Directory.CreateDirectory(Path.GetDirectoryName(partial)!);
            File.WriteAllBytes(partial, hub.Data[..12345]);
            var downloaded = await manager.DownloadAsync("translator", spec.Repo, "", options, progress, default);
            check(hub.Ranges.Contains(12345) && File.ReadAllBytes(downloaded.Model.Path).SequenceEqual(hub.Data), "model download resumes Range and verifies SHA256");
            check(File.Exists(Path.Combine(cacheRoot, "models/models--tests--model/refs/main")), "unversioned download publishes refs/main");
            var cached = manager.Resolve(new TranslationConfig { ModelId = spec.Repo }, options);
            check(cached.Revision == HubFixture.Revision && cached.Model.Path == downloaded.Model.Path, "verified cache resolves without network");
            reject(() => manager.Resolve(new TranslationConfig { ModelId = spec.Repo, Revision = new string('b', 40) }, options), "explicit missing revision never falls back");
            File.AppendAllText(cached.Model.Path, "corrupt");
            reject(() => manager.Resolve(new TranslationConfig { ModelId = spec.Repo, Revision = HubFixture.Revision }, options), "corrupted cached weight rejected");
            var repaired = await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, progress, default);
            check(File.ReadAllBytes(repaired.Model.Path).SequenceEqual(hub.Data), "corrupted cache repaired from verified blob download");
            var files = await manager.ListFilesAsync("tests/custom", "", default);
            check(files.SequenceEqual(new[] { "model.gguf" }), "custom repository exposes selectable model files");
            var custom = await manager.DownloadAsync("translator", "tests/custom", "", options, progress, default);
            check(custom.Revision == HubFixture.Revision && File.Exists(custom.Model.Path), "custom download pins resolved commit and file hash");
        }
        using (var manager = new ModelManager(Path.Combine(root, "ignore-range"), catalog, hub.Endpoint))
        {
            var partial = Path.Combine(root, "ignore-range/models/models--tests--model/blobs/" + hub.Hash + ".incomplete"); Directory.CreateDirectory(Path.GetDirectoryName(partial)!); File.WriteAllBytes(partial, hub.Data[..100]);
            hub.IgnoreRange = true;
            var result = await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, progress, default);
            check(File.ReadAllBytes(result.Model.Path).SequenceEqual(hub.Data), "server ignoring Range restarts file instead of appending duplicate bytes"); hub.IgnoreRange = false;
        }
        using (var manager = new ModelManager(Path.Combine(root, "cancel-download"), catalog, hub.Endpoint))
        {
            hub.DelayMs = 5; using var cancellation = new CancellationTokenSource(); bool cancelled = false;
            try { await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, new InlineProgress<(string Detail, long Completed, long Total)>(p => { if (p.Completed > 32768) cancellation.Cancel(); }), cancellation.Token); }
            catch (OperationCanceledException) { cancelled = true; }
            var partial = Path.Combine(root, "cancel-download/models/models--tests--model/blobs/" + hub.Hash + ".incomplete");
            check(cancelled && File.Exists(partial) && new FileInfo(partial).Length > 0, "cancelled model download retains resumable partial");
            hub.DelayMs = 0; var result = await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, progress, default);
            check(File.Exists(result.Model.Path), "cancelled download resumes successfully");
        }
        using (var manager = new ModelManager(Path.Combine(root, "bad-hash"), catalog, hub.Endpoint))
        {
            hub.Corrupt = true; bool rejected = false;
            try { await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, progress, default); } catch (InvalidDataException) { rejected = true; }
            check(rejected && !Directory.Exists(Path.Combine(root, "bad-hash/models/models--tests--model/snapshots")), "bad SHA256 never publishes snapshot"); hub.Corrupt = false;
        }
        using (var manager = new ModelManager(Path.Combine(root, "complete-partial"), catalog, hub.Endpoint))
        {
            var partial = Path.Combine(root, "complete-partial/models/models--tests--model/blobs/" + hub.Hash + ".incomplete"); Directory.CreateDirectory(Path.GetDirectoryName(partial)!); File.WriteAllBytes(partial, hub.Data);
            int before = hub.Downloads; await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, progress, default);
            check(hub.Downloads == before, "complete partial is verified locally without invalid end-of-file Range request");
        }
        using (var manager = new ModelManager(Path.Combine(root, "explicit"), catalog, hub.Endpoint))
        {
            await manager.DownloadAsync("translator", spec.Repo, HubFixture.Revision, options, progress, default);
            check(!File.Exists(Path.Combine(root, "explicit/models/models--tests--model/refs/main")), "explicit revision does not rewrite refs/main");
            var raw = Path.Combine(root, "raw.bin"); File.WriteAllText(raw, "not a GGUF model");
            reject(() => manager.Resolve(new ModelConfig { ModelId = "local/custom", LocalModelPath = raw }, new RuntimeConfig()), "MLX and raw checkpoint formats rejected before inference");
        }
        var hostile = spec with { Files = [new("../escape.gguf", hub.Data.Length, hub.Hash)] };
        var badCatalog = Path.Combine(root, "hostile-models.json"); File.WriteAllText(badCatalog, new JsonObject { ["schema_version"] = 1, ["models"] = JsonSerializer.SerializeToNode(new[] { hostile }, BackendJson.Options) }.ToJsonString());
        reject(() => { using var _ = new ModelManager(root, badCatalog, hub.Endpoint); }, "model manifest traversal rejected");
        using (var manager = new ModelManager(Path.Combine(root, "real-format"), Path.Combine(workspace, "windows/models.lock.json")))
        {
            foreach (var model in manager.Presets)
            {
                var directory = Path.Combine(workspace, ".bootstrap/verification-models", model.Id);
                if (!Directory.Exists(directory)) continue;
                var runtime = new RuntimeConfig { AsrEngine = model.Engine is "qwen" or "whisper" ? model.Engine : "qwen", TranslatorPath = Path.Combine(directory, model.Files[0].Name), AsrProjectorPath = model.Files.Length > 1 ? Path.Combine(directory, model.Files[1].Name) : "" };
                var result = model.Role == "asr" ? manager.Resolve(new ModelConfig { ModelId = model.Repo, LocalModelPath = Path.Combine(directory, model.Files[0].Name) }, runtime) : manager.Resolve(new TranslationConfig { ModelId = model.Repo }, runtime);
                check(result.Model.Engine == model.Engine, "real model format validated: " + model.Id);
            }
        }
    }
    private sealed class InlineProgress<T>(Action<T> action) : IProgress<T> { public void Report(T value) => action(value); }
    private sealed class HubFixture : IAsyncDisposable
    {
        public const string Revision = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
        public byte[] Data { get; } = new byte[512 * 1024];
        public string Hash { get; }
        public string Endpoint { get; }
        public bool IgnoreRange, Corrupt;
        public int DelayMs, Downloads;
        public List<long> Ranges = new();
        private readonly TcpListener listener = new(IPAddress.Loopback, 0);
        private readonly CancellationTokenSource lifetime = new();
        private readonly Task accept;
        private readonly List<Task> clients = new();
        public HubFixture()
        {
            new Random(42).NextBytes(Data);
            using (var stream = new MemoryStream(Data)) using (var writer = new BinaryWriter(stream, Encoding.UTF8, true))
            {
                writer.Write(0x46554747u); writer.Write(3u); writer.Write(1UL); writer.Write(1UL);
                var key = Encoding.UTF8.GetBytes("general.architecture"); writer.Write((ulong)key.Length); writer.Write(key); writer.Write(8u); writer.Write(5UL); writer.Write(Encoding.UTF8.GetBytes("qwen3"));
            }
            Hash = Convert.ToHexString(SHA256.HashData(Data)).ToLowerInvariant(); listener.Start(); Endpoint = "http://127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port; accept = AcceptAsync();
        }
        private async Task AcceptAsync()
        {
            try { while (!lifetime.IsCancellationRequested) { var client = await listener.AcceptTcpClientAsync(lifetime.Token); lock (clients) clients.Add(Handle(client)); } }
            catch (OperationCanceledException) { } catch (SocketException) when (lifetime.IsCancellationRequested) { }
        }
        private async Task Handle(TcpClient client)
        {
            using (client)
            try
            {
                var stream = client.GetStream(); using var reader = new StreamReader(stream, Encoding.ASCII, false, 4096, true);
                var request = await reader.ReadLineAsync(lifetime.Token); var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                for (;;) { var line = await reader.ReadLineAsync(lifetime.Token); if (string.IsNullOrEmpty(line)) break; int colon = line.IndexOf(':'); if (colon > 0) headers[line[..colon]] = line[(colon + 1)..].Trim(); }
                byte[] body; long offset = 0; string extra = "", status = "200 OK";
                if (request!.Contains("/api/models/")) body = Encoding.UTF8.GetBytes(new JsonObject { ["sha"] = Revision, ["siblings"] = new JsonArray(new JsonObject { ["rfilename"] = "model.gguf", ["size"] = Data.Length, ["lfs"] = new JsonObject { ["sha256"] = Hash } }) }.ToJsonString());
                else
                {
                    Interlocked.Increment(ref Downloads);
                    if (headers.TryGetValue("Range", out var range)) { offset = long.Parse(range[6..].TrimEnd('-')); lock (Ranges) Ranges.Add(offset); }
                    if (IgnoreRange) offset = 0;
                    if (offset > 0) { status = "206 Partial Content"; extra = $"Content-Range: bytes {offset}-{Data.Length - 1}/{Data.Length}\r\n"; }
                    body = Data[(int)offset..].ToArray(); if (Corrupt) body[^1] ^= 1;
                }
                await stream.WriteAsync(Encoding.ASCII.GetBytes($"HTTP/1.1 {status}\r\nContent-Length: {body.Length}\r\n{extra}Connection: close\r\n\r\n"), lifetime.Token);
                for (int p = 0; p < body.Length; p += 8192) { await stream.WriteAsync(body.AsMemory(p, Math.Min(8192, body.Length - p)), lifetime.Token); if (DelayMs > 0) await Task.Delay(DelayMs, lifetime.Token); }
            }
            catch (Exception ex) when (ex is IOException or SocketException or OperationCanceledException) { }
        }
        public async ValueTask DisposeAsync() { lifetime.Cancel(); listener.Stop(); await accept; Task[] pending; lock (clients) pending = clients.ToArray(); await Task.WhenAll(pending); lifetime.Dispose(); }
    }
}
