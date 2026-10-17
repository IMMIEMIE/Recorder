using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Recorder.Backend;

public sealed record CudaRuntimeFile(string Entry, string Name, long Size, string Sha256);
public sealed record CudaRuntimePackage(string Name, string Version, string Path, long Size, string Sha256, CudaRuntimeFile[] Files);
public sealed record CudaRuntimeLock(int SchemaVersion, string Id, string Description, string[] Mirrors, CudaRuntimePackage[] Packages);

/// <summary>
/// The CUDA runtime and cuBLAS (~790 MB) are not shipped in the installer. They are fetched on demand from NVIDIA's
/// official PyPI wheels pinned in cuda-runtime.lock.json, verified by SHA256 per wheel and per extracted file, and kept
/// under &lt;data root&gt;/runtime/&lt;id&gt;. The CUDA worker receives that directory as an extra DLL directory.
/// </summary>
public sealed class CudaRuntime : IDisposable
{
    private readonly string dataRoot, bundledDirectory;
    private readonly HttpClient http;
    private readonly SemaphoreSlim gate = new(1);
    public CudaRuntimeLock Lock { get; }
    public CudaRuntime(string dataRoot, string appRuntimeRoot, string? lockPath = null, HttpMessageHandler? handler = null)
    {
        this.dataRoot = Path.GetFullPath(dataRoot); bundledDirectory = Path.Combine(Path.GetFullPath(appRuntimeRoot), "cuda");
        var node = JsonNode.Parse(File.ReadAllText(lockPath ?? Path.Combine(AppContext.BaseDirectory, "cuda-runtime.lock.json")))!.AsObject();
        Lock = node.Deserialize<CudaRuntimeLock>(BackendJson.Options) ?? throw new InvalidDataException("CUDA 运行库清单为空。");
        if (Lock.SchemaVersion != 1 || !System.Text.RegularExpressions.Regex.IsMatch(Lock.Id, "^[A-Za-z0-9][A-Za-z0-9._-]*$") || Lock.Packages.Length == 0) throw new InvalidDataException("CUDA 运行库清单无效。");
        foreach (var package in Lock.Packages)
        {
            if (package.Path.Contains("..") || package.Path.StartsWith('/') || package.Size <= 0 || package.Sha256.Length != 64) throw new InvalidDataException("CUDA 运行库清单包含无效条目。");
            foreach (var file in package.Files) if (Path.GetFileName(file.Name) != file.Name || file.Sha256.Length != 64 || file.Size <= 0) throw new InvalidDataException("CUDA 运行库清单包含无效文件名。");
        }
        http = new HttpClient(handler ?? new HttpClientHandler { AllowAutoRedirect = true, MaxAutomaticRedirections = 8 }) { Timeout = Timeout.InfiniteTimeSpan };
    }
    public string InstallDirectory => Path.Combine(dataRoot, "runtime", Lock.Id);
    public long DownloadSize => Lock.Packages.Sum(p => p.Size);
    private IEnumerable<CudaRuntimeFile> Libraries => Lock.Packages.SelectMany(p => p.Files).Where(f => f.Name.EndsWith(".dll", StringComparison.OrdinalIgnoreCase));
    /// <summary>An offline "full" package may still bundle the libraries next to the CUDA worker.</summary>
    public bool Bundled => Libraries.All(f => File.Exists(Path.Combine(bundledDirectory, f.Name)));
    public bool Installed => Bundled || InstalledCopyValid();
    /// <summary>Extra DLL directories for a worker on <paramref name="device"/>; null when CUDA libraries are not available.</summary>
    public IReadOnlyList<string>? DllDirectories(string device) => device != "cuda" || Bundled ? [] : InstalledCopyValid() ? [InstallDirectory] : null;
    private bool InstalledCopyValid()
    {
        try
        {
            var manifest = Path.Combine(InstallDirectory, "manifest.json"); if (!File.Exists(manifest)) return false;
            if ((string?)JsonNode.Parse(File.ReadAllText(manifest))?["id"] != Lock.Id) return false;
            return Lock.Packages.SelectMany(p => p.Files).All(f => new FileInfo(Path.Combine(InstallDirectory, f.Name)) is { Exists: true } info && info.Length == f.Size);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException) { return false; }
    }
    private IEnumerable<Uri> Sources(CudaRuntimePackage package)
    {
        var mirrors = Lock.Mirrors.ToList();
        if (Environment.GetEnvironmentVariable("SHENGJIAN_PYPI_MIRROR") is { Length: > 0 } preferred) mirrors.Insert(0, preferred);
        foreach (var mirror in mirrors.Distinct()) { Uri? uri = null; try { uri = ServiceAddress.Endpoint(mirror, "/" + package.Path); } catch (InvalidDataException) { } if (uri != null) yield return uri; }
    }
    public async Task InstallAsync(IProgress<(string Detail, long Completed, long Total)> progress, CancellationToken ct)
    {
        if (!await gate.WaitAsync(0, ct)) throw new InvalidOperationException("GPU 加速组件正在下载。");
        try
        {
            if (InstalledCopyValid()) return;
            var runtimeRoot = Path.Combine(dataRoot, "runtime"); var downloads = Path.Combine(runtimeRoot, ".download"); Directory.CreateDirectory(downloads);
            long needed = Lock.Packages.Sum(p => p.Size + p.Files.Sum(f => f.Size)) - Lock.Packages.Sum(p => File.Exists(Partial(downloads, p)) ? new FileInfo(Partial(downloads, p)).Length : 0);
            if (Path.GetPathRoot(runtimeRoot) is { Length: > 0 } drive && new DriveInfo(drive) is { IsReady: true } info && info.AvailableFreeSpace < needed + (256L << 20))
                throw new IOException($"磁盘空间不足：GPU 加速组件需要约 {needed / (double)(1L << 30):0.0} GiB 可用空间。");
            long total = DownloadSize, before = 0; int index = 0;
            foreach (var package in Lock.Packages)
            {
                index++; long offset = before;
                var label = $"正在下载 GPU 加速组件 {package.Name} {package.Version}（{index}/{Lock.Packages.Length}）";
                await FetchAsync(package, Partial(downloads, package), new Progress<long>(done => progress.Report((label, offset + done, total))), ct);
                before += package.Size;
            }
            var staging = Path.Combine(runtimeRoot, ".staging-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(staging);
            try
            {
                foreach (var package in Lock.Packages)
                {
                    progress.Report(("正在校验并解压 " + package.Name, total, total));
                    using var archive = ZipFile.OpenRead(Partial(downloads, package));
                    foreach (var file in package.Files) await ExtractAsync(archive, file, Path.Combine(staging, file.Name), ct);
                }
                File.WriteAllText(Path.Combine(staging, "manifest.json"), new JsonObject { ["id"] = Lock.Id, ["files"] = new JsonArray(Lock.Packages.SelectMany(p => p.Files).Select(f => (JsonNode)new JsonObject { ["name"] = f.Name, ["sha256"] = f.Sha256, ["size"] = f.Size }).ToArray()) }.ToJsonString());
                if (Directory.Exists(InstallDirectory)) Directory.Delete(InstallDirectory, true);
                Directory.Move(staging, InstallDirectory);
            }
            finally { if (Directory.Exists(staging)) Directory.Delete(staging, true); }
            foreach (var package in Lock.Packages) File.Delete(Partial(downloads, package));
            progress.Report(("GPU 加速组件已安装。", total, total));
        }
        finally { gate.Release(); }
    }
    public void Uninstall()
    {
        if (!gate.Wait(0)) throw new InvalidOperationException("GPU 加速组件正在下载。");
        try { if (Directory.Exists(InstallDirectory)) Directory.Delete(InstallDirectory, true); var downloads = Path.Combine(dataRoot, "runtime", ".download"); if (Directory.Exists(downloads)) Directory.Delete(downloads, true); }
        finally { gate.Release(); }
    }
    private static string Partial(string downloads, CudaRuntimePackage package) => Path.Combine(downloads, Path.GetFileName(package.Path) + ".incomplete");
    private async Task FetchAsync(CudaRuntimePackage package, string target, IProgress<long> progress, CancellationToken ct)
    {
        if (File.Exists(target) && new FileInfo(target).Length == package.Size && await HashAsync(target, ct) == package.Sha256) return;
        var failures = new List<string>();
        foreach (var source in Sources(package))
        {
            // A resumed file that fails SHA256 may mix bytes from another mirror: retry this mirror once from scratch.
            for (int attempt = 0; attempt < 2; attempt++)
            {
                bool resumed = false;
                try { resumed = await FetchFromAsync(package, source, target, progress, ct); return; }
                catch (CorruptDownloadException ex) when (!ct.IsCancellationRequested) { resumed = ex.Resumed; failures.Add(source.Host + "：" + ex.Message); }
                catch (Exception ex) when (!ct.IsCancellationRequested) { failures.Add(source.Host + "：" + ex.Message); }
                if (!resumed) break;
            }
        }
        throw new IOException("GPU 加速组件下载失败。" + string.Join("；", failures));
    }
    private sealed class CorruptDownloadException(string message, bool resumed) : Exception(message) { public bool Resumed { get; } = resumed; }
    private async Task<bool> FetchFromAsync(CudaRuntimePackage package, Uri source, string target, IProgress<long> progress, CancellationToken ct)
    {
        long existing = File.Exists(target) ? new FileInfo(target).Length : 0;
        if (existing > package.Size) { File.Delete(target); existing = 0; }
        using var request = new HttpRequestMessage(HttpMethod.Get, source);
        if (existing > 0) request.Headers.Range = new System.Net.Http.Headers.RangeHeaderValue(existing, null);
        using var response = await http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        if (response.RequestMessage?.RequestUri is { } final && !(final.Scheme == "https" || final.Scheme == "http" && final.IsLoopback)) throw new InvalidDataException("下载地址被重定向到非 HTTPS 地址。");
        if (existing > 0 && response.StatusCode == System.Net.HttpStatusCode.RequestedRangeNotSatisfiable) { File.Delete(target); throw new IOException("断点续传失效，将重新下载。"); }
        response.EnsureSuccessStatusCode();
        bool append = existing > 0 && response.StatusCode == System.Net.HttpStatusCode.PartialContent && response.Content.Headers.ContentRange?.From == existing;
        if (!append) existing = 0;
        // A mirror serving a different file is rejected before it can overwrite or extend verified partial data.
        if (response.Content.Headers.ContentLength is long length && existing + length != package.Size) throw new InvalidDataException("服务器文件大小与清单不符。");
        await using (var output = new FileStream(target, append ? FileMode.Append : FileMode.Create, FileAccess.Write, FileShare.None, 1 << 20, true))
        await using (var input = await response.Content.ReadAsStreamAsync(ct))
        {
            var buffer = new byte[1 << 20]; long done = existing; progress.Report(done);
            for (;;)
            {
                using var idle = CancellationTokenSource.CreateLinkedTokenSource(ct); idle.CancelAfter(TimeSpan.FromSeconds(60));
                int read;
                try { read = await input.ReadAsync(buffer, idle.Token); }
                catch (OperationCanceledException) when (!ct.IsCancellationRequested) { throw new TimeoutException("下载超过 60 秒没有数据，可稍后继续。"); }
                if (read == 0) break;
                if (done + read > package.Size) { output.SetLength(0); throw new InvalidDataException("下载文件大于清单记录。"); }
                await output.WriteAsync(buffer.AsMemory(0, read), ct); done += read; progress.Report(done);
            }
        }
        if (new FileInfo(target).Length != package.Size) throw new IOException("下载未完成，可稍后继续。");
        if (await HashAsync(target, ct) != package.Sha256) { File.Delete(target); throw new CorruptDownloadException("SHA256 校验失败，已删除损坏文件。", append); }
        return append;
    }
    private static async Task ExtractAsync(ZipArchive archive, CudaRuntimeFile file, string target, CancellationToken ct)
    {
        var entry = archive.GetEntry(file.Entry) ?? throw new InvalidDataException("安装包缺少 " + file.Entry);
        if (entry.Length != file.Size) throw new InvalidDataException(file.Name + " 大小与清单不符。");
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        await using (var input = entry.Open())
        await using (var output = new FileStream(target, FileMode.CreateNew, FileAccess.Write, FileShare.None, 1 << 20, true))
        {
            var buffer = new byte[1 << 20]; int read;
            while ((read = await input.ReadAsync(buffer, ct)) > 0) { hash.AppendData(buffer, 0, read); await output.WriteAsync(buffer.AsMemory(0, read), ct); }
        }
        if (Convert.ToHexStringLower(hash.GetHashAndReset()) != file.Sha256) throw new InvalidDataException(file.Name + " SHA256 校验失败。");
    }
    private static async Task<string> HashAsync(string path, CancellationToken ct)
    {
        await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20, true);
        return Convert.ToHexStringLower(await SHA256.HashDataAsync(stream, ct));
    }
    public void Dispose() { http.Dispose(); gate.Dispose(); }
}
