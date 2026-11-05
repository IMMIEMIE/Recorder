using Recorder.Backend;
using System.Text.Json.Nodes;
namespace Recorder.Windows;

internal sealed class SettingsForm : Form
{
    private readonly AppSettings current;
    private readonly Dictionary<string, TextBox> fields = new();
    private readonly Dictionary<string, ComboBox> choices = new();
    private readonly Dictionary<string, CheckBox> checks = new();
    private readonly Dictionary<string, NumericUpDown> numbers = new();
    private readonly Button save = Theme.Button("加载并保存", true);
    private readonly Label status = Theme.Label("模型加载和预热成功后才会保存选择。", 9, Theme.Muted);
    private CancellationTokenSource? operation;
    private readonly TabControl tabs = new() { Dock = DockStyle.Fill };
    private readonly WorkflowSelector workflow = new() { Dock = DockStyle.Fill };
    public SettingsForm(AppSettings settings)
    {
        current = settings with { }; Text = "声笺 · 设置"; ClientSize = new(790, 740); MinimumSize = new(700, 600); Theme.Style(this);
        var root = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(20), RowCount = 4, ColumnCount = 1 };
        root.RowStyles.Add(new(SizeType.Absolute, 106));
        root.RowStyles.Add(new(SizeType.Percent, 100)); root.RowStyles.Add(new(SizeType.Absolute, 58)); root.RowStyles.Add(new(SizeType.Absolute, 42));
        var header = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Margin = new(0) };
        header.RowStyles.Add(new(SizeType.Absolute, 24)); header.RowStyles.Add(new(SizeType.Absolute, 44)); header.RowStyles.Add(new(SizeType.Percent, 100));
        header.Controls.Add(Theme.Label("工作模式", 9, Theme.Muted)); header.Controls.Add(workflow);
        var description = Theme.Label("", 9, Theme.Muted); description.Dock = DockStyle.Fill; header.Controls.Add(description); root.Controls.Add(header);
        root.Controls.Add(tabs); status.Dock = DockStyle.Fill; root.Controls.Add(status);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft };
        var cancel = Theme.Button("取消操作"); buttons.Controls.Add(save); buttons.Controls.Add(cancel); root.Controls.Add(buttons); Controls.Add(root);
        var asr = Page("识别");
        Choice(asr, "Mode", "识别方式", ["local", "api", "stream"], settings.RecognitionMode);
        Choice(asr, "Language", "原文语言", Languages.Recognition, Languages.RecognitionName(settings.Language));
        Choice(asr, "Device", "运行设备", ["auto", "cpu", "cuda"], settings.Device);
        CudaActions(asr);
        Choice(asr, "AsrPreset", "本地模型", DesktopBackend.Shared.Models.Presets.Where(p => p.Role == "asr").Select(p => p.Name).Append("自定义").ToArray(), PresetName("asr", settings.AsrModelId, settings.AsrFilename));
        Field(asr, "AsrModelId", "模型仓库 owner/model", settings.AsrModelId);
        Field(asr, "AsrRevision", "固定 revision（可留空）", settings.AsrRevision);
        Choice(asr, "AsrEngine", "自定义模型架构", ["qwen", "whisper"], settings.AsrEngine);
        Check(asr, "UseLocalFile", "使用本地模型文件或目录", settings.UseLocalFile);
        FileField(asr, "ModelPath", "本地 GGUF / GGML", settings.ModelPath);
        FileField(asr, "AsrProjector", "Qwen 音频编码 GGUF", settings.AsrProjector);
        Field(asr, "AsrFilename", "仓库权重文件名", settings.AsrFilename);
        Field(asr, "AsrProjectorFilename", "仓库音频编码文件名", settings.AsrProjectorFilename);
        ModelActions(asr, "asr");
        Choice(asr, "EndpointMode", "停顿策略", ["smart", "fixed"], settings.EndpointMode);
        Number(asr, "SilenceMs", "固定停顿 (ms)", settings.SilenceMs, 300, 2000);
        Number(asr, "SmartSentenceSilenceMs", "完整句停顿 (ms)", settings.SmartSentenceSilenceMs, 300, 1200);
        Number(asr, "SmartFallbackSilenceMs", "兜底停顿 (ms)", settings.SmartFallbackSilenceMs, 800, 3000);
        var endpointHint = Theme.Label("", 9, Theme.Muted); endpointHint.MaximumSize = new(430, 0); Add(asr, "生效方式", endpointHint);
        void RefreshEndpointFields()
        {
            bool local = ((Option)choices["Mode"].SelectedItem!).Value == "local";
            bool smart = ((Option)choices["EndpointMode"].SelectedItem!).Value == "smart";
            SetRowVisible(asr, numbers["SilenceMs"], !local || !smart);
            SetRowVisible(asr, numbers["SmartSentenceSilenceMs"], local && smart);
            SetRowVisible(asr, numbers["SmartFallbackSilenceMs"], local && smart);
            SetRowVisible(asr, endpointHint, local);
            asr.GetControlFromPosition(0, asr.GetRow(numbers["SilenceMs"]))!.Text = local ? "固定停顿 (ms)" : "固定 / 完整句停顿 (ms)";
            endpointHint.Text = smart
                ? "识别到完整句后按短停顿定稿，未完整句按兜底停顿收尾。兜底至少比完整句停顿长 200 ms。时间从最后语音帧起算，文字显示还需等待模型；保存后从下一次会话生效。"
                : "持续停顿达到设定时间即收尾。时间从最后语音帧起算，文字显示还需等待模型；保存后从下一次会话生效。";
        }
        numbers["SmartSentenceSilenceMs"].ValueChanged += (_, _) => numbers["SmartFallbackSilenceMs"].Minimum = Math.Max(800, numbers["SmartSentenceSilenceMs"].Value + 200);
        numbers["SmartFallbackSilenceMs"].Minimum = Math.Max(800, numbers["SmartSentenceSilenceMs"].Value + 200);
        choices["Mode"].SelectedIndexChanged += (_, _) => RefreshEndpointFields();
        choices["EndpointMode"].SelectedIndexChanged += (_, _) => RefreshEndpointFields();
        RefreshEndpointFields();
        Number(asr, "PreviewMs", "临时预览间隔 (ms)", settings.PreviewMs, 800, 10000);
        Number(asr, "MaxSegmentSeconds", "模型输入块长度 (秒)", settings.MaxSegmentSeconds, 5, 25);
        var api = Page("在线服务");
        Field(api, "ApiBase", "转写 API Base URL", settings.ApiBase); Field(api, "ApiModel", "转写模型", settings.ApiModel);
        Field(api, "ApiSecret", "转写 API Key（空白保留）", "", true); Field(api, "StreamingSecret", "千问流式专用 Key", "", true);
        Field(api, "TranslationBase", "翻译 / AI Base URL", settings.TranslationBase); Field(api, "TranslationModel", "翻译 / AI 模型", settings.TranslationModel);
        Field(api, "TranslationSecret", "翻译 / AI Key", "", true);
        var profiles = Theme.Button("管理多个 API 服务…"); Add(api, "", profiles);
        profiles.Click += (_, _) => { using var form = new ProfilesForm(); if (form.ShowDialog(this) == DialogResult.OK) { current.ApiProfileId = form.SelectedId; var p = new ProfileStore(SettingsStore.Root).Get(form.SelectedId); fields["TranslationBase"].Text = p.BaseUrl; fields["TranslationModel"].Text = p.Model; } };
        var translate = Page("翻译");
        Check(translate, "Translation", "开启翻译", settings.Translation);
        Choice(translate, "TranslationProvider", "翻译服务", ["local", "api"], settings.TranslationProvider);
        var translationHint = Theme.Label("本地翻译随转录预览更新，定稿后校正；API 翻译在定稿后开始。", 9, Theme.Muted);
        translationHint.MaximumSize = new(430, 0); Add(translate, "更新方式", translationHint);
        Choice(translate, "TargetLanguage", "目标语言", Languages.Targets, Languages.Target(settings.TargetLanguage));
        Choice(translate, "TranslatorPreset", "本地翻译模型", DesktopBackend.Shared.Models.Presets.Where(p => p.Role == "translator").Select(p => p.Name).Append("自定义").ToArray(), PresetName("translator", settings.TranslatorModelId, settings.TranslatorFilename));
        Field(translate, "TranslatorModelId", "模型仓库 owner/model", settings.TranslatorModelId); Field(translate, "TranslatorRevision", "固定 revision（可留空）", settings.TranslatorRevision);
        Choice(translate, "TranslatorEngine", "自定义模型架构", ["qwen3", "hunyuan", "qwen2", "llama", "mistral"], settings.TranslatorEngine);
        FileField(translate, "TranslatorPath", "本地 GGUF（可留空）", settings.TranslatorPath); Field(translate, "TranslatorFilename", "仓库权重文件名", settings.TranslatorFilename);
        ModelActions(translate, "translator");
        var live = Page("LiveTranslate"); Field(live, "LiveEndpoint", "WSS 服务地址", settings.LiveEndpoint); Field(live, "LiveSecret", "LiveTranslate 专用 Key", "", true);
        Choice(live, "LiveTargetLanguage", "目标语言", Languages.Targets.Where(language => language != "繁體中文").ToArray(), Languages.Target(settings.EffectiveLiveTarget));
        Check(live, "LiveAudioOutput", "译音输出", settings.LiveAudioOutput); Number(live, "LiveVolume", "播放音量 (%)", (int)(settings.LiveVolume * 100), 0, 100);
        Choice(live, "LiveTiming", "播放时机", ["streaming", "final"], settings.LiveTiming);
        var appearance = Page("外观");
        Choice(appearance, "Appearance", "界面外观", ["system", "light", "dark"], settings.Appearance);
        var appearanceHint = Theme.Label("默认跟随 Windows 的应用颜色模式。外观保存后立即生效，无需加载模型。", 9, Theme.Muted);
        appearanceHint.MaximumSize = new(430, 0); Add(appearance, "", appearanceHint);
        var applyAppearance = Theme.Button("应用外观", true); Add(appearance, "", applyAppearance);
        applyAppearance.Click += (_, _) =>
        {
            if (operation != null) return;
            try
            {
                var value = ((Option)choices["Appearance"].SelectedItem!).Value;
                SettingsStore.Save(SettingsStore.Load() with { Appearance = value });
                current.Appearance = value; Theme.SetAppearance(value); status.Text = "外观已保存并应用。";
            }
            catch (Exception ex) { status.Text = "外观未保存：" + ex.Message; }
        };
        var pages = tabs.TabPages.Cast<TabPage>().ToArray();
        void ShowMode(bool liveMode)
        {
            tabs.TabPages.Clear();
            tabs.TabPages.AddRange(liveMode ? [pages[3], pages[4]] : [pages[0], pages[1], pages[2], pages[4]]);
            description.Text = liveMode ? "云端直接实时翻译，可输出译音；使用 LiveTranslate 专用 Key。" : "先识别原文，再按需翻译；支持本地模型、HTTP API 和千问流式识别。";
            save.Text = liveMode ? "保存 LiveTranslate 设置" : "加载并保存";
            status.Text = liveMode ? "保存后在主界面开始。此模式无需加载本地识别或翻译模型。" : "模型加载和预热成功后才会保存选择。";
        }
        workflow.LiveMode = settings.Mode == "live"; workflow.ModeChanged += ShowMode; ShowMode(workflow.LiveMode);
        FormClosed += (_, _) => { foreach (var page in pages) page.Dispose(); };
        choices["AsrPreset"].SelectedIndexChanged += (_, _) => Preset("asr"); choices["TranslatorPreset"].SelectedIndexChanged += (_, _) => Preset("translator");
        save.Click += async (_, _) => await RunAsync(async ct =>
        {
            var next = Read();
            if (next.Mode == "live")
            {
                await DesktopBackend.Shared.SuspendAsync(ct);
                ct.ThrowIfCancellationRequested();
                SettingsStore.Save(next); Theme.SetAppearance(next.Appearance); DialogResult = DialogResult.OK; Close(); return;
            }
            await DesktopBackend.Shared.ApplyAsync(next, ct: ct);
            var accepted = SettingsStore.Load();
            SettingsStore.Save(accepted with { ApiSecret = next.ApiSecret, StreamingSecret = next.StreamingSecret, LiveSecret = next.LiveSecret, LiveEndpoint = next.LiveEndpoint, LiveAudioOutput = next.LiveAudioOutput, LiveTiming = next.LiveTiming, LiveVolume = next.LiveVolume, LiveTargetLanguage = next.LiveTargetLanguage, RegularMode = next.RegularMode, Mode = next.Mode });
            if (next.TranslationProvider == "api" || fields["TranslationSecret"].Text.Length > 0)
            {
                var profiles = new ProfileStore(SettingsStore.Root); var profile = new ServiceProfile(ServiceProfile.Normalize(next.TranslationBase), next.TranslationModel);
                profiles.Save(profile, fields["TranslationSecret"].Text.Trim()); next.ApiProfileId = profile.Id; next.TranslationSecret = "";
                File.WriteAllText(Path.Combine(SettingsStore.Root, "profiles/.legacy-migrated"), "1");
            }
            var command = DesktopBackend.Command("translation_settings"); var t = next.TranslationConfig();
            command["enabled"] = t.Enabled; command["provider"] = t.Provider; command["target_language"] = t.TargetLanguage; command["api_profile"] = t.ApiProfile;
            // Reload the translator only when its model, engine or device changed; switching languages never reloads it.
            await DesktopBackend.Shared.WaitTranslatorIdleAsync(ct);
            if (DesktopBackend.Shared.NeedsTranslatorLoad(next)) await DesktopBackend.Shared.ApplyAsync(next, role: "translator", ct: ct);
            await DesktopBackend.Shared.Channel.ControlAsync(command);
            SettingsStore.Save(next); Theme.SetAppearance(next.Appearance); DialogResult = DialogResult.OK; Close();
        });
        cancel.Click += async (_, _) => { operation?.Cancel(); await DesktopBackend.Shared.Channel.ControlAsync(DesktopBackend.Command("cancel_operation")); };
        FormClosing += (_, e) => { if (operation != null && DialogResult != DialogResult.OK) { e.Cancel = true; operation.Cancel(); } };
        DesktopBackend.Shared.Event += Progress; FormClosed += (_, _) => DesktopBackend.Shared.Event -= Progress;
    }
    private TableLayoutPanel Page(string title)
    {
        var page = new TabPage(title) { AutoScroll = true, BackColor = Theme.Paper };
        var panel = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2, Padding = new(12) };
        panel.ColumnStyles.Add(new(SizeType.Absolute, 210)); panel.ColumnStyles.Add(new(SizeType.Percent, 100)); page.Controls.Add(panel); tabs.TabPages.Add(page); return panel;
    }
    private void Add(TableLayoutPanel panel, string label, Control control)
    { int row = panel.RowCount++; panel.RowStyles.Add(new(SizeType.AutoSize)); panel.Controls.Add(Theme.Label(label, 9), 0, row); control.Dock = DockStyle.Fill; control.Margin = new(0, 5, 0, 5); panel.Controls.Add(control, 1, row); }
    private static void SetRowVisible(TableLayoutPanel panel, Control control, bool visible)
    {
        int row = panel.GetRow(control);
        control.Visible = visible;
        if (panel.GetControlFromPosition(0, row) is Control label) label.Visible = visible;
        panel.RowStyles[row].SizeType = visible ? SizeType.AutoSize : SizeType.Absolute;
        panel.RowStyles[row].Height = 0;
    }
    private void Field(TableLayoutPanel p, string key, string label, string value, bool secret = false) { var box = new TextBox { Text = value, UseSystemPasswordChar = secret }; fields[key] = box; Add(p, label, box); }
    private sealed record Option(string Value, string Label) { public override string ToString() => Label; }
    private static string Caption(string key, string value) => (key, value) switch
    {
        ("Mode", "local") => "本地识别（离线）", ("Mode", "api") => "HTTP 转录 API", ("Mode", "stream") => "千问流式识别", ("Mode", "live") => "LiveTranslate 实时翻译",
        ("TranslationProvider", "local") => "本地模型（离线）", ("TranslationProvider", "api") => "已保存的 API 服务",
        ("EndpointMode", "smart") => "智能定句", ("EndpointMode", "fixed") => "固定停顿",
        ("LiveTiming", "streaming") => "边说边播放", ("LiveTiming", "final") => "定稿后播放",
        ("Appearance", "system") => "跟随系统", ("Appearance", "light") => "浅色", ("Appearance", "dark") => "深色",
        (_, "auto") => "自动", (_, "cpu") => "CPU", (_, "cuda") => "NVIDIA CUDA", ("Language", "Chinese") => "中文", ("Language", "Cantonese") => "粤语", ("Language", "Japanese") => "日本語", ("Language", "Korean") => "한국어",
        _ => value
    };
    private void Choice(TableLayoutPanel p, string key, string label, string[] items, string value) { var box = new ComboBox { DropDownStyle = ComboBoxStyle.DropDownList }; box.Items.AddRange(items.Select(v => (object)new Option(v, Caption(key, v))).ToArray()); box.SelectedIndex = Math.Max(0, Array.IndexOf(items, value)); choices[key] = box; Add(p, label, box); }
    private void Check(TableLayoutPanel p, string key, string label, bool value) { var box = new CheckBox { Text = label, Checked = value, AutoSize = true }; checks[key] = box; Add(p, "", box); }
    private void Number(TableLayoutPanel p, string key, string label, int value, int min, int max) { var box = new NumericUpDown { Minimum = min, Maximum = max, Value = Math.Clamp(value, min, max) }; numbers[key] = box; Add(p, label, box); }
    private void FileField(TableLayoutPanel p, string key, string label, string value)
    {
        Field(p, key, label, value); var button = Theme.Button("浏览…"); Add(p, "", button);
        button.Click += (_, _) => { using var d = new OpenFileDialog { Filter = "兼容模型|*.gguf;*.bin|所有文件|*.*" }; if (d.ShowDialog(this) == DialogResult.OK) fields[key].Text = d.FileName; };
    }
    private void Preset(string role)
    {
        string prefix = role == "asr" ? "Asr" : "Translator"; var repo = choices[prefix + "Preset"].Text;
        var preset = DesktopBackend.Shared.Models.Presets.FirstOrDefault(p => p.Name == repo); if (preset == null) return;
        fields[prefix + "ModelId"].Text = preset.Repo; fields[prefix + "Revision"].Text = ""; choices[prefix + "Engine"].SelectedItem = choices[prefix + "Engine"].Items.Cast<Option>().Single(o => o.Value == preset.Engine);
        fields[prefix + "Filename"].Text = preset.Files[0].Name;
        if (role == "asr") { checks["UseLocalFile"].Checked = false; fields["AsrProjector"].Text = ""; fields["AsrProjectorFilename"].Text = ""; }
        else fields["TranslatorPath"].Text = "";
    }
    private static string PresetName(string role, string repo, string filename) => DesktopBackend.Shared.Models.Presets.FirstOrDefault(p => p.Role == role && p.Repo == repo && (filename.Length == 0 || p.Files[0].Name == filename))?.Name ?? "自定义";
    private void CudaActions(TableLayoutPanel p)
    {
        var cuda = DesktopBackend.Shared.Cuda; var state = Theme.Label("", 9, Theme.Muted); state.AutoSize = true; state.MaximumSize = new Size(520, 0); Add(p, "GPU 加速组件", state);
        var row = new FlowLayoutPanel { AutoSize = true, WrapContents = false }; var install = Theme.Button("下载 GPU 加速组件"); var remove = Theme.Button("移除"); row.Controls.Add(install); row.Controls.Add(remove); Add(p, "", row);
        void Refresh()
        {
            if (!cuda.KernelsAvailable) { state.Text = "当前为 CPU 精简版，支持 CPU 本地推理和云端服务。需要 NVIDIA GPU 加速请使用标准版。"; install.Visible = remove.Visible = false; return; }
            bool bundled = cuda.Bundled, installed = cuda.Installed;
            state.Text = bundled ? "已随安装包提供 CUDA 运行库。" : installed ? "已安装 NVIDIA CUDA 12.8 运行库和 cuBLAS。" : $"未安装。CUDA 需要约 {cuda.DownloadSize / 1048576.0:0} MiB 的 NVIDIA 运行库（cuBLAS），首次使用时单独下载；“自动”在未安装时使用 CPU。";
            install.Visible = !installed; remove.Visible = installed && !bundled;
        }
        Refresh();
        install.Click += async (_, _) => await RunAsync(async ct =>
        {
            var progress = new Progress<(string Detail, long Completed, long Total)>(e => status.Text = $"{e.Detail}  {FormatSize(e.Completed)} / {FormatSize(e.Total)}");
            await cuda.InstallAsync(progress, ct); Refresh(); status.Text = "GPU 加速组件已安装，选择“自动”或“NVIDIA CUDA”后加载模型即可使用。";
        });
        remove.Click += (_, _) =>
        {
            if (DesktopBackend.Shared.Core.ActiveAsrDevice == "cuda" || DesktopBackend.Shared.Core.Runtime.TranslatorDevice == "cuda" && DesktopBackend.Shared.Core.TranslationReady) { status.Text = "模型正在使用 CUDA，请先切换到 CPU 并加载后再移除。"; return; }
            try { cuda.Uninstall(); Refresh(); status.Text = "已移除 GPU 加速组件。"; } catch (Exception ex) { status.Text = ex.Message; }
        };
    }
    private void ModelActions(TableLayoutPanel p, string role)
    {
        var button = Theme.Button("下载并加载模型", true); Add(p, "", button);
        button.Click += async (_, _) => await RunAsync(async ct => { await DesktopBackend.Shared.ApplyAsync(Read(), true, role, ct); status.Text = "下载、校验与预热完成。"; });
        var list = Theme.Button("列出仓库文件"); Add(p, "", list);
        list.Click += async (_, _) => await RunAsync(async ct =>
        {
            string prefix = role == "asr" ? "Asr" : "Translator";
            var files = await DesktopBackend.Shared.Models.ListFilesAsync(fields[prefix + "ModelId"].Text.Trim(), fields[prefix + "Revision"].Text.Trim(), ct);
            using var dialog = new Form { Text = "选择权重文件", Size = new(700, 500) }; Theme.Style(dialog); dialog.StartPosition = FormStartPosition.CenterParent;
            var box = new ListBox { Dock = DockStyle.Fill }; box.Items.AddRange(files.Cast<object>().ToArray()); dialog.Controls.Add(box);
            box.DoubleClick += (_, _) => { if (box.SelectedItem is string name) { fields[prefix + "Filename"].Text = name; dialog.Close(); } }; dialog.ShowDialog(this);
        });
    }
    private AppSettings Read()
    {
        bool liveMode = workflow.LiveMode;
        var next = current with { };
        bool Include(string key) => !liveMode || key == "Appearance" || key.StartsWith("Live", StringComparison.Ordinal);
        foreach (var (key, box) in fields.Where(entry => Include(entry.Key))) { if (key.EndsWith("Secret")) { if (box.Text.Length > 0) typeof(AppSettings).GetProperty(key)!.SetValue(next, SettingsStore.Protect(box.Text)); } else typeof(AppSettings).GetProperty(key)!.SetValue(next, box.Text.Trim()); }
        foreach (var (key, box) in choices.Where(entry => Include(entry.Key))) if (!key.EndsWith("Preset")) { var value = ((Option)box.SelectedItem!).Value; typeof(AppSettings).GetProperty(key)!.SetValue(next, key is "TargetLanguage" or "LiveTargetLanguage" ? FullSettingsStore.TargetCode(value) : value); }
        foreach (var (key, box) in checks.Where(entry => Include(entry.Key))) typeof(AppSettings).GetProperty(key)!.SetValue(next, box.Checked);
        foreach (var (key, box) in numbers.Where(entry => Include(entry.Key))) typeof(AppSettings).GetProperty(key)!.SetValue(next, key == "LiveVolume" ? (object)((float)box.Value / 100) : (int)box.Value);
        if (liveMode)
        {
            next.Mode = "live";
            next.RegularMode = current.RecognitionMode;
            if (!Uri.TryCreate(next.LiveEndpoint, UriKind.Absolute, out var endpoint) || endpoint.Scheme != "wss" || endpoint.Host.Length == 0 || endpoint.UserInfo.Length > 0)
                throw new InvalidDataException("请填写有效的 LiveTranslate WSS 服务地址。");
            return next;
        }
        next.RegularMode = next.Mode;
        if (next.SmartFallbackSilenceMs < next.SmartSentenceSilenceMs + 200) throw new InvalidDataException("兜底停顿至少应比完整句停顿长 200 毫秒。");
        next.RecognitionConfig().Validate(); next.TranslationConfig().Validate(); next.RuntimeConfig().Validate(); return next;
    }
    private async Task RunAsync(Func<CancellationToken, Task> action)
    {
        if (operation != null) return; using var token = new CancellationTokenSource(); operation = token; save.Enabled = workflow.Enabled = tabs.Enabled = false;
        try { await action(token.Token); } catch (OperationCanceledException) { await DesktopBackend.Shared.Channel.ControlAsync(DesktopBackend.Command("cancel_operation")); status.Text = "操作已取消，下载进度已保留。"; } catch (Exception ex) { status.Text = ex.Message; }
        finally { operation = null; if (!IsDisposed) save.Enabled = workflow.Enabled = tabs.Enabled = true; }
    }
    private void Progress(JsonObject message)
    {
        if (IsDisposed || !IsHandleCreated) return;
        try { BeginInvoke(() => { if ((string?)message["type"] == "progress") status.Text = $"{message["detail"]}  {FormatSize(BackendJson.Integer(message["completed"]))} / {FormatSize(BackendJson.Integer(message["total"]))}"; else if (message["detail"] is JsonNode detail) status.Text = detail + ((string?)message["device"] is string device && device.Length > 0 ? " · " + device.ToUpperInvariant() : ""); }); } catch (InvalidOperationException) { }
    }
    private static string FormatSize(long bytes) => bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):0.00} GiB" : $"{bytes / 1048576.0:0.0} MiB";
}
