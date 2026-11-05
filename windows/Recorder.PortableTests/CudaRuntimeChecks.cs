using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text.Json.Nodes;
using Recorder.Backend;

/// <summary>On-demand CUDA runtime installer against a local server: mirror fallback, corrupt download, resume, bundled copy.</summary>
static class CudaRuntimeChecks
{
    public static async Task Run(string root, string workspace, Action<bool, string> check)
    {
        var shipped = new CudaRuntime(Path.Combine(root, "lock-check"), Path.Combine(root, "no-runtime"), Path.Combine(workspace, "windows", "cuda-runtime.lock.json"));
        check(shipped.Lock.Packages.SelectMany(p => p.Files).Select(f => f.Name).Order().SequenceEqual(new[] { "CUDA-EULA.txt", "cublas64_12.dll", "cublasLt64_12.dll", "cudart64_12.dll" }.Order()), "shipped lock lists cudart, cuBLAS, cuBLASLt and the NVIDIA license");
        check(shipped.Lock.Mirrors[0] == "https://files.pythonhosted.org" && shipped.DownloadSize > 500L << 20, "shipped lock pins the official PyPI wheels");
        shipped.Dispose();

        var data = Path.Combine(root, "cuda"); Directory.CreateDirectory(data);
        var random = new Random(11); var dll = new byte[300_000]; random.NextBytes(dll); var lt = new byte[900_000]; random.NextBytes(lt); var license = "NVIDIA EULA"u8.ToArray();
        byte[] Wheel(params (string Entry, byte[] Data)[] entries)
        {
            using var stream = new MemoryStream();
            using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, true)) foreach (var (entry, bytes) in entries) { using var e = zip.CreateEntry(entry).Open(); e.Write(bytes); }
            return stream.ToArray();
        }
        var runtimeWheel = Wheel(("nvidia/cuda_runtime/bin/cudart64_12.dll", dll), ("lic/License.txt", license));
        var blasWheel = Wheel(("nvidia/cublas/bin/cublasLt64_12.dll", lt), ("nvidia/cublas/bin/cublas64_12.dll", dll));
        string Hash(byte[] bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
        using var server = new WheelServer(new() { ["/good/packages/a/cudart.whl"] = runtimeWheel, ["/good/packages/b/cublas.whl"] = blasWheel, ["/bad/packages/a/cudart.whl"] = Wheel(("x", dll)) });
        JsonObject File(string entry, string name, byte[] bytes) => new() { ["entry"] = entry, ["name"] = name, ["size"] = bytes.Length, ["sha256"] = Hash(bytes) };
        var lockJson = new JsonObject
        {
            ["schema_version"] = 1, ["id"] = "cuda-test", ["description"] = "test",
            ["mirrors"] = new JsonArray("http://127.0.0.1:" + server.Port + "/missing", "http://127.0.0.1:" + server.Port + "/bad", "http://127.0.0.1:" + server.Port + "/good"),
            ["packages"] = new JsonArray(
                new JsonObject { ["name"] = "rt", ["version"] = "1", ["path"] = "packages/a/cudart.whl", ["size"] = runtimeWheel.Length, ["sha256"] = Hash(runtimeWheel), ["files"] = new JsonArray(File("nvidia/cuda_runtime/bin/cudart64_12.dll", "cudart64_12.dll", dll), File("lic/License.txt", "CUDA-EULA.txt", license)) },
                new JsonObject { ["name"] = "blas", ["version"] = "1", ["path"] = "packages/b/cublas.whl", ["size"] = blasWheel.Length, ["sha256"] = Hash(blasWheel), ["files"] = new JsonArray(File("nvidia/cublas/bin/cublas64_12.dll", "cublas64_12.dll", dll), File("nvidia/cublas/bin/cublasLt64_12.dll", "cublasLt64_12.dll", lt)) })
        };
        var lockPath = Path.Combine(root, "cuda-test.lock.json"); System.IO.File.WriteAllText(lockPath, lockJson.ToJsonString());
        var appRuntime = Path.Combine(root, "app-runtime"); Directory.CreateDirectory(Path.Combine(appRuntime, "cuda"));
        using var cuda = new CudaRuntime(data, appRuntime, lockPath);
        check(!cuda.Installed && cuda.DllDirectories("cuda") == null && cuda.DllDirectories("cpu")!.Count == 0, "missing CUDA runtime reported before download");

        server.CutAfter = ("/good/packages/b/cublas.whl", 400_000);
        using (var first = new CancellationTokenSource())
        {
            try { await cuda.InstallAsync(new Progress<(string, long, long)>(), first.Token); check(false, "interrupted download must not install"); }
            catch (IOException ex) { Console.WriteLine("INFO: interrupted as expected: " + ex.Message); }
        }
        check(!cuda.Installed && System.IO.File.Exists(Path.Combine(data, "runtime", ".download", "cublas.whl.incomplete")), "interrupted download keeps verified partial data for resume");
        server.CutAfter = null; long reported = 0;
        await cuda.InstallAsync(new Progress<(string Detail, long Completed, long Total)>(p => reported = Math.Max(reported, p.Completed)), default);
        check(server.Requests.Any(r => r.Path == "/good/packages/b/cublas.whl" && r.Range == 400_000), "download resumes with an HTTP Range request");
        check(server.Requests.Any(r => r.Path.StartsWith("/bad/")) && cuda.Installed, "corrupt mirror is rejected by SHA256 and the next mirror is used");
        check(cuda.DllDirectories("cuda")!.SequenceEqual(new[] { cuda.InstallDirectory }) && System.IO.File.ReadAllBytes(Path.Combine(cuda.InstallDirectory, "cublasLt64_12.dll")).SequenceEqual(lt), "installed CUDA libraries are verified and handed to the CUDA worker");
        check(!Directory.Exists(Path.Combine(data, "runtime", ".download")) || !Directory.EnumerateFiles(Path.Combine(data, "runtime", ".download")).Any(), "downloaded wheels are removed after extraction");
        System.IO.File.WriteAllBytes(Path.Combine(cuda.InstallDirectory, "cublas64_12.dll"), [1, 2, 3]);
        check(!cuda.Installed, "truncated installed library is detected");
        cuda.Uninstall(); check(!Directory.Exists(cuda.InstallDirectory), "uninstall removes the CUDA runtime");
        foreach (var name in new[] { "cudart64_12.dll", "cublas64_12.dll", "cublasLt64_12.dll" }) System.IO.File.WriteAllBytes(Path.Combine(appRuntime, "cuda", name), [0]);
        check(cuda.Bundled && cuda.Installed && cuda.DllDirectories("cuda")!.Count == 0, "offline package with bundled CUDA libraries needs no download");
    }
}

/// <summary>Minimal HTTP/1.1 file server with Range support and an optional connection cut, on a loopback socket.</summary>
sealed class WheelServer : IDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly Dictionary<string, byte[]> files;
    private readonly CancellationTokenSource stop = new();
    public readonly List<(string Path, long Range)> Requests = new();
    public (string Path, int Bytes)? CutAfter;
    public int Port => ((IPEndPoint)listener.LocalEndpoint).Port;
    public WheelServer(Dictionary<string, byte[]> files) { this.files = files; listener.Start(); _ = Task.Run(AcceptAsync); }
    private async Task AcceptAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            TcpClient client; try { client = await listener.AcceptTcpClientAsync(stop.Token); } catch { return; }
            _ = Task.Run(async () => { using (client) try { await ServeAsync(client.GetStream()); } catch { } });
        }
    }
    private async Task ServeAsync(NetworkStream stream)
    {
        var reader = new StreamReader(stream, leaveOpen: true); var line = await reader.ReadLineAsync() ?? ""; var path = line.Split(' ')[1]; long from = 0;
        for (string? header; !string.IsNullOrEmpty(header = await reader.ReadLineAsync());)
            if (header.StartsWith("Range: bytes=", StringComparison.OrdinalIgnoreCase)) from = long.Parse(header[13..].TrimEnd('-').Split('-')[0]);
        lock (Requests) Requests.Add((path, from));
        if (!files.TryGetValue(path, out var body)) { await stream.WriteAsync("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"u8.ToArray()); return; }
        var slice = body.AsMemory((int)from);
        var head = from > 0 ? $"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {from}-{body.Length - 1}/{body.Length}\r\n" : "HTTP/1.1 200 OK\r\n";
        await stream.WriteAsync(System.Text.Encoding.ASCII.GetBytes(head + $"Content-Length: {slice.Length}\r\nConnection: close\r\n\r\n"));
        if (CutAfter is { } cut && cut.Path == path && from == 0) { await stream.WriteAsync(slice[..cut.Bytes]); return; }
        await stream.WriteAsync(slice);
    }
    public void Dispose() { stop.Cancel(); listener.Stop(); }
}
