using System.Text.Json;
using System.Text.RegularExpressions;
using MimeKit;

namespace FakeSmtp;

public sealed record Envelope(string MailFrom, List<string> RcptTo, string Client, DateTimeOffset ReceivedUtc);

public sealed record MessageSummary(string Id, DateTimeOffset ReceivedUtc, string MailFrom, List<string> RcptTo, string From, string To,
    string Subject, long Size, bool HasHtml, int Attachments);

// Keeps each received message as <id>.eml (exactly the bytes sent after DATA) plus <id>.json (envelope and summary).
public sealed partial class MailStore
{
    private readonly string _folder;
    private readonly ILogger<MailStore> _log;
    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    private readonly int _maxMessages;

    public MailStore(IConfiguration config, IHostEnvironment env, ILogger<MailStore> log)
    {
        var folder = config["FakeSmtp:MailFolder"] ?? "data";
        _folder = Path.GetFullPath(Path.IsPathRooted(folder) ? folder : Path.Combine(env.ContentRootPath, folder));
        Directory.CreateDirectory(_folder);
        _maxMessages = config.GetValue<int?>("FakeSmtp:MaxMessages") ?? 0;
        _log = log;
    }

    public string Folder => _folder;

    [GeneratedRegex("^[0-9]{17}-[0-9a-f]{8}$")]
    private static partial Regex IdPattern();

    public static bool IsValidId(string id) => IdPattern().IsMatch(id);

    public async Task<MessageSummary> SaveAsync(byte[] raw, Envelope envelope, CancellationToken ct)
    {
        var id = $"{envelope.ReceivedUtc:yyyyMMddHHmmssfff}-{Guid.NewGuid().ToString("N")[..8]}";
        await File.WriteAllBytesAsync(EmlPath(id), raw, ct);

        string from = "", to = "", subject = "(unparsed)";
        bool hasHtml = false;
        int attachments = 0;
        try
        {
            using var ms = new MemoryStream(raw);
            var msg = await MimeMessage.LoadAsync(ms, ct);
            from = msg.From.ToString();
            to = msg.To.ToString();
            subject = msg.Subject ?? "";
            hasHtml = msg.HtmlBody is not null;
            attachments = msg.Attachments.Count();
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Message {Id} could not be parsed as MIME; kept raw", id);
        }

        var summary = new MessageSummary(id, envelope.ReceivedUtc, envelope.MailFrom, envelope.RcptTo, from, to, subject, raw.LongLength, hasHtml, attachments);
        await File.WriteAllTextAsync(JsonPath(id), JsonSerializer.Serialize(new { summary, envelope.Client }, Json), ct);
        Prune();
        return summary;
    }

    // Keeps only the newest FakeSmtp:MaxMessages messages (0 = keep everything).
    private void Prune()
    {
        if (_maxMessages <= 0) return;
        foreach (var old in Directory.EnumerateFiles(_folder, "*.eml").OrderByDescending(f => f, StringComparer.Ordinal).Skip(_maxMessages))
        {
            try { Delete(Path.GetFileNameWithoutExtension(old)); }
            catch (IOException ex) { _log.LogWarning(ex, "Could not prune {File}", old); }
        }
    }

    public IEnumerable<MessageSummary> List()
    {
        foreach (var file in Directory.EnumerateFiles(_folder, "*.json").OrderByDescending(f => f, StringComparer.Ordinal))
        {
            MessageSummary? s = null;
            try
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(file));
                s = doc.RootElement.GetProperty("summary").Deserialize<MessageSummary>(Json);
            }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "Skipping unreadable index file {File}", file);
            }
            if (s is not null) yield return s;
        }
    }

    public bool Exists(string id) => IsValidId(id) && File.Exists(EmlPath(id));

    public string EmlPath(string id) => Path.Combine(_folder, id + ".eml");

    private string JsonPath(string id) => Path.Combine(_folder, id + ".json");

    public async Task<MimeMessage> LoadAsync(string id, CancellationToken ct)
    {
        await using var fs = File.OpenRead(EmlPath(id));
        return await MimeMessage.LoadAsync(fs, ct);
    }

    public void Delete(string id)
    {
        File.Delete(EmlPath(id));
        File.Delete(JsonPath(id));
    }

    public int DeleteAll()
    {
        var n = 0;
        foreach (var f in Directory.EnumerateFiles(_folder, "*.eml"))
        {
            Delete(Path.GetFileNameWithoutExtension(f));
            n++;
        }
        return n;
    }
}
