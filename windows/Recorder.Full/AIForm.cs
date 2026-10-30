using Recorder.Backend;
namespace Recorder.Windows;
internal sealed class AIForm : Form
{
    private readonly RichTextBox output = new() { Dock = DockStyle.Fill, ReadOnly = true, BackColor = Color.White, Font = Theme.Body(11) };
    private readonly TextBox question = new() { Dock = DockStyle.Fill, Text = "总结主要内容、结论和待办事项。" };
    private readonly Label status = Theme.Label("选择服务后发送。", 9, Theme.Muted);
    private readonly ComboBox profiles = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 320 };
    private readonly ProfileStore store = new(SettingsStore.Root);
    private CancellationTokenSource? pending;
    private readonly string text;
    public AIForm(string text)
    {
        this.text = text; Text = "声笺 · AI 提问"; ClientSize = new(820, 650); Theme.Style(this);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(20), RowCount = 4, ColumnCount = 1 };
        layout.RowStyles.Add(new(SizeType.Absolute, 42)); layout.RowStyles.Add(new(SizeType.Absolute, 48)); layout.RowStyles.Add(new(SizeType.Percent, 100)); layout.RowStyles.Add(new(SizeType.Absolute, 44));
        var toolbar = new FlowLayoutPanel { Dock = DockStyle.Fill }; var configure = Theme.Button("服务设置…"); var summary = Theme.Button("总结"); var translate = Theme.Button("文本翻译"); toolbar.Controls.AddRange([profiles, configure, summary, translate]); layout.Controls.Add(toolbar);
        layout.Controls.Add(question); layout.Controls.Add(output);
        var footer = new FlowLayoutPanel { Dock = DockStyle.Fill }; var send = Theme.Button("发送", true); var cancel = Theme.Button("取消"); var copy = Theme.Button("复制"); var save = Theme.Button("保存…"); footer.Controls.AddRange([send, cancel, copy, save, status]); layout.Controls.Add(footer); Controls.Add(layout);
        void Reload() { profiles.Items.Clear(); foreach (var p in store.Load()) profiles.Items.Add(p.BaseUrl); var selected = SettingsStore.Load().AiProfileId; var all = store.Load(); profiles.SelectedIndex = all.Count == 0 ? -1 : Math.Max(0, all.ToList().FindIndex(p => p.Id == selected)); }
        Reload(); configure.Click += (_, _) => { using var form = new ProfilesForm(); form.ShowDialog(this); Reload(); };
        summary.Click += (_, _) => question.Text = "总结主要内容、结论和待办事项。";
        translate.Click += (_, _) => question.Text = "将全文翻译为" + Languages.Target(SettingsStore.Load().TargetLanguage) + "。";
        send.Click += async (_, _) =>
        {
            if (pending != null) return;
            using var ct = new CancellationTokenSource(); pending = ct; send.Enabled = false; output.Clear();
            try
            {
                var profile = store.Load().Single(p => p.BaseUrl == profiles.Text); await using var client = new ChatClient(profile, store.Key(profile));
                await foreach (var delta in client.StreamAsync(ChatClient.Question(question.Text, text), 4096, ct.Token)) output.AppendText(delta);
                status.Text = "已完成";
            }
            catch (OperationCanceledException) { status.Text = ct.IsCancellationRequested ? "已取消，保留已收到的内容。" : "服务响应超时，保留已收到的内容。"; }
            catch (Exception ex) { status.Text = ex.Message; }
            finally { pending = null; if (!IsDisposed) send.Enabled = true; }
        };
        cancel.Click += (_, _) => pending?.Cancel();
        copy.Click += (_, _) => { if (output.TextLength > 0) { try { Clipboard.SetText(output.Text); } catch (Exception ex) { status.Text = ex.Message; } } };
        save.Click += (_, _) => { using var d = new SaveFileDialog { Filter = "文本|*.txt" }; if (d.ShowDialog(this) == DialogResult.OK) File.WriteAllText(d.FileName, output.Text); };
        FormClosing += (_, e) => { if (pending != null) { pending.Cancel(); e.Cancel = true; status.Text = "正在取消，请稍后关闭。"; } };
    }
}
internal sealed class ProfilesForm : Form
{
    private readonly ProfileStore store = new(SettingsStore.Root);
    private readonly ListBox profiles = new() { Dock = DockStyle.Fill };
    private readonly TextBox url = new() { Dock = DockStyle.Fill }, model = new() { Dock = DockStyle.Fill }, key = new() { Dock = DockStyle.Fill, UseSystemPasswordChar = true };
    private readonly Label status = Theme.Label("API Key 空白时保留已有密钥。", 9, Theme.Muted);
    private CancellationTokenSource? pending;
    public string SelectedId { get; private set; } = "";
    public ProfilesForm()
    {
        Text = "声笺 · API 服务"; ClientSize = new(730, 510); Theme.Style(this);
        var layout = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new(20), RowCount = 7, ColumnCount = 2 };
        layout.ColumnStyles.Add(new(SizeType.Absolute, 95)); layout.ColumnStyles.Add(new(SizeType.Percent, 100));
        layout.RowStyles.Add(new(SizeType.Percent, 100)); for (int i = 1; i < 7; i++) layout.RowStyles.Add(new(SizeType.Absolute, 42));
        layout.Controls.Add(profiles, 0, 0); layout.SetColumnSpan(profiles, 2);
        void Field(int row, string label, Control box) { layout.Controls.Add(Theme.Label(label, 9), 0, row); layout.Controls.Add(box, 1, row); }
        Field(1, "Base URL", url); Field(2, "模型", model); Field(3, "API Key", key);
        var buttons = new FlowLayoutPanel { Dock = DockStyle.Fill }; var add = Theme.Button("保存服务"); var select = Theme.Button("选择", true); var delete = Theme.Button("删除服务"); var test = Theme.Button("连接测试"); var cancel = Theme.Button("取消测试"); buttons.Controls.AddRange([add, select, delete, test, cancel]); layout.Controls.Add(buttons, 0, 4); layout.SetColumnSpan(buttons, 2); layout.Controls.Add(status, 0, 5); layout.SetColumnSpan(status, 2); Controls.Add(layout);
        void Reload() { profiles.Items.Clear(); profiles.Items.AddRange(store.Load().Select(p => (object)p.BaseUrl).ToArray()); if (store.Issues.Count > 0) status.Text = $"忽略了 {store.Issues.Count} 个损坏配置，其余服务仍可使用。"; }
        Reload(); var settings = SettingsStore.Load(); url.Text = settings.TranslationBase; model.Text = settings.TranslationModel;
        profiles.SelectedIndexChanged += (_, _) => { if (profiles.SelectedItem is string address) { var p = store.Load().Single(p => p.BaseUrl == address); url.Text = p.BaseUrl; model.Text = p.Model; key.Clear(); } };
        add.Click += (_, _) => { try { var p = new ServiceProfile(ServiceProfile.Normalize(url.Text), model.Text.Trim()); store.Save(p, key.Text.Trim()); key.Clear(); Reload(); profiles.SelectedItem = p.BaseUrl; status.Text = "服务已保存。"; } catch (Exception ex) { status.Text = ex.Message; } };
        select.Click += (_, _) => { try { var p = store.Load().Single(p => p.BaseUrl == profiles.Text); SelectedId = p.Id; SettingsStore.Save(SettingsStore.Load() with { AiProfileId = p.Id }); DialogResult = DialogResult.OK; } catch (Exception ex) { status.Text = ex.Message; } };
        delete.Click += (_, _) => { try { store.Delete(store.Load().Single(p => p.BaseUrl == profiles.Text)); Reload(); status.Text = "已删除服务及其密钥。"; } catch (Exception ex) { status.Text = ex.Message; } };
        test.Click += async (_, _) =>
        {
            if (pending != null) return; using var ct = new CancellationTokenSource(TimeSpan.FromSeconds(30)); pending = ct; test.Enabled = false;
            try { var p = new ServiceProfile(ServiceProfile.Normalize(url.Text), model.Text.Trim()); await using var client = new ChatClient(p, key.Text.Length > 0 ? key.Text : store.Key(p)); await foreach (var ignored in client.StreamAsync([new("user", "Reply OK.")], 8, ct.Token)) { } status.Text = "连接成功。"; }
            catch (Exception ex) { status.Text = ct.IsCancellationRequested ? "测试已取消或超时。" : ex.Message; }
            finally { pending = null; test.Enabled = true; }
        };
        cancel.Click += (_, _) => pending?.Cancel(); FormClosing += (_, e) => { if (pending != null) { pending.Cancel(); e.Cancel = true; } };
    }
}
