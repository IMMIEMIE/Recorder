namespace Recorder.Windows;

internal sealed class SettingsForm : Form
{
    private readonly AppSettings settings;
    private readonly ComboBox mode = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly ComboBox language = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly ComboBox target = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill };
    private readonly NumericUpDown silence = new() { Minimum = 200, Maximum = 6000, Increment = 100, Dock = DockStyle.Fill };
    private readonly CheckBox translate = new() { Text = "对定稿句子启用 API 翻译", AutoSize = true };
    private readonly TextBox modelPath, apiBase, apiModel, apiKey, streamKey, translationBase, translationModel, translationKey, liveEndpoint, liveKey;
    private readonly CancellationTokenSource downloadCancel = new();
    private bool downloading;
    private readonly Button save = Theme.Button("保存", true);
    private readonly Label downloadStatus = Theme.Label("模型约 74 MB，下载后可离线识别。", 9, Theme.Muted);
    private static readonly string[] Modes = ["local", "api", "stream", "live"];
    private static readonly string[] Languages = ["auto", "zh", "en", "ja", "ko", "fr", "de", "es", "ru"];
    private static readonly string[] Targets = ["zh", "zh-TW", "en", "ja", "ko", "fr", "de", "es", "ru"];
    private static TextBox Field(string value, bool secret = false) => new() { Text = value, Dock = DockStyle.Fill, UseSystemPasswordChar = secret, Margin = new(0, 5, 0, 5) };
    public SettingsForm(AppSettings current)
    {
        settings = current;
        Text = "声笺 · 设置"; ClientSize = new(710, 655); MinimumSize = new(650, 570); Theme.Style(this);
        mode.Items.AddRange(["Whisper 本地识别（离线）", "OpenAI 兼容 API", "千问 WebSocket 流式识别", "LiveTranslate 实时翻译（文字）"]);
        mode.SelectedIndex = Math.Max(0, Array.IndexOf(Modes, settings.Mode));
        language.Items.AddRange(["自动检测", "中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"]);
        language.SelectedIndex = Math.Max(0, Array.IndexOf(Languages, settings.Language));
        target.Items.AddRange(["简体中文", "繁體中文", "English", "日本語", "한국어", "Français", "Deutsch", "Español", "Русский"]);
        target.SelectedIndex = Math.Max(0, Array.IndexOf(Targets, settings.TargetLanguage));
        silence.Value = Math.Clamp(settings.SilenceMs, 200, 6000); translate.Checked = settings.Translation;
        modelPath = Field(settings.ModelPath); apiBase = Field(settings.ApiBase); apiModel = Field(settings.ApiModel); apiKey = Field("", true);
        streamKey = Field("", true); translationBase = Field(settings.TranslationBase); translationModel = Field(settings.TranslationModel);
        translationKey = Field("", true); liveEndpoint = Field(settings.LiveEndpoint); liveKey = Field("", true);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(24), ColumnCount = 1, RowCount = 3 };
        layout.RowStyles.Add(new(SizeType.Absolute, 40)); layout.RowStyles.Add(new(SizeType.Percent, 100)); layout.RowStyles.Add(new(SizeType.Absolute, 55));
        layout.Controls.Add(Theme.Label("识别与翻译", 17), 0, 0);
        var tabs = new TabControl { Dock = DockStyle.Fill, Padding = new(16, 8) };
        layout.Controls.Add(tabs, 0, 1);
        var asr = Page(tabs, "转写", out var a);
        Add(a, "识别方式", mode); Add(a, "原文语言", language); Add(a, "停顿定稿（毫秒）", silence);
        Add(a, "API Base URL", apiBase); Add(a, "音频转写模型", apiModel); Add(a, "API Key", apiKey);
        Add(a, "千问流式 API Key", streamKey);
        Note(a, "流式模型：qwen-audio-3.0-asr-flash-streaming\n请使用千问AI平台密钥（非阿里云百炼密钥）。\nAPI / 流式模式会上传所选音频，费用由服务商收取。");
        Page(tabs, "本地模型", out var m);
        Add(m, "GGML 模型文件", modelPath);
        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill };
        var browse = Theme.Button("选择模型…"); var download = Theme.Button("下载 Whisper Tiny", true);
        actions.Controls.Add(browse); actions.Controls.Add(download); Add(m, "", actions);
        browse.Click += (_, _) => { using var dialog = new OpenFileDialog { Filter = "Whisper GGML 模型|*.bin" }; if (dialog.ShowDialog(this) == DialogResult.OK) modelPath.Text = dialog.FileName; };
        download.Click += async (_, _) =>
        {
            if (downloading) { downloadCancel.Cancel(); return; }
            downloading = true; save.Enabled = false; browse.Enabled = false; modelPath.Enabled = false; download.Text = "取消下载";
            var path = Path.Combine(SettingsStore.Root, "models", "ggml-tiny.bin");
            try
            {
                await ModelDownload.DownloadAsync(path, new Progress<int>(p => downloadStatus.Text = $"正在下载及校验模型：{p}%"), downloadCancel.Token);
                modelPath.Text = path; downloadStatus.Text = "模型已下载并通过 SHA256 校验，可保存设置开始识别。";
            }
            catch (OperationCanceledException) { downloadStatus.Text = "下载已取消。"; }
            catch (Exception ex) { downloadStatus.Text = "下载失败：" + ex.Message; }
            finally { downloading = false; save.Enabled = true; browse.Enabled = true; modelPath.Enabled = true; download.Enabled = !downloadCancel.IsCancellationRequested; download.Text = "下载 Whisper Tiny"; }
        };
        Add(m, "", downloadStatus);
        Note(m, "本地识别使用 CPU，不上传音频。\n32 位版建议 Tiny / Base；Tiny 的中文准确率低于大模型。\n也可选择 whisper.cpp 的 Tiny / Base / Small GGML 文件。\nApple MLX / Qwen 本地权重不能在此版本使用。\n首次下载需要联网，模型与程序分开保存。");
        Page(tabs, "逐句翻译", out var t);
        Add(t, "", translate); Add(t, "目标语言", target); Add(t, "API Base URL", translationBase);
        Add(t, "翻译模型", translationModel); Add(t, "API Key", translationKey);
        Note(t, "仅向翻译服务发送定稿原文。\nWindows x86 版使用 API 翻译，尚未移植 MLX 本地翻译。\nLiveTranslate 使用自己的目标语言和密钥，不调用此接口。");
        Page(tabs, "LiveTranslate", out var l);
        Add(l, "WSS 服务地址", liveEndpoint); Add(l, "专用 API Key", liveKey);
        Note(l, "模型：qwen3.8-livetranslate-flash-realtime\n在「转写」页选择 LiveTranslate 后生效。\n目标语言沿用「逐句翻译」页的选择，繁体中文会使用 zh。\n此版本仅接收原文和译文，暂不支持译音播放。\n音频持续上传；密钥须匹配服务地址、区域和工作空间。");
        Page(tabs, "数据与隐私", out var p);
        Note(p, "API Key 由 Windows 当前用户加密，留空保存会保留已有密钥。\n更换服务地址后必须重新填写对应密钥。\n程序不保存录音或文字历史；复制和导出由你主动触发。\n关闭软件后，未导出的文字会被清除。\n系统音频采集包含所有应用的声音，建议使用耳机。\n\n设置和模型目录：\n" + SettingsStore.Root);
        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.RightToLeft, Padding = new(0, 16, 0, 0) };
        footer.Controls.Add(save); var cancel = Theme.Button("取消"); footer.Controls.Add(cancel);
        cancel.Click += (_, _) => Close(); save.Click += (_, _) => SaveSettings();
        layout.Controls.Add(footer, 0, 2); Controls.Add(layout);
        FormClosing += (_, e) => { if (downloading) { downloadCancel.Cancel(); e.Cancel = true; } };
    }
    private static TabPage Page(TabControl tabs, string title, out TableLayoutPanel grid)
    {
        var page = new TabPage(title) { BackColor = Color.White, Padding = new(20), AutoScroll = true };
        grid = new TableLayoutPanel { Dock = DockStyle.Top, AutoSize = true, ColumnCount = 2 };
        grid.ColumnStyles.Add(new(SizeType.Absolute, 155)); grid.ColumnStyles.Add(new(SizeType.Percent, 100));
        page.Controls.Add(grid); tabs.TabPages.Add(page); return page;
    }
    private static void Add(TableLayoutPanel grid, string label, Control control)
    {
        int row = grid.RowCount++; grid.RowStyles.Add(new(SizeType.AutoSize));
        grid.Controls.Add(Theme.Label(label, 9), 0, row); grid.Controls.Add(control, 1, row);
    }
    private static void Note(TableLayoutPanel grid, string text)
    {
        var note = Theme.Label(text, 9, Theme.Muted); note.MaximumSize = new(570, 0); note.Margin = new(0, 16, 0, 10);
        int row = grid.RowCount++; grid.Controls.Add(note, 0, row); grid.SetColumnSpan(note, 2);
    }
    private void SaveSettings()
    {
        try
        {
            var next = settings with { Mode = Modes[mode.SelectedIndex], Language = Languages[language.SelectedIndex], SilenceMs = (int)silence.Value,
                ModelPath = modelPath.Text.Trim(), ApiBase = apiBase.Text.Trim().TrimEnd('/'), ApiModel = apiModel.Text.Trim(),
                Translation = translate.Checked, TargetLanguage = Targets[target.SelectedIndex], TranslationBase = translationBase.Text.Trim().TrimEnd('/'),
                TranslationModel = translationModel.Text.Trim(), LiveEndpoint = liveEndpoint.Text.Trim() };
            if (next.Mode == "api") { ServiceHttp.Endpoint(next.ApiBase, "/audio/transcriptions"); if (next.ApiModel.Length == 0) throw new InvalidOperationException("请填写音频转写模型。"); }
            if (next.Translation) { ServiceHttp.Endpoint(next.TranslationBase, "/chat/completions"); if (next.TranslationModel.Length == 0) throw new InvalidOperationException("请填写翻译模型。"); }
            string Secret(TextBox box, string old, bool changed)
            {
                if (string.IsNullOrWhiteSpace(box.Text)) { if (changed && old.Length > 0) throw new InvalidOperationException("服务地址已更改，请填写新地址对应的 API Key。"); return old; }
                return SettingsStore.Protect(box.Text.Trim());
            }
            next.ApiSecret = Secret(apiKey, settings.ApiSecret, next.ApiBase != settings.ApiBase);
            next.StreamingSecret = Secret(streamKey, settings.StreamingSecret, false);
            next.TranslationSecret = Secret(translationKey, settings.TranslationSecret, next.TranslationBase != settings.TranslationBase);
            next.LiveSecret = Secret(liveKey, settings.LiveSecret, next.LiveEndpoint != settings.LiveEndpoint);
            SettingsStore.Save(next); DialogResult = DialogResult.OK; Close();
        }
        catch (Exception ex) { MessageBox.Show(this, ex.Message, "设置未保存", MessageBoxButtons.OK, MessageBoxIcon.Information); }
    }
}
