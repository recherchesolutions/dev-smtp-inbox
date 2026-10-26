# dev-smtp-inbox

A local SMTP server for development and testing. Point any application's outgoing mail at it: every message is stored and shown in a web inbox, and nothing is ever delivered to a real recipient.

- **SMTP** on `127.0.0.1:25`. It accepts any sender, recipient and SMTP AUTH login (`PLAIN` / `LOGIN`), so apps configured with credentials work unchanged.
- **Web inbox** at http://127.0.0.1:5025: list and search, HTML / text / headers views, attachments, `.eml` download, delete one or all. It refreshes every 3 seconds.
- **No database.** Each message is a pair of files: the exact `.eml` received plus a small `.json` summary.
- **Single self-contained .NET 10 app**, about 400 lines. It runs from the console or as a Windows service.

## Quick start

Requires the [.NET 10 SDK](https://dotnet.microsoft.com/download).

```powershell
git clone https://github.com/recherchesolutions/dev-smtp-inbox.git
cd dev-smtp-inbox
dotnet run
```

Open http://127.0.0.1:5025 and send a test message:

```powershell
Send-MailMessage -SmtpServer localhost -Port 25 -From app@example.test -To someone@example.test -Subject 'Hello' -Body 'It works'
```

## Run as a Windows service (NSSM)

The scripts use [NSSM](https://nssm.cc/) (the Non-Sucking Service Manager), expected at `C:\Tools\nssm.exe` (or pass `-NssmPath`).

**Get nssm.exe:** download the zip from https://nssm.cc/download, extract it, and copy `win64\nssm.exe` (or `win32\nssm.exe` on 32-bit Windows) to `C:\Tools\`:

```powershell
New-Item -ItemType Directory -Force C:\Tools | Out-Null
Copy-Item <extracted folder>\win64\nssm.exe C:\Tools\
```

Then, from an elevated PowerShell in the repo folder:

```powershell
.\scripts\install-service.ps1
```

The install script:

1. publishes the app to `.\publish` (skip with `-SkipPublish`);
2. registers the service `FakeSmtp` with delayed automatic start and restart on exit;
3. runs it as `NT AUTHORITY\LocalService`, with read access to the program folder and write access to the mail and log folders only;
4. writes service output to `.\logs\service.log`, rotated at 10 MB.

Re-running the script reinstalls the service and keeps stored mail.

| Parameter | Default | Meaning |
| --- | --- | --- |
| `-NssmPath` | `C:\Tools\nssm.exe` | Path to nssm.exe |
| `-ServiceName` | `FakeSmtp` | Windows service name |
| `-InstallDir` | `.\publish` | Where the app is published and run from |
| `-MailFolder` | `.\mail` | Where messages are stored |
| `-LogFolder` | `.\logs` | Service output logs |
| `-SmtpPort` | `25` | SMTP port (127.0.0.1 only) |
| `-WebPort` | `5025` | Web inbox port (127.0.0.1 only) |
| `-MaxMessages` | `0` | Keep only the newest N messages; `0` keeps everything |
| `-Account` | `NT AUTHORITY\LocalService` | Service account |
| `-SkipPublish` | off | Use the existing `-InstallDir` build |

Remove the service (stored mail and logs are kept):

```powershell
.\scripts\uninstall-service.ps1
```

Manage it like any service: `Get-Service FakeSmtp`, `Restart-Service FakeSmtp`.

## Configuration

Settings are in `appsettings.json`. Any of them can be overridden with environment variables (`FakeSmtp__SmtpPort=2525`, `Urls=http://127.0.0.1:8025`) or command-line arguments (`--FakeSmtp:SmtpPort 2525 --urls http://127.0.0.1:8025`).

| Setting | Default | Meaning |
| --- | --- | --- |
| `FakeSmtp:SmtpAddress` | `127.0.0.1` | Address the SMTP listener binds to |
| `FakeSmtp:SmtpPort` | `25` | SMTP port |
| `FakeSmtp:MaxMessageBytes` | `52428800` (50 MB) | Larger messages are rejected with `552` |
| `FakeSmtp:MaxMessages` | `0` | Keep only the newest N messages; `0` keeps everything |
| `FakeSmtp:MailFolder` | `mail` | Storage folder, relative to the app folder unless absolute |
| `Urls` | `http://127.0.0.1:5025` | Web inbox address |
| `AllowedHosts` | `localhost;127.0.0.1` | Host headers the web inbox answers |

## Pointing an application at it

Use host `localhost` (or `127.0.0.1`), port `25`, **no SSL/TLS**. Any username and password are accepted.

.NET Framework (`web.config` / `app.config`):

```xml
<system.net>
  <mailSettings>
    <smtp deliveryMethod="Network">
      <network host="localhost" port="25" enableSsl="false" />
    </smtp>
  </mailSettings>
</system.net>
```

.NET (`System.Net.Mail` or MailKit), Java, Node.js, Python and others: set the SMTP host and port the same way, with TLS off.

## Storage

Messages are saved in the mail folder as `<id>.eml` (the exact bytes received after `DATA`) and `<id>.json` (envelope sender and recipients, subject, size, attachment count, time received). The id starts with the UTC receive time, so names sort oldest to newest. Delete files directly or use **Delete all** in the inbox; `-MaxMessages` prunes automatically.

## Web API

| Method and path | Returns |
| --- | --- |
| `GET /api/messages/?q=text` | Newest 500 summaries, optionally filtered by subject, sender or recipients |
| `GET /api/messages/{id}` | Headers, text body, attachment list |
| `GET /api/messages/{id}/html` | HTML body, `cid:` images inlined |
| `GET /api/messages/{id}/raw` | The `.eml` file |
| `GET /api/messages/{id}/attachments/{n}` | Attachment `n` |
| `DELETE /api/messages/{id}` | Deletes one message |
| `DELETE /api/messages/` | Deletes all messages |

## Security notes

- Both listeners bind to `127.0.0.1` by default. **The web inbox has no login.** Do not bind it to other addresses on a shared or reachable machine: anyone who can reach it can read every captured message.
- Email HTML is shown in a sandboxed iframe, with a Content-Security-Policy that blocks scripts and all remote content (remote images are not loaded). Links open in a new tab.
- Requests with a `Host` header outside `AllowedHosts` are rejected, which blocks DNS-rebinding attempts from a browser.
- Captured mail may contain whatever your test data contains. Treat the mail folder like the data it came from.

## Limitations

- No STARTTLS. Clients configured to require SSL/TLS will fail to send; turn TLS off for local use.
- No relaying, delivery, bounce simulation or POP3/IMAP access.

## License

No license has been chosen yet, so all rights are reserved. Open an issue if you would like to use it under specific terms.
