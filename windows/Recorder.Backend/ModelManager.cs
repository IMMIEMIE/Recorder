using System.Net;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace Recorder.Backend;

public sealed record ModelFile(string Name, long Size, string Sha256);
public sealed record ModelSpec(string Id, string Name, string Role, string Engine, string Repo, string Revision, ModelFile[] Files);
public sealed class ModelManager : IModelResolver, IModelDownloader, IDisposable
{
    private readonly string cache, endpoint;
    private readonly HttpClient http;
    private readonly SemaphoreSlim downloadGate = new(1);
    private readonly Dictionary<string, (long Size, long Mtime, string Hash)> hashes = new(StringComparer.OrdinalIgnoreCase);
    public IReadOnlyList<ModelSpec> Presets { get; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool CreateHardLink(string file, string existing, IntPtr security);
    public ModelManager(string root, string? catalogPath = null, string? hubEndpoint = null)
    {
        cache = Path.Combine(Path.GetFullPath(root), "models");
        endpoint = (hubEndpoint ?? Environment.GetEnvironmentVariable("HF_ENDPOINT") ?? "https://huggingface.co").TrimEnd('/');
        ServiceAddress.Endpoint(endpoint, "");
        var node = JsonNode.Parse(File.ReadAllText(catalogPath ?? Path.Combine(AppContext.BaseDirectory, "models.lock.json")))!.AsObject();
        if ((int?)node["schema_version"] != 1) throw new InvalidDataException("模型目录版本不兼容。");
        Presets = node["models"]!.Deserialize<ModelSpec[]>(BackendJson.Options) ?? throw new InvalidDataException("模型目录为空。");
        foreach (var spec in Presets) ValidateSpec(spec);
        http = new HttpClient(new HttpClientHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 8 }) { Timeout = Timeout.InfiniteTimeSpan };
    }
    public string ExpectedPath(ModelSpec model) => Path.Combine(Snapshot(model.Repo, model.Revision), model.Files[0].Name);
    public ModelResolution Resolve(ModelConfig config, RuntimeConfig runtime) => Resolve("asr", config.ModelId, config.Revision, config.LocalModelPath, runtime);
    public ModelResolution Resolve(TranslationConfig config, RuntimeConfig runtime) => Resolve("translator", config.ModelId, config.Revision, runtime.TranslatorPath, runtime);
    private ModelResolution Resolve(string role, string id, string revision, string local, RuntimeConfig runtime)
    {
        var preset = Presets.FirstOrDefault(p => p.Repo == id && p.Role == role);
        string engine = preset?.Engine ?? (role == "asr" ? runtime.AsrEngine : runtime.TranslatorEngine);
        if (local.Length > 0)
        {
            string path = Path.GetFullPath(local);
            if (Directory.Exists(path))
            {
                string filename = role == "asr" ? runtime.AsrFilename : runtime.TranslatorFilename;
                if (filename.Length > 0) path = SafeFile(path, filename);
                else if (preset != null) path = SafeFile(path, preset.Files[0].Name);
                else
                {
                    var localFiles = Directory.EnumerateFiles(path).Where(p => engine == "whisper" ? p.EndsWith(".bin", StringComparison.OrdinalIgnoreCase) : p.EndsWith(".gguf", StringComparison.OrdinalIgnoreCase) && !Path.GetFileName(p).StartsWith("mmproj", StringComparison.OrdinalIgnoreCase)).ToArray();
                    if (localFiles.Length != 1) throw new InvalidDataException("本地目录包含多个或没有兼容模型，请选择具体模型文件。"); path = localFiles[0];
                }
            }
            string projector = "";
            if (engine == "qwen")
            {
                projector = runtime.AsrProjectorPath;
                if (projector.Length == 0)
                {
                    var directory = Path.GetDirectoryName(path)!;
                    if (preset?.Files.Length > 1) projector = SafeFile(directory, preset.Files[1].Name);
                    else { var files = Directory.GetFiles(directory, "mmproj*.gguf"); if (files.Length != 1) throw new InvalidDataException("请选择与 Qwen 模型配套的音频编码文件。"); projector = files[0]; }
                }
            }
            var result = new EngineModel(engine, path, projector, runtime.Device); ValidateModel(result); return new(result, revision);
        }
        ModelAddress.ValidateId(id);
        var repoRoot = Repository(id);
        IEnumerable<string> candidates;
        if (revision.Length > 0) { ValidateRevision(revision); candidates = [Snapshot(id, revision)]; }
        else
        {
            var reference = Path.Combine(repoRoot, "refs", "main"); var list = new List<string>();
            if (File.Exists(reference)) { var sha = File.ReadAllText(reference).Trim(); if (Regex.IsMatch(sha, "^[a-f0-9]{40}$")) list.Add(Snapshot(id, sha)); }
            var snapshots = Path.Combine(repoRoot, "snapshots");
            if (Directory.Exists(snapshots)) list.AddRange(Directory.GetDirectories(snapshots).Where(d => Regex.IsMatch(Path.GetFileName(d), "^[a-f0-9]{40}$")).OrderByDescending(Directory.GetLastWriteTimeUtc));
            candidates = list.Distinct(StringComparer.OrdinalIgnoreCase);
        }
        foreach (var directory in candidates)
        {
            try
            {
                var manifest = Path.Combine(directory, "recorder-manifest.json");
                ModelSpec spec = File.Exists(manifest) ? JsonSerializer.Deserialize<ModelSpec>(File.ReadAllText(manifest), BackendJson.Options)! : preset ?? throw new InvalidDataException("缓存缺少模型清单。");
                ValidateSpec(spec);
                if (spec.Repo != id || spec.Role != role || spec.Revision != Path.GetFileName(directory)) throw new InvalidDataException("缓存清单与模型版本不匹配。");
                foreach (var file in spec.Files) VerifyFile(SafeFile(directory, file.Name), file);
                var model = new EngineModel(spec.Engine, SafeFile(directory, spec.Files[0].Name), spec.Engine == "qwen" ? SafeFile(directory, spec.Files[1].Name) : "", runtime.Device);
                ValidateModel(model); return new(model, spec.Revision);
            }
            catch when (revision.Length == 0) { }
        }
        throw new FileNotFoundException(revision.Length > 0 ? "指定版本的模型未缓存或不完整，请下载该版本。" : "未找到完整的本地模型，请先下载或选择本地文件。");
    }
    public async Task<ModelResolution> DownloadAsync(string role, string modelId, string revision, RuntimeConfig runtime, IProgress<(string Detail, long Completed, long Total)> progress, CancellationToken ct)
    {
        await downloadGate.WaitAsync(ct);
        try
        {
            var preset = Presets.FirstOrDefault(p => p.Role == role && p.Repo == modelId);
            ModelSpec spec;
            if (preset != null && (revision.Length == 0 || revision == preset.Revision)) spec = preset;
            else spec = await RemoteSpecAsync(role, modelId, revision, runtime, ct);
            ValidateSpec(spec); long total = spec.Files.Sum(f => f.Size), complete = 0;
            var repo = Repository(spec.Repo); var blobs = Path.Combine(repo, "blobs"); Directory.CreateDirectory(blobs);
            foreach (var file in spec.Files)
            {
                ct.ThrowIfCancellationRequested(); var blob = Path.Combine(blobs, file.Sha256);
                bool valid = false;
                if (File.Exists(blob)) { try { VerifyFile(blob, file); valid = true; } catch (InvalidDataException) { File.Delete(blob); } }
                if (!valid) await DownloadFileAsync(spec, file, blob, complete, total, progress, ct);
                complete += file.Size; progress.Report((file.Name, complete, total));
            }
            ct.ThrowIfCancellationRequested();
            var snapshot = Snapshot(spec.Repo, spec.Revision); Directory.CreateDirectory(snapshot);
            foreach (var file in spec.Files)
            {
                var target = SafeFile(snapshot, file.Name); Directory.CreateDirectory(Path.GetDirectoryName(target)!);
                if (File.Exists(target)) { try { VerifyFile(target, file); continue; } catch (InvalidDataException) { } }
                var temp = target + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try { var blob = Path.Combine(blobs, file.Sha256); if (!CreateHardLink(temp, blob, IntPtr.Zero)) File.Copy(blob, temp); File.Move(temp, target, true); }
                finally { if (File.Exists(temp)) File.Delete(temp); }
            }
            var manifest = Path.Combine(snapshot, "recorder-manifest.json");
            File.WriteAllText(manifest + ".tmp", JsonSerializer.Serialize(spec, BackendJson.Options)); File.Move(manifest + ".tmp", manifest, true);
            var model = new EngineModel(spec.Engine, SafeFile(snapshot, spec.Files[0].Name), spec.Engine == "qwen" ? SafeFile(snapshot, spec.Files[1].Name) : "", runtime.Device);
            ValidateModel(model); ct.ThrowIfCancellationRequested();
            if (revision.Length == 0)
            {
                var refs = Path.Combine(repo, "refs"); Directory.CreateDirectory(refs); var main = Path.Combine(refs, "main");
                File.WriteAllText(main + ".tmp", spec.Revision); File.Move(main + ".tmp", main, true);
            }
            return new(model, spec.Revision);
        }
        finally { downloadGate.Release(); }
    }
    public async Task<IReadOnlyList<string>> ListFilesAsync(string modelId, string revision, CancellationToken ct)
    {
        ModelAddress.ValidateId(modelId); if (revision.Length > 0) ValidateRevision(revision);
        var metadata = await MetadataAsync(modelId, revision.Length == 0 ? "main" : revision, ct);
        return metadata["siblings"]!.AsArray().Select(n => (string)n!["rfilename"]!).Where(f => f.EndsWith(".gguf", StringComparison.OrdinalIgnoreCase) || f.EndsWith(".bin", StringComparison.OrdinalIgnoreCase)).ToArray();
    }
    private async Task<JsonObject> MetadataAsync(string id, string revision, CancellationToken ct)
    {
        using var response = await http.GetAsync(endpoint + "/api/models/" + id + "/revision/" + revision + "?blobs=true", ct);
        response.EnsureSuccessStatusCode(); var raw = await response.Content.ReadAsByteArrayAsync(ct);
        if (raw.Length > 8 * 1024 * 1024) throw new InvalidDataException("模型文件清单过大。");
        return JsonNode.Parse(raw)!.AsObject();
    }
    private async Task<ModelSpec> RemoteSpecAsync(string role, string id, string revision, RuntimeConfig options, CancellationToken ct)
    {
        ModelAddress.ValidateId(id); if (revision.Length > 0) ValidateRevision(revision);
        var metadata = await MetadataAsync(id, revision.Length == 0 ? "main" : revision, ct);
        string sha = (string)metadata["sha"]!; ValidateRevision(sha);
        var names = new List<string> { role == "asr" ? options.AsrFilename : options.TranslatorFilename };
        string engine = role == "asr" ? options.AsrEngine : options.TranslatorEngine;
        if (engine == "qwen") names.Add(options.AsrProjectorFilename);
        if (names.Any(string.IsNullOrWhiteSpace)) throw new InvalidDataException("自定义模型请先从仓库文件列表选择模型文件及配套音频编码文件。");
        var files = names.Select(name =>
        {
            var entry = metadata["siblings"]!.AsArray().FirstOrDefault(n => (string?)n!["rfilename"] == name) ?? throw new InvalidDataException("模型仓库缺少文件：" + name);
            return new ModelFile(name, (long)entry["size"]!, (string?)entry["lfs"]?["sha256"] ?? throw new InvalidDataException("模型文件缺少 SHA256 信息。"));
        }).ToArray();
        return new(id, id, role, engine, id, sha, files);
    }
    private async Task DownloadFileAsync(ModelSpec spec, ModelFile file, string blob, long complete, long total, IProgress<(string Detail, long Completed, long Total)> progress, CancellationToken ct)
    {
        var partial = blob + ".incomplete"; long offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
        if (offset > file.Size) { File.Delete(partial); offset = 0; }
        if (offset == file.Size)
        {
            try { VerifyFile(partial, file); ct.ThrowIfCancellationRequested(); File.Move(partial, blob, true); return; }
            catch (InvalidDataException) { File.Delete(partial); offset = 0; }
        }
        using var request = new HttpRequestMessage(HttpMethod.Get, endpoint + "/" + spec.Repo + "/resolve/" + spec.Revision + "/" + string.Join('/', file.Name.Split('/').Select(Uri.EscapeDataString)));
        if (offset > 0) request.Headers.Range = new RangeHeaderValue(offset, null);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct); response.EnsureSuccessStatusCode();
        if (response.StatusCode == HttpStatusCode.PartialContent)
        { if (response.Content.Headers.ContentRange?.From != offset || response.Content.Headers.ContentRange?.Length != file.Size) throw new InvalidDataException("模型下载断点响应无效。"); }
        else offset = 0;
        await using (var source = await response.Content.ReadAsStreamAsync(ct))
        await using (var target = new FileStream(partial, offset > 0 ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.Read, 131072, true))
        {
            var buffer = new byte[131072]; int n; long received = offset;
            while ((n = await source.ReadAsync(buffer, ct)) > 0)
            {
                received += n; if (received > file.Size) throw new InvalidDataException("模型下载大小超出清单。");
                await target.WriteAsync(buffer.AsMemory(0, n), ct); progress.Report((file.Name, complete + received, total));
            }
            await target.FlushAsync(ct);
        }
        if (new FileInfo(partial).Length < file.Size) throw new IOException("模型下载中断，已保留断点，请重试。");
        try { VerifyFile(partial, file); }
        catch (InvalidDataException) { File.Delete(partial); throw; }
        ct.ThrowIfCancellationRequested(); File.Move(partial, blob, true);
    }
    private string Repository(string id) { ModelAddress.ValidateId(id); return Path.Combine(cache, "models--" + id.Replace("/", "--")); }
    private string Snapshot(string id, string revision) { ValidateRevision(revision); return Path.Combine(Repository(id), "snapshots", revision); }
    private static string SafeFile(string root, string relative)
    {
        if (relative.Length == 0 || Path.IsPathRooted(relative) || relative.Contains('\\') || relative.Split('/').Any(p => p is "" or "." or ".." || p.EndsWith('.') || p.EndsWith(' ') || p.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)) throw new InvalidDataException("模型文件名无效。");
        var path = Path.GetFullPath(Path.Combine(root, relative));
        if (!path.StartsWith(Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("模型路径超出缓存目录。");
        return path;
    }
    private static void ValidateRevision(string revision) { if (!Regex.IsMatch(revision, "^[a-f0-9]{40}$")) throw new InvalidDataException("模型版本须为 40 位提交 SHA。"); }
    private static void ValidateSpec(ModelSpec model)
    {
        ModelAddress.ValidateId(model.Repo); ValidateRevision(model.Revision);
        if (model.Role is not ("asr" or "translator") || model.Files.Length != (model.Engine == "qwen" ? 2 : 1)) throw new InvalidDataException("模型角色或配套文件清单无效。");
        if (!(model.Role == "asr" ? new[] { "qwen", "whisper" } : new[] { "qwen2", "qwen3", "hunyuan", "llama", "mistral" }).Contains(model.Engine)) throw new InvalidDataException("不支持的本地模型架构。");
        foreach (var file in model.Files)
        { SafeFile(Path.GetTempPath(), file.Name); if (file.Size < 4 || !Regex.IsMatch(file.Sha256, "^[a-f0-9]{64}$") || !(file.Name.EndsWith(".gguf", StringComparison.OrdinalIgnoreCase) || model.Engine == "whisper" && file.Name.EndsWith(".bin", StringComparison.OrdinalIgnoreCase))) throw new InvalidDataException("模型文件格式、大小或哈希无效。"); }
    }
    private void VerifyFile(string path, ModelFile expected)
    {
        var info = new FileInfo(path); if (!info.Exists || info.Length != expected.Size) throw new InvalidDataException("模型文件不完整：" + expected.Name);
        string hash;
        lock (hashes)
        {
            if (hashes.TryGetValue(path, out var cached) && cached.Size == info.Length && cached.Mtime == info.LastWriteTimeUtc.Ticks) hash = cached.Hash;
            else { using var source = File.OpenRead(path); hash = Convert.ToHexString(SHA256.HashData(source)).ToLowerInvariant(); hashes[path] = (info.Length, info.LastWriteTimeUtc.Ticks, hash); }
        }
        if (hash != expected.Sha256) throw new InvalidDataException("模型 SHA256 校验失败：" + expected.Name);
    }
    private static void ValidateModel(EngineModel model)
    {
        if (!File.Exists(model.Path)) throw new FileNotFoundException("模型文件不存在。", model.Path);
        using (var file = new BinaryReader(File.OpenRead(model.Path)))
        {
            if (file.BaseStream.Length < 4 || file.ReadUInt32() != (model.Engine == "whisper" ? 0x67676d6cu : 0x46554747u)) throw new InvalidDataException("请选择 Windows 兼容的 GGUF／Whisper GGML 权重；MLX 和原始 Transformers 权重不能直接加载。");
        }
        if (model.Engine != "whisper")
        {
            var architecture = GgufArchitecture(model.Path);
            var supported = model.Engine switch { "qwen" => new[] { "qwen3vl", "qwen3" }, "qwen2" => ["qwen2"], "qwen3" => ["qwen3"], "hunyuan" => ["hunyuan-dense"], "llama" or "mistral" => ["llama", "mistral"], _ => Array.Empty<string>() };
            if (!supported.Contains(architecture)) throw new InvalidDataException("模型架构与所选引擎不匹配：" + architecture);
        }
        if (model.Engine == "qwen")
        {
            if (!File.Exists(model.Projector)) throw new FileNotFoundException("Qwen 音频编码文件缺失。", model.Projector);
            using var file = new BinaryReader(File.OpenRead(model.Projector)); if (file.BaseStream.Length < 4 || file.ReadUInt32() != 0x46554747u) throw new InvalidDataException("Qwen 音频编码文件格式无效。");
        }
    }
    private static string GgufArchitecture(string path)
    {
        using var input = new BinaryReader(File.OpenRead(path), new UTF8Encoding(false, true));
        input.ReadUInt32(); uint version = input.ReadUInt32(); if (version is not (2 or 3)) throw new InvalidDataException("不支持的 GGUF 版本。");
        input.ReadUInt64(); ulong count = input.ReadUInt64(); if (count > 100000) throw new InvalidDataException("GGUF 元数据数量异常。");
        void Skip(ulong bytes) { if (bytes > (ulong)(input.BaseStream.Length - input.BaseStream.Position)) throw new InvalidDataException("GGUF 元数据不完整。"); input.BaseStream.Seek((long)bytes, SeekOrigin.Current); }
        string Text()
        {
            ulong length = input.ReadUInt64(); if (length > 65536 || length > (ulong)(input.BaseStream.Length - input.BaseStream.Position)) throw new InvalidDataException("GGUF 文本字段过长或不完整。");
            return new UTF8Encoding(false, true).GetString(input.ReadBytes((int)length));
        }
        void Value(uint type, int depth)
        {
            int size = type switch { 0 or 1 or 7 => 1, 2 or 3 => 2, 4 or 5 or 6 => 4, 10 or 11 or 12 => 8, _ => 0 };
            if (size > 0) { Skip((ulong)size); return; }
            if (type == 8) { Skip(input.ReadUInt64()); return; }
            if (type != 9 || depth > 1) throw new InvalidDataException("GGUF 元数据类型无效。");
            uint element = input.ReadUInt32(); ulong items = input.ReadUInt64(); if (items > 10000000) throw new InvalidDataException("GGUF 数组过长。");
            for (ulong i = 0; i < items; ++i) Value(element, depth + 1);
        }
        for (ulong i = 0; i < count; ++i)
        {
            string key = Text(); uint type = input.ReadUInt32();
            if (key == "general.architecture") { if (type != 8) throw new InvalidDataException("GGUF 模型架构字段无效。"); return Text(); }
            Value(type, 0);
        }
        throw new InvalidDataException("GGUF 缺少模型架构。");
    }
    public void Dispose() { http.Dispose(); downloadGate.Dispose(); }
}
