# KnowledgeBase-Crawler

A PowerShell website crawler for archiving documentation and knowledge bases for later analysis by an AI assistant. It uses **Invoke-WebRequest**, supports Windows integrated authentication, and provides crawl-depth controls.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7+
- Network access to the target site
- Permission to access and archive the target content

## Quick start

Download HTML pages only (no linked images, stylesheets, scripts, fonts, or other assets):

```powershell
.\Invoke-KBCrawl.ps1 -Url "https://docs.example.com" -Depth 3 -SourceOnly
```

Use your current Windows credentials for an internal site:

```powershell
.\Invoke-KBCrawl.ps1 -Url "https://intranet.example.local" -Depth 4 -SourceOnly -UseDefaultCredentials
```

Download pages and common linked assets:

```powershell
.\Invoke-KBCrawl.ps1 -Url "https://docs.example.com" -Depth 2
```

## Parameters

| Parameter | Default | Description |
|---|---:|---|
| `-Url` | Required | Starting HTTP/HTTPS URL |
| `-Depth` | `2` | Link depth. Start page is depth 0; depth 0 downloads only the start page |
| `-OutputDirectory` | `./KnowledgeBase-Download` | Destination folder |
| `-SourceOnly` | Off | Save HTML pages only; skip linked assets |
| `-UseDefaultCredentials` | Off | Send current Windows credentials |
| `-DelaySeconds` | `1` | Delay between requests |
| `-MaxPages` | `2000` | Safety limit on downloaded HTML pages |
| `-IncludeSubdomains` | Off | Also allow subdomains of the starting host |
| `-AllowInsecureTls` | Off | PowerShell 7+ only; disables certificate validation (not recommended) |

## Output

- HTML files are saved under the output directory using URL paths.
- `crawl-manifest.csv` maps source URLs to local files and crawl depth.
- `crawl-errors.csv` records failed requests.

## AI workflow

1. Crawl the relevant documentation with `-SourceOnly`.
2. Review the manifest and error log.
3. Remove content you are not authorized to share with an external AI service.
4. Upload the HTML files (or convert them to Markdown/text) to your AI assistant.
5. Ask it to create a task-specific procedure, citing source page titles/URLs and preserving prerequisites, warnings, decision points, and verification steps.

Example prompt:

> Using only the uploaded knowledge base, create a detailed step-by-step guide for [my task]. Include prerequisites, required permissions, exact navigation/actions, decision points, expected results, troubleshooting, and source URLs. Flag gaps or conflicting instructions instead of guessing.

## Important notes and limitations

- The crawler stays on the starting origin by default. `-IncludeSubdomains` broadens this to subdomains of the starting host.
- `-SourceOnly` saves HTML responses only and follows `href` links. It does not download `src` resources such as images or scripts.
- The crawler does not execute JavaScript, render client-side applications, or capture content that appears only after browser-side execution. Some modern documentation portals may need a browser-based crawler or an official export/API.
- Internal authentication depends on the server accepting Windows integrated credentials. It does not bypass access controls.
- This is a lightweight link crawler, not a full web archiver. Test against a small depth first and inspect the manifest.
- Review organizational policies, site terms, copyright, and robots guidance before crawling. Keep internal knowledge bases private; do not upload confidential material to third-party AI services unless approved.
- Use conservative delays and page limits.

## License

MIT. See [LICENSE](LICENSE).
