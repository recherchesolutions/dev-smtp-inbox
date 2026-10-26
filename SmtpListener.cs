using System.Net;
using System.Net.Sockets;
using System.Text;

namespace FakeSmtp;

// A receive-only SMTP server: accepts any sender, recipient and AUTH credentials, and stores every message
// instead of delivering it. No STARTTLS: clients must connect without SSL.
public sealed class SmtpListener(MailStore store, IConfiguration config, ILogger<SmtpListener> log) : BackgroundService
{
    private const string HostName = "fake-smtp.local";
    private static readonly TimeSpan IdleTimeout = TimeSpan.FromMinutes(5);
    private readonly long _maxBytes = config.GetValue<long?>("FakeSmtp:MaxMessageBytes") ?? 50L * 1024 * 1024;

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var address = IPAddress.Parse(config["FakeSmtp:SmtpAddress"] ?? "127.0.0.1");
        var port = config.GetValue<int?>("FakeSmtp:SmtpPort") ?? 25;
        var listener = new TcpListener(address, port);
        listener.Start();
        log.LogInformation("SMTP listening on {Address}:{Port}; messages go to {Folder}", address, port, store.Folder);
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(stoppingToken);
                _ = Task.Run(() => HandleAsync(client, stoppingToken), stoppingToken);
            }
        }
        catch (OperationCanceledException) { }
        finally
        {
            listener.Stop();
        }
    }

    private async Task HandleAsync(TcpClient client, CancellationToken stoppingToken)
    {
        var remote = client.Client.RemoteEndPoint?.ToString() ?? "?";
        using var _ = client;
        await using var stream = client.GetStream();
        var reader = new LineReader(stream);
        string? mailFrom = null;
        var rcpt = new List<string>();

        async Task Reply(string line) => await stream.WriteAsync(Encoding.ASCII.GetBytes(line + "\r\n"), stoppingToken);

        try
        {
            await Reply($"220 {HostName} Fake SMTP ready (messages are stored, never delivered)");
            while (true)
            {
                var line = await reader.ReadLineAsync(IdleTimeout, stoppingToken);
                if (line is null) return;
                var text = Encoding.Latin1.GetString(line);
                var verb = text.Split(' ', 2)[0].ToUpperInvariant();
                var arg = text.Length > verb.Length ? text[(verb.Length + 1)..].Trim() : "";

                switch (verb)
                {
                    case "EHLO":
                        await Reply($"250-{HostName}");
                        await Reply($"250-SIZE {_maxBytes}");
                        await Reply("250-8BITMIME");
                        await Reply("250-SMTPUTF8");
                        await Reply("250-AUTH PLAIN LOGIN");
                        await Reply("250 HELP");
                        break;
                    case "HELO":
                        await Reply($"250 {HostName}");
                        break;
                    case "AUTH":
                        // Accept any credentials; read and discard them.
                        var parts = arg.Split(' ', 2);
                        if (parts[0].Equals("LOGIN", StringComparison.OrdinalIgnoreCase))
                        {
                            if (parts.Length == 1)
                            {
                                await Reply("334 VXNlcm5hbWU6");
                                if (await reader.ReadLineAsync(IdleTimeout, stoppingToken) is null) return;
                            }
                            await Reply("334 UGFzc3dvcmQ6");
                            if (await reader.ReadLineAsync(IdleTimeout, stoppingToken) is null) return;
                        }
                        else if (parts[0].Equals("PLAIN", StringComparison.OrdinalIgnoreCase) && parts.Length == 1)
                        {
                            await Reply("334 ");
                            if (await reader.ReadLineAsync(IdleTimeout, stoppingToken) is null) return;
                        }
                        else if (!parts[0].Equals("PLAIN", StringComparison.OrdinalIgnoreCase))
                        {
                            await Reply("504 Unrecognized authentication type");
                            break;
                        }
                        await Reply("235 Authentication successful");
                        break;
                    case "MAIL":
                        mailFrom = ExtractAddress(arg, "FROM:");
                        rcpt.Clear();
                        await Reply("250 OK");
                        break;
                    case "RCPT":
                        if (mailFrom is null) { await Reply("503 Need MAIL first"); break; }
                        rcpt.Add(ExtractAddress(arg, "TO:"));
                        await Reply("250 OK");
                        break;
                    case "DATA":
                        if (mailFrom is null || rcpt.Count == 0) { await Reply("503 Need MAIL and RCPT first"); break; }
                        await Reply("354 End data with <CR><LF>.<CR><LF>");
                        var data = await reader.ReadDataAsync(_maxBytes, IdleTimeout, stoppingToken);
                        if (data is null) return;
                        if (data.TooLarge) { await Reply("552 Message exceeds maximum size"); }
                        else
                        {
                            var saved = await store.SaveAsync(data.Bytes, new Envelope(mailFrom, [.. rcpt], remote, DateTimeOffset.UtcNow), stoppingToken);
                            log.LogInformation("Stored {Id} from {From} to {To}: {Subject}", saved.Id, mailFrom, string.Join(", ", rcpt), saved.Subject);
                            await Reply($"250 OK queued as {saved.Id}");
                        }
                        mailFrom = null;
                        rcpt.Clear();
                        break;
                    case "RSET":
                        mailFrom = null;
                        rcpt.Clear();
                        await Reply("250 OK");
                        break;
                    case "NOOP":
                        await Reply("250 OK");
                        break;
                    case "VRFY":
                        await Reply("252 Cannot verify user, but will accept message");
                        break;
                    case "QUIT":
                        await Reply($"221 {HostName} closing");
                        return;
                    case "STARTTLS":
                        await Reply("502 TLS not available; connect without SSL");
                        break;
                    default:
                        await Reply("500 Command not recognized");
                        break;
                }
            }
        }
        catch (Exception ex) when (ex is IOException or SocketException or TimeoutException or OperationCanceledException)
        {
            log.LogDebug("Connection {Remote} ended: {Message}", remote, ex.Message);
        }
        catch (Exception ex)
        {
            log.LogError(ex, "Connection {Remote} failed", remote);
        }
    }

    private static string ExtractAddress(string arg, string prefix)
    {
        var s = arg.StartsWith(prefix, StringComparison.OrdinalIgnoreCase) ? arg[prefix.Length..].Trim() : arg;
        var lt = s.IndexOf('<');
        var gt = s.IndexOf('>');
        return lt >= 0 && gt > lt ? s[(lt + 1)..gt] : s.Split(' ')[0];
    }

    private sealed record DataResult(byte[] Bytes, bool TooLarge);

    // Reads CRLF-terminated lines as raw bytes, so 8-bit message content is stored unchanged.
    private sealed class LineReader(Stream stream)
    {
        private readonly byte[] _buffer = new byte[64 * 1024];
        private int _start, _end;

        public async Task<byte[]?> ReadLineAsync(TimeSpan timeout, CancellationToken ct)
        {
            using var line = new MemoryStream();
            while (true)
            {
                for (var i = _start; i < _end; i++)
                {
                    if (_buffer[i] != (byte)'\n') continue;
                    line.Write(_buffer, _start, i - _start);
                    _start = i + 1;
                    var bytes = line.ToArray();
                    return bytes.Length > 0 && bytes[^1] == (byte)'\r' ? bytes[..^1] : bytes;
                }
                line.Write(_buffer, _start, _end - _start);
                if (line.Length > 1024 * 1024) throw new IOException("Line too long");
                if (!await FillAsync(timeout, ct)) return null;
            }
        }

        // Reads message lines until the lone "." line, removing dot-stuffing; keeps CRLF line endings.
        public async Task<DataResult?> ReadDataAsync(long maxBytes, TimeSpan timeout, CancellationToken ct)
        {
            using var data = new MemoryStream();
            var tooLarge = false;
            while (true)
            {
                var line = await ReadLineAsync(timeout, ct);
                if (line is null) return null;
                if (line.Length == 1 && line[0] == (byte)'.') return new DataResult(tooLarge ? [] : data.ToArray(), tooLarge);
                if (tooLarge) continue;
                var offset = line.Length > 0 && line[0] == (byte)'.' ? 1 : 0;
                data.Write(line, offset, line.Length - offset);
                data.Write("\r\n"u8);
                if (data.Length > maxBytes) { tooLarge = true; data.SetLength(0); }
            }
        }

        private async Task<bool> FillAsync(TimeSpan timeout, CancellationToken ct)
        {
            _start = 0;
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            try
            {
                _end = await stream.ReadAsync(_buffer, cts.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                throw new TimeoutException("Client idle too long");
            }
            return _end > 0;
        }
    }
}
