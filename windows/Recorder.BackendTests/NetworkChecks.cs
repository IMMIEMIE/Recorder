using System.Net;
using System.Net.Sockets;
using System.Text;
using Recorder.Backend;
internal static class NetworkChecks
{
    public static async Task Run(string root, Action<bool, string> check)
    {
        var profiles = new ProfileStore(Path.Combine(root, "profiles-test"));
        var a = new ServiceProfile(ServiceProfile.Normalize("HTTPS://example.com:443/v1/chat/completions/"), "model-a");
        var b = new ServiceProfile("https://other.example/v1", "model-b"); profiles.Save(a, "test-secret-a"); profiles.Save(b, "test-secret-b"); profiles.Save(a with { Model = "updated" }, "");
        check(a.BaseUrl == "https://example.com/v1" && profiles.Load().Count == 2 && profiles.Key(a) == "test-secret-a" && profiles.Key(b) == "test-secret-b", "service profiles normalize endpoints and isolate DPAPI credentials");
        check(!string.Join("", Directory.GetFiles(Path.Combine(root, "profiles-test/profiles"), "*.json").Select(File.ReadAllText)).Contains("test-secret"), "plain service configuration never stores API keys");
        profiles.Delete(a); check(profiles.Load().Count == 1 && profiles.Key(a) == "", "deleting profile deletes its credential only");
        File.WriteAllText(Path.Combine(root, "profiles-test/profiles/broken.json"), "bad-json");
        check(profiles.Load().Count == 1 && profiles.Issues.Count == 1, "corrupt service profile does not hide valid services");
        File.WriteAllText(Path.Combine(root, "profiles-test/profiles/missing.json"), "{\"model\":\"test\"}");
        check(profiles.Load().Count == 1 && profiles.Issues.Count == 2, "service profiles with missing required fields are isolated");
        using (var locked = new FileStream(Path.Combine(root, "profiles-test/profiles/" + b.Id + ".json"), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            bool rejected = false; try { profiles.Save(b with { Model = "changed" }, "replacement-secret"); } catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { rejected = true; }
            check(rejected && profiles.Key(b) == "test-secret-b", "failed service metadata commit rolls credential back atomically");
        }
        var socket = new TcpListener(IPAddress.Loopback, 0); socket.Start(); int port = ((IPEndPoint)socket.LocalEndpoint).Port; socket.Stop();
        using var listener = new HttpListener(); string address = $"http://127.0.0.1:{port}"; listener.Prefixes.Add(address + "/"); listener.Start();
        async Task Scenario(string route, string data, bool error, bool cancel = false, int status = 200)
        {
            var server = Task.Run(async () =>
            {
                var c = await listener.GetContextAsync(); using var sink = new MemoryStream(); await c.Request.InputStream.CopyToAsync(sink);
                check(c.Request.Headers["Authorization"] == "Bearer synthetic" && Encoding.UTF8.GetString(sink.ToArray()).Contains("\"stream\":true"), "SSE request carries isolated credential and streaming flag: " + route);
                c.Response.StatusCode = status; c.Response.ContentType = "text/event-stream"; if (status == 302) c.Response.RedirectLocation = address + "/never";
                try { if (cancel) await Task.Delay(200); foreach (byte value in Encoding.UTF8.GetBytes(data)) await c.Response.OutputStream.WriteAsync(new byte[] { value }); } catch (HttpListenerException) { } catch (ObjectDisposedException) { } finally { c.Response.Close(); }
            });
            using var ct = new CancellationTokenSource(cancel ? 50 : 5000); var result = new StringBuilder(); bool failed = false;
            try { await using var client = new ChatClient(new(address + "/" + route, "mock"), "synthetic"); await foreach (var delta in client.StreamAsync([new("user", "test")], 32, ct.Token)) result.Append(delta); }
            catch { failed = true; }
            await server.WaitAsync(TimeSpan.FromSeconds(5));
            check(failed == error && (error || result.ToString() == "你好🌏"), "SSE protocol scenario: " + route);
        }
        string ok = ": ping\r\n\r\ndata: {\"choices\":[{\"delta\":{\"content\":\"你好🌏\"},\"finish_reason\":null}]}\r\n\r\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n";
        await Scenario("ok", ok, false); await Scenario("truncated", "data: {\"choices\":[{\"delta\":{\"content\":\"partial\"}}]}\n\n", true);
        await Scenario("malformed", "data: not-json\n\n", true); await Scenario("limited", ok.Replace("\"stop\"", "\"length\""), true);
        await Scenario("redirect", "", true, status: 302); await Scenario("rate", "", true, status: 429); await Scenario("cancel", ok, true, true);
        check(ChatClient.Question("总结", "转写文本")[1].Content.Contains("<transcript>"), "AI tasks delimit transcript material");
    }
}
