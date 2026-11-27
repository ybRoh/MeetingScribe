using System.Diagnostics;
using System.Text;
using System.Text.RegularExpressions;
using System.Text.Json;
using NAudio.Wave;

namespace MeetingScribe;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        ApplicationConfiguration.Initialize();
        Application.Run(new MeetingWindow());
    }
}

internal sealed class MeetingWindow : Form
{
    private readonly CheckBox consent = new() { Text = "참석자 동의를 확인했습니다", AutoSize = true };
    private readonly Button start = new() { Text = "기록 시작", AutoSize = true };
    private readonly Button stop = new() { Text = "기록 종료", AutoSize = true, Enabled = false };
    private readonly Button cancelProcessing = new() { Text = "처리 취소", AutoSize = true, Visible = false };
    private readonly Button recovery = new() { Text = "복구 열기", AutoSize = true };
    private readonly Button retry = new() { Text = "다시 시도", AutoSize = true, Visible = false };
    private readonly Button keep = new() { Text = "녹음 파일 보관", AutoSize = true, Visible = false };
    private readonly ComboBox microphones = new() { DropDownStyle = ComboBoxStyle.DropDownList, Width = 200 };
    private static readonly string RecoveryRoot = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MeetingScribe", "Recordings");
    private static readonly string GlossaryPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MeetingScribe", "glossary.txt");
    private string glossary = "";
    private readonly Label status = new() { Text = "대면 회의 · 마이크만", AutoSize = true };
    private readonly TextBox minutes = Editor();
    private readonly TextBox transcript = Editor();
    private WaveInEvent? input;
    private WaveFileWriter? writer;
    private string? workFolder;
    private bool processing;
    private CancellationTokenSource? processingCancellation;
    private sealed record CompletedMeeting(string Transcript, string Minutes);

    public MeetingWindow()
    {
        Text = "회의록 서기";
        MinimumSize = new Size(680, 480);
        Size = new Size(850, 650);
        StartPosition = FormStartPosition.CenterScreen;
        Font = new Font("Malgun Gothic", 10F);
        var grid = new TableLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(12), ColumnCount = 1, RowCount = 4 };
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        grid.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        grid.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        var actions = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        for (int i = 0; i < WaveInEvent.DeviceCount; i++)
            microphones.Items.Add(WaveInEvent.GetCapabilities(i).ProductName);
        if (microphones.Items.Count > 0) microphones.SelectedIndex = 0;
        microphones.AccessibleName = "마이크";
        var terms = new Button { Text = "용어집", AutoSize = true };
        terms.Click += (_, _) => EditGlossary();
        actions.Controls.AddRange(new Control[] { microphones, consent, start, stop, retry, keep, cancelProcessing, recovery, terms });
        var tabs = new TabControl { Dock = DockStyle.Fill };
        var minutesTab = new TabPage("회의록");
        var transcriptTab = new TabPage("한국어 받아쓰기");
        minutesTab.Controls.Add(minutes);
        transcriptTab.Controls.Add(transcript);
        tabs.TabPages.AddRange(new[] { minutesTab, transcriptTab });
        var copy = new Button { Text = "복사", AutoSize = true };
        var save = new Button { Text = "파일 저장", AutoSize = true };
        var exports = new FlowLayoutPanel { Dock = DockStyle.Fill, AutoSize = true };
        exports.Controls.AddRange(new Control[] { copy, save });
        grid.Controls.Add(actions, 0, 0);
        grid.Controls.Add(status, 0, 1);
        grid.Controls.Add(tabs, 0, 2);
        grid.Controls.Add(exports, 0, 3);
        Controls.Add(grid);
        start.Enabled = false;
        consent.CheckedChanged += (_, _) => start.Enabled = consent.Checked && input == null && !processing;
        start.Click += (_, _) => StartRecording();
        cancelProcessing.Click += (_, _) => processingCancellation?.Cancel();
        recovery.Click += (_, _) => ShowRecovery();
        retry.Click += async (_, _) => await ProcessRecording();
        keep.Click += (_, _) => SaveRecording();
        Shown += (_, _) =>
        {
            try { if (File.Exists(GlossaryPath)) glossary = File.ReadAllText(GlossaryPath, Encoding.UTF8); }
            catch (Exception error) { ShowError(error); }
            OfferRecovery();
        };
        stop.Click += (_, _) => { stop.Enabled = false; input?.StopRecording(); };
        copy.Click += (_, _) =>
        {
            string text = tabs.SelectedTab == transcriptTab ? transcript.Text : minutes.Text;
            if (!string.IsNullOrWhiteSpace(text)) Clipboard.SetText(text);
        };
        save.Click += (_, _) => Save(tabs.SelectedTab == transcriptTab ? transcript.Text : minutes.Text);
        FormClosing += (_, e) =>
        {
            if (input == null && !processing)
            {
                if (workFolder != null || (string.IsNullOrWhiteSpace(minutes.Text) && string.IsNullOrWhiteSpace(transcript.Text))) return;
                e.Cancel = MessageBox.Show(this, "저장할 내용이 있다면 먼저 저장하세요. 창을 닫을까요?",
                    Text, MessageBoxButtons.YesNo) != DialogResult.Yes;
                return;
            }
            e.Cancel = true;
            status.Text = "기록 종료 후 처리가 끝나면 창을 닫을 수 있습니다.";
        };
    }

    private static TextBox Editor() => new()
    {
        Dock = DockStyle.Fill, Multiline = true, ScrollBars = ScrollBars.Vertical, AcceptsReturn = true
    };

    private void StartRecording()
    {
        try
        {
            Engines.CheckFiles();
            if (microphones.SelectedIndex < 0) throw new InvalidOperationException("사용 가능한 마이크가 없습니다.");
            if ((!string.IsNullOrWhiteSpace(minutes.Text) || !string.IsNullOrWhiteSpace(transcript.Text)) &&
                MessageBox.Show(this, "새 회의를 시작하면 현재 내용이 지워집니다. 시작할까요?",
                    Text, MessageBoxButtons.YesNo) != DialogResult.Yes) return;

            if (RecordingAvailable() && MessageBox.Show(this,
                "이전 녹음은 복구 폴더에 남습니다. 새 회의를 시작할까요?", Text, MessageBoxButtons.YesNo) != DialogResult.Yes)
                return;
            workFolder = Path.Combine(RecoveryRoot, Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(workFolder);
            SetRecoveryButtons(false);
            input = new WaveInEvent { DeviceNumber = microphones.SelectedIndex, WaveFormat = new WaveFormat(16000, 16, 1) };
            writer = new WaveFileWriter(Path.Combine(workFolder, "recording.wav"), input.WaveFormat);
            var flushClock = Stopwatch.StartNew();
            input.DataAvailable += (_, e) =>
            {
                writer?.Write(e.Buffer, 0, e.BytesRecorded);
                if (flushClock.Elapsed >= TimeSpan.FromSeconds(5))
                {
                    writer?.Flush();
                    flushClock.Restart();
                }
            };
            input.RecordingStopped += async (_, e) => await FinishRecording(e.Exception);
            input.StartRecording();
            minutes.Clear();
            transcript.Clear();
            start.Enabled = false;
            stop.Enabled = true;
            consent.Enabled = false;
            microphones.Enabled = false;
            recovery.Enabled = false;
            status.Text = "녹음 중 · 기록 종료 후 한국어 받아쓰기를 시작합니다.";
        }
        catch (Exception error)
        {
            ReleaseRecording();
            if (RecordingAvailable()) SetRecoveryButtons(true);
            else RemoveTemporaryFiles();
            ShowError(error);
        }
    }

    private async Task FinishRecording(Exception? captureError)
    {
        stop.Enabled = false;
        try
        {
            ReleaseRecording();
            if (captureError != null) throw captureError;
        }
        catch (Exception error)
        {
            ShowError(error);
            SetRecoveryButtons(RecordingAvailable());
            RestoreControls();
            return;
        }
        await ProcessRecording();
    }

    private async Task ProcessRecording()
    {
        if (processing || !RecordingAvailable()) return;
        processing = true;
        using var cancellation = new CancellationTokenSource();
        processingCancellation = cancellation;
        cancelProcessing.Visible = true;
        recovery.Enabled = false;
        start.Enabled = false;
        consent.Enabled = false;
        microphones.Enabled = false;
        SetRecoveryButtons(false);
        try
        {
            Engines.CheckFiles();
            status.Text = "한국어로 받아쓰는 중입니다.";
            string terms = glossary;
            transcript.Text = await Engines.Transcribe(workFolder!, terms, cancellation.Token);
            if (string.IsNullOrWhiteSpace(transcript.Text))
            {
                status.Text = "인식한 발언이 없습니다. 녹음 파일은 보관했습니다.";
                return;
            }

            status.Text = "회의록을 생성하는 중입니다.";
            minutes.Text = await Engines.Summarize(workFolder!, transcript.Text, terms, cancellation.Token);
            SaveCompletedMeeting();
            status.Text = "완료 · 내용을 확인한 뒤 복사하거나 저장하세요.";
            RemoveProcessedAudio();
        }
        catch (OperationCanceledException) { status.Text = "처리를 취소했습니다. 녹음은 보관했습니다."; }
        catch (Exception error) { ShowError(error); }
        finally
        {
            processingCancellation = null;
            cancelProcessing.Visible = false;
            SetRecoveryButtons(RecordingAvailable());
            RestoreControls();
        }
    }

    private void RestoreControls()
    {
        processing = false;
        consent.Enabled = true;
        microphones.Enabled = true;
        recovery.Enabled = true;
        consent.Checked = false;
        start.Enabled = false;
    }

    private string? RecordingPath => workFolder == null ? null : Path.Combine(workFolder, "recording.wav");

    private bool RecordingAvailable()
    {
        try { return RecordingPath is string path && new FileInfo(path).Length > 46; }
        catch (IOException) { return false; }
        catch (UnauthorizedAccessException) { return false; }
    }

    private void SetRecoveryButtons(bool available) => retry.Visible = keep.Visible = available;

    private static FileInfo[] RecoverableFiles()
    {
        if (!Directory.Exists(RecoveryRoot)) return [];
        return Directory.EnumerateDirectories(RecoveryRoot)
            .SelectMany(folder => new[] { new FileInfo(Path.Combine(folder, "meeting.json")), new FileInfo(Path.Combine(folder, "recording.wav")) })
            .Where(file => file.Exists && (file.Extension == ".json" || file.Length > 46))
            .OrderByDescending(file => file.LastWriteTimeUtc)
            .ToArray();
    }

    private void OfferRecovery()
    {
        try
        {
            if (RecoverableFiles().Length > 0 &&
                MessageBox.Show(this, "보관된 회의가 있습니다. 복구할 회의를 고를까요?",
                    Text, MessageBoxButtons.YesNo) == DialogResult.Yes) ShowRecovery();
        }
        catch (Exception error) { ShowError(error); }
    }

    private void ShowRecovery()
    {
        if (input != null || processing) return;
        try
        {
            var files = RecoverableFiles();
            if (files.Length == 0) { status.Text = "복구할 회의가 없습니다."; return; }
            using var dialog = new Form { Text = "복구할 회의", Size = new Size(525, 310),
                StartPosition = FormStartPosition.CenterParent };
            var list = new ListBox { Dock = DockStyle.Fill };
            foreach (var file in files)
                list.Items.Add($"{file.LastWriteTime:g} · {(file.Extension == ".json" ? "처리 완료 회의록" : "녹음")}");
            list.SelectedIndex = 0;
            var open = new Button { Text = "열기", Dock = DockStyle.Bottom, DialogResult = DialogResult.OK };
            dialog.Controls.Add(list);
            dialog.Controls.Add(open);
            dialog.AcceptButton = open;
            if (dialog.ShowDialog(this) != DialogResult.OK || list.SelectedIndex < 0) return;
            var selected = files[list.SelectedIndex];
            if ((!string.IsNullOrWhiteSpace(minutes.Text) || !string.IsNullOrWhiteSpace(transcript.Text)) &&
                MessageBox.Show(this, "현재 편집 중인 내용을 닫고 선택한 회의를 열까요?", Text, MessageBoxButtons.YesNo)
                != DialogResult.Yes) return;
            if (selected.Extension == ".json")
            {
                var saved = JsonSerializer.Deserialize<CompletedMeeting>(File.ReadAllText(selected.FullName))
                    ?? throw new InvalidDataException("회의록을 읽을 수 없습니다.");
                transcript.Text = saved.Transcript;
                minutes.Text = saved.Minutes;
                workFolder = null;
                status.Text = "보관된 회의록을 열었습니다.";
            }
            else
            {
                workFolder = selected.DirectoryName;
                transcript.Clear();
                minutes.Clear();
                status.Text = "녹음을 복구했습니다. 다시 시도하거나 WAV 파일로 보관하세요.";
            }
            SetRecoveryButtons(RecordingAvailable());
        }
        catch (Exception error) { ShowError(error); }
    }

    private void SaveCompletedMeeting()
    {
        string path = Path.Combine(workFolder!, "meeting.json");
        File.WriteAllText(path + ".new", JsonSerializer.Serialize(new CompletedMeeting(transcript.Text, minutes.Text)));
        File.Move(path + ".new", path, overwrite: true);
    }

    private void RemoveProcessedAudio()
    {
        if (workFolder == null) return;
        foreach (var file in new[] { "recording.wav", "transcript.txt", "prompt.txt" })
        {
            try { File.Delete(Path.Combine(workFolder, file)); }
            catch (IOException) { status.Text += " 처리용 파일을 지우지 못했습니다."; }
            catch (UnauthorizedAccessException) { status.Text += " 처리용 파일을 지우지 못했습니다."; }
        }
        workFolder = null;
    }

    private void SaveRecording()
    {
        if (!RecordingAvailable()) return;
        using var dialog = new SaveFileDialog
        {
            Filter = "WAV (*.wav)|*.wav", FileName = $"회의녹음-{DateTime.Today:yyyy-MM-dd}.wav"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            File.Copy(RecordingPath!, dialog.FileName, overwrite: true);
            status.Text = "녹음 사본을 저장했습니다.";
        }
        catch (Exception error) { ShowError(error); }
    }

    private void ReleaseRecording()
    {
        input?.Dispose();
        input = null;
        writer?.Dispose();
        writer = null;
    }

    private void RemoveTemporaryFiles()
    {
        if (workFolder == null) return;
        try { Directory.Delete(workFolder, recursive: true); }
        catch (IOException) { status.Text += " 임시 파일을 지우지 못했습니다."; }
        catch (UnauthorizedAccessException) { status.Text += " 임시 파일을 지우지 못했습니다."; }
        workFolder = null;
    }

    private void ShowError(Exception error)
    {
        status.Text = RecordingAvailable() ? "처리 오류 · 녹음은 복구 폴더에 보관했습니다." : "오류가 발생했습니다.";
        MessageBox.Show(this, error.Message, Text, MessageBoxButtons.OK, MessageBoxIcon.Error);
    }

    private void EditGlossary()
    {
        using var dialog = new Form { Text = "사내 용어집", Size = new Size(500, 320),
            StartPosition = FormStartPosition.CenterParent };
        var editor = Editor();
        editor.Text = glossary;
        editor.AccessibleName = "회사명, 제품명, 참석자 이름, 약어";
        var label = new Label { Dock = DockStyle.Top, Text = editor.AccessibleName };
        var save = new Button { Text = "저장", Dock = DockStyle.Bottom, DialogResult = DialogResult.OK };
        dialog.Controls.Add(editor);
        dialog.Controls.Add(label);
        dialog.Controls.Add(save);
        dialog.AcceptButton = save;
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(GlossaryPath)!);
            File.WriteAllText(GlossaryPath + ".new", editor.Text, Encoding.UTF8);
            File.Move(GlossaryPath + ".new", GlossaryPath, overwrite: true);
            glossary = editor.Text;
        }
        catch (Exception error) { ShowError(error); }
    }

    private void Save(string text)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        using var dialog = new SaveFileDialog
        {
            Filter = "Markdown (*.md)|*.md|Word (*.docx)|*.docx", FileName = $"회의록-{DateTime.Today:yyyy-MM-dd}"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK) return;
        try
        {
            if (Path.GetExtension(dialog.FileName).Equals(".docx", StringComparison.OrdinalIgnoreCase))
                WordExport.Save(text, dialog.FileName, Path.Combine(AppContext.BaseDirectory, "Word"));
            else
                File.WriteAllText(dialog.FileName, text, Encoding.UTF8);
        }
        catch (Exception error) { ShowError(error); }
    }
}

internal static class Engines
{
    private static readonly string Root = AppContext.BaseDirectory;
    private static readonly string Whisper = Path.Combine(Root, "engines", "whisper", "whisper-cli.exe");
    private static readonly string Llama = Path.Combine(Root, "engines", "llama", "llama-completion.exe");
    private static readonly string SpeechModel = Path.Combine(Root, "models", "ggml-large-v3-turbo-q5_0.bin");
    private static readonly string MinutesModel = Path.Combine(Root, "models", "Qwen3-4B-Q4_K_M.gguf");
    private static readonly string Threads = Math.Clamp(Environment.ProcessorCount, 1, 8).ToString();

    public static void CheckFiles()
    {
        foreach (string path in new[] { Whisper, Llama, SpeechModel, MinutesModel })
            if (!File.Exists(path))
                throw new FileNotFoundException($"필수 파일을 찾을 수 없습니다. ZIP 전체를 압축 해제하세요.\n{Path.GetFileName(path)}");
    }

    public static async Task<string> Transcribe(string folder, string glossary, CancellationToken cancellation)
    {
        string output = Path.Combine(folder, "transcript");
        await Run(Whisper, cancellation, "-m", SpeechModel, "-f", Path.Combine(folder, "recording.wav"),
            "-l", "ko", "-t", Threads, "-ng", "-nth", "0.5", "--prompt", LimitGlossary(glossary, 400),
            "-otxt", "-of", output);
        return (await File.ReadAllTextAsync(output + ".txt", Encoding.UTF8, cancellation)).Trim();
    }

    public static async Task<string> Summarize(string folder, string transcript, string glossary, CancellationToken cancellation)
    {
        string draft = "";
        string instructions = await File.ReadAllTextAsync(Path.Combine(Root, "MinutesPrompt.txt"), Encoding.UTF8);
        string promptPath = Path.Combine(folder, "prompt.txt");
        string terms = LimitGlossary(glossary, 1200).Replace("<|", "< |");
        // Whole lines, about 3000 characters each: fewer model runs than fixed
        // 2500-character cuts, and no sentence is split between two prompts.
        foreach (string chunk in TranscriptChunks.Split(transcript))
        {
            string incoming = chunk.Replace("<|", "< |");
            string prompt = $"""
                <|im_start|>system
                {instructions.TrimEnd()}<|im_end|>
                <|im_start|>user
                <표기용어>
                {terms}
                </표기용어>
                <이전초안>
                {draft.Replace("<|", "< |")}
                </이전초안>
                <새발언>
                {incoming}
                </새발언>
                /no_think<|im_end|>
                <|im_start|>assistant
                <think>

                </think>

                """;
            await File.WriteAllTextAsync(promptPath, prompt, new UTF8Encoding(false), cancellation);
            string result = await Run(Llama, cancellation, "-m", MinutesModel, "-f", promptPath, "--no-conversation",
                "--no-display-prompt", "--simple-io", "-n", "3000", "-c", "16384",
                "-t", Threads, "--temp", "0.15");
            if (!result.Contains("[end of text]", StringComparison.Ordinal))
                throw new InvalidOperationException("회의록 생성이 끝까지 완료되지 않았습니다. 녹음은 보관했습니다.");
            result = result.Replace("[end of text]", "");
            result = Regex.Replace(result, @"\x1B\[[0-?]*[ -/]*[@-~]", "");
            int thoughtEnd = result.LastIndexOf("</think>", StringComparison.Ordinal);
            if (thoughtEnd >= 0) result = result[(thoughtEnd + 8)..];
            int heading = result.IndexOf("## 주요 논의", StringComparison.Ordinal);
            draft = (heading >= 0 ? result[heading..] : result).Trim();
            if (draft.Length == 0) throw new InvalidOperationException("회의록 생성 결과가 비어 있습니다.");
            draft = ToDoList.AtEnd(draft);
        }
        return draft;
    }

    private static string LimitGlossary(string text, int limit) => string.Concat(text.EnumerateRunes().Take(limit));

    private static async Task<string> Run(string executable, CancellationToken cancellation, params string[] arguments)
    {
        cancellation.ThrowIfCancellationRequested();
        var config = new ProcessStartInfo(executable)
        {
            UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true,
            RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8, WorkingDirectory = Path.GetDirectoryName(executable)!
        };
        foreach (string argument in arguments) config.ArgumentList.Add(argument);
        using var process = Process.Start(config) ?? throw new InvalidOperationException("실행 엔진을 시작할 수 없습니다.");
        var output = process.StandardOutput.ReadToEndAsync();
        var errors = process.StandardError.ReadToEndAsync();
        try { await process.WaitForExitAsync(cancellation); }
        catch (OperationCanceledException)
        {
            try { if (!process.HasExited) process.Kill(entireProcessTree: true); }
            catch (InvalidOperationException) when (process.HasExited) { }
            await process.WaitForExitAsync();
            throw;
        }
        string result = await output;
        string diagnostic = await errors;
        if (unchecked((uint)process.ExitCode) == 0xC0000135)
            throw new InvalidOperationException("실행 엔진의 DLL을 찾지 못했습니다. Microsoft Visual C++ Redistributable x64를 설치하고 ZIP을 전체 압축 해제했는지 확인하세요.");
        if (process.ExitCode != 0)
            throw new InvalidOperationException($"{Path.GetFileName(executable)} 실행 오류 (0x{process.ExitCode:X8})\n{diagnostic[Math.Max(0, diagnostic.Length - 650)..]}");
        return result;
    }
}
