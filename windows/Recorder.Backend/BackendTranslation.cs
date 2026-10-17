using System.Diagnostics;
using System.Text.Json.Nodes;
namespace Recorder.Backend;

public sealed partial class BackendCore
{
    private sealed class TranslationJob(string session, int segment, long unit, string source)
    {
        public readonly string Session = session, Source = source;
        public readonly int Segment = segment;
        public readonly long Unit = unit;
        public string Target = "", Text = ""; public int Revision; public bool Cancelled;
        public long Started, Sent; public CancellationTokenSource? Cancel;
        public IAsyncEnumerator<string>? Stream; public ITranslatorEngine? ApiEngine;
    }
    private readonly TranslationPlanner planner = new();
    private readonly Queue<TranslationJob> translations = new();
    private readonly List<(string Target, string Session, string Source, string Text)> context = new();
    private TranslationJob? translating;
    private EngineModel? activeTranslator;
    private long nextUnit;
    private string overloadSession = "";
    private Func<TranslationConfig, ITranslatorEngine>? apiTranslationFactory;
    public void SetApiTranslationFactory(Func<TranslationConfig, ITranslatorEngine> factory) { lock (gate) apiTranslationFactory = factory; }
    private bool CanTranslate => translation.Enabled && (translation.Provider == "local" ? translator.IsLoaded : apiTranslationFactory != null);
    private partial bool HasTranslation => translating != null || translations.Count > 0;
    partial void PlanTranslation(string sessionId, int segmentId, string text, bool forcedCut)
    { if (CanTranslate) QueueUnit(sessionId, planner.Add(sessionId, segmentId, text, forcedCut)); }
    partial void FlushTranslation(string sessionId) { if (CanTranslate) QueueUnit(sessionId, planner.Flush(sessionId)); }
    private void QueueUnit(string sessionId, TranslationUnit? unit)
    {
        if (unit == null || TranslationText.AlreadyInTarget(unit.Source, translation.TargetLanguage)) return;
        bool dropped = false;
        while (translations.Count >= 4) { EndTranslation(translations.Dequeue()); dropped = true; }
        if (dropped && overloadSession != sessionId) { overloadSession = sessionId; Error("翻译跟不上语速，已跳过部分句子的译文；原文不受影响。"); }
        var job = new TranslationJob(sessionId, unit.AnchorSegment, ++nextUnit, unit.Source);
        TranslationEvent(job, false); translations.Enqueue(job); Wake();
    }
    private void TranslationEvent(TranslationJob job, bool done, string? text = null)
    {
        Emit("translation", new() { ["session_id"] = job.Session, ["segment_id"] = job.Segment, ["unit_id"] = job.Unit, ["revision"] = job.Revision,
            ["text"] = text ?? job.Text.Trim(), ["done"] = done, ["skipped"] = done && string.IsNullOrEmpty(text), ["elapsed_ms"] = job.Started == 0 ? 0 : (long)Stopwatch.GetElapsedTime(job.Started).TotalMilliseconds });
    }
    private void EndTranslation(TranslationJob job, string text = "") { job.Revision++; TranslationEvent(job, true, text); }
    private void DropTranslations()
    {
        while (translations.TryDequeue(out var job)) EndTranslation(job);
        if (translating is { } current) { current.Cancelled = true; current.Cancel?.Cancel(); }
        context.Clear(); Wake();
    }
    private async Task CloseTranslationAsync(TranslationJob job)
    {
        try { if (job.Stream != null) await job.Stream.DisposeAsync(); }
        finally { job.Stream = null; job.Cancel?.Dispose(); job.Cancel = null; if (job.ApiEngine != null) await job.ApiEngine.DisposeAsync(); }
    }
    private async Task CancelTranslationAsync()
    {
        TranslationJob? current;
        lock (gate) { DropTranslations(); current = translating; translating = null; }
        if (current != null) { try { await CloseTranslationAsync(current); } finally { lock (gate) EndTranslation(current); } }
    }
    private partial async Task TranslationStepAsync()
    {
        TranslationJob? job;
        lock (gate) { if (translating == null && translations.Count > 0) translating = translations.Dequeue(); job = translating; }
        if (job == null) return;
        try
        {
            if (job.Cancelled || !CanTranslate) { await FinishTranslationAsync(job); return; }
            if (job.Stream == null)
            {
                IReadOnlyList<ChatMessage> messages; ITranslatorEngine engine;
                lock (gate)
                {
                    job.Target = translation.TargetLanguage; job.Started = job.Sent = Stopwatch.GetTimestamp(); job.Cancel = CancellationTokenSource.CreateLinkedTokenSource(lifetime.Token);
                    engine = translation.Provider == "local" ? translator : job.ApiEngine = apiTranslationFactory!(translation);
                    messages = TranslationText.Messages(runtime.TranslatorEngine, job.Source, job.Target, context.Where(p => p.Session == job.Session && p.Target == job.Target).Select(p => (p.Source, p.Text)));
                }
                job.Stream = engine.StreamAsync(messages, TranslationText.MaxTokens(job.Source), job.Cancel.Token).GetAsyncEnumerator();
            }
            // One token per step lets the pump run final/load/stop jobs first.
            if (await job.Stream.MoveNextAsync())
            {
                lock (gate)
                {
                    job.Text += job.Stream.Current;
                    if (!job.Cancelled && job.Text.Trim().Length > 0 && Stopwatch.GetElapsedTime(job.Sent).TotalSeconds >= .2) { job.Revision++; job.Sent = Stopwatch.GetTimestamp(); TranslationEvent(job, false); }
                }
            }
            else
            {
                string result = job.Text.Trim(); if (TranslationText.Same(result, job.Source)) result = "";
                lock (gate) if (result.Length > 0 && !job.Cancelled) { context.Add((job.Target, job.Session, job.Source, result)); while (context.Count > 2) context.RemoveAt(0); }
                await FinishTranslationAsync(job, job.Cancelled ? "" : result);
            }
        }
        catch (OperationCanceledException) when (job.Cancelled || lifetime.IsCancellationRequested) { await FinishTranslationAsync(job); }
        catch (Exception ex)
        {
            await FinishTranslationAsync(job);
            lock (gate) { DropTranslations(); Error("翻译失败：" + ex.Message + "；原文不受影响。"); TranslatorStatus(translator.IsLoaded ? "ready" : "error", ex.Message); }
        }
    }
    private async Task FinishTranslationAsync(TranslationJob job, string result = "")
    {
        try { await CloseTranslationAsync(job); }
        finally { lock (gate) { if (translating == job) translating = null; EndTranslation(job, result); } }
    }
    private partial async Task LoadTranslatorAsync(TranslationConfig next, RuntimeConfig nextRuntime, EngineModel? resolved)
    {
        var previous = translation; var previousRuntime = runtime; var previousModel = activeTranslator;
        try
        {
            await CancelTranslationAsync();
            if (resolved == null) { var result = resolver.Resolve(next, nextRuntime); resolved = result.Model; next = next with { Revision = result.Revision }; }
            await translator.LoadAsync(resolved, lifetime.Token);
            lock (gate) TranslatorStatus("warming");
            await translator.WarmupAsync(lifetime.Token);
            store.SaveSelection(next with { Enabled = true }, nextRuntime);
            lock (gate) { runtime = nextRuntime; translation = next with { Enabled = true }; activeTranslator = resolved; TranslatorStatus("ready"); }
        }
        catch (Exception ex)
        {
            await translator.UnloadAsync(); bool restored = false;
            if (previousModel != null && !lifetime.IsCancellationRequested) try { await translator.LoadAsync(previousModel, lifetime.Token); await translator.WarmupAsync(lifetime.Token); restored = true; } catch { }
            lock (gate) { translation = previous; runtime = previousRuntime; activeTranslator = restored ? previousModel : null; TranslatorStatus("error", ex.Message); if (restored) TranslatorStatus("ready", "已恢复上一翻译模型。"); }
        }
    }
    private partial void MaybeLoadTranslator()
    {
        if (translation.Enabled && translation.Provider == "local" && !translator.IsLoaded && translatorState is not ("loading" or "warming"))
        { TranslatorStatus("loading"); var current = translation; var options = runtime; Queue(() => LoadTranslatorAsync(current, options)); }
    }
    private partial void SetTranslation(JsonObject message)
    {
        if (translatorState is "loading" or "warming" or "downloading") throw new InvalidOperationException("请等待翻译模型操作结束。");
        var values = BackendJson.Object(translation);
        foreach (var key in new[] { "enabled", "target_language", "provider", "api_profile" }) if (message[key] is JsonNode value) values[key] = value.DeepClone();
        var next = BackendJson.Parse<TranslationConfig>(values);
        store.Save("translation.json", next); if (translation != next) DropTranslations(); translation = next;
        if (!next.Enabled || next.Provider == "api") Queue(async () => { await CancelTranslationAsync(); await translator.UnloadAsync(); lock (gate) { activeTranslator = null; TranslatorStatus("idle"); } });
        else MaybeLoadTranslator();
        TranslatorStatus(translatorState);
    }
}
