using System.Text.RegularExpressions;
using FakeSmtp;
using MimeKit;

var builder = WebApplication.CreateBuilder(new WebApplicationOptions
{
    Args = args,
    ContentRootPath = AppContext.BaseDirectory,
});
builder.Host.UseWindowsService(o => o.ServiceName = "FakeSmtp");
builder.Services.AddSingleton<MailStore>();
builder.Services.AddHostedService<SmtpListener>();

var app = builder.Build();
app.UseDefaultFiles();
app.UseStaticFiles();

var api = app.MapGroup("/api/messages");

api.MapGet("/", (MailStore store, string? q) =>
{
    var list = store.List();
    if (!string.IsNullOrWhiteSpace(q))
        list = list.Where(m => $"{m.Subject} {m.From} {m.To} {m.MailFrom} {string.Join(' ', m.RcptTo)}".Contains(q, StringComparison.OrdinalIgnoreCase));
    return Results.Ok(list.Take(500));
});

api.MapGet("/{id}", async (string id, MailStore store, CancellationToken ct) =>
{
    if (!store.Exists(id)) return Results.NotFound();
    var msg = await store.LoadAsync(id, ct);
    return Results.Ok(new
    {
        id,
        from = msg.From.ToString(),
        to = msg.To.ToString(),
        cc = msg.Cc.ToString(),
        bcc = msg.Bcc.ToString(),
        replyTo = msg.ReplyTo.ToString(),
        subject = msg.Subject,
        date = msg.Date,
        text = msg.TextBody,
        hasHtml = msg.HtmlBody is not null,
        headers = msg.Headers.Select(h => new { name = h.Field, value = h.Value }),
        attachments = msg.Attachments.Select((a, i) => new
        {
            index = i,
            name = a.ContentDisposition?.FileName ?? a.ContentType.Name ?? $"attachment-{i}",
            contentType = a.ContentType.MimeType,
        }),
    });
});

// The email's HTML, with cid: images inlined as data: URIs. Served with a CSP that blocks scripts and remote
// content; the UI also shows it in a sandboxed iframe.
api.MapGet("/{id}/html", async (string id, MailStore store, HttpContext http, CancellationToken ct) =>
{
    if (!store.Exists(id)) return Results.NotFound();
    var msg = await store.LoadAsync(id, ct);
    var html = msg.HtmlBody ?? "";
    foreach (var part in msg.BodyParts.OfType<MimePart>())
    {
        if (string.IsNullOrEmpty(part.ContentId) || part.Content is null) continue;
        using var ms = new MemoryStream();
        await part.Content.DecodeToAsync(ms, ct);
        var dataUri = $"data:{part.ContentType.MimeType};base64,{Convert.ToBase64String(ms.ToArray())}";
        html = Regex.Replace(html, "cid:" + Regex.Escape(part.ContentId), dataUri, RegexOptions.IgnoreCase);
    }
    http.Response.Headers.ContentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:";
    return Results.Content("<base target=\"_blank\">" + html, "text/html; charset=utf-8");
});

api.MapGet("/{id}/raw", (string id, MailStore store) =>
    store.Exists(id) ? Results.File(store.EmlPath(id), "message/rfc822", id + ".eml") : Results.NotFound());

api.MapGet("/{id}/attachments/{index:int}", async (string id, int index, MailStore store, CancellationToken ct) =>
{
    if (!store.Exists(id)) return Results.NotFound();
    var msg = await store.LoadAsync(id, ct);
    if (msg.Attachments.ElementAtOrDefault(index) is not MimePart { Content: not null } part) return Results.NotFound();
    var ms = new MemoryStream();
    await part.Content.DecodeToAsync(ms, ct);
    ms.Position = 0;
    return Results.File(ms, part.ContentType.MimeType, part.FileName ?? $"attachment-{index}");
});

api.MapDelete("/{id}", (string id, MailStore store) =>
{
    if (!store.Exists(id)) return Results.NotFound();
    store.Delete(id);
    return Results.NoContent();
});

api.MapDelete("/", (MailStore store) => Results.Ok(new { deleted = store.DeleteAll() }));

app.Run();
