# Security Policy

## Supported versions

This is a single-track desktop and mobile app: only the **latest release**
receives fixes. If you're on an older build, update before reporting — the
in-app updater, `winget upgrade`, or the
[releases page](https://github.com/TheSaltyKorean/md/releases/latest) will get
you current.

| Version | Supported |
| --- | --- |
| Latest release | ✅ |
| Anything older | ❌ |

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Use GitHub's private vulnerability reporting, which is enabled on this
repository:

**[Report a vulnerability →](https://github.com/TheSaltyKorean/md/security/advisories/new)**

That opens a private advisory visible only to you and the maintainer. If you
can't use it for any reason, contact
[@TheSaltyKorean](https://github.com/TheSaltyKorean) directly through GitHub
and ask for a private channel before sending details.

Helpful things to include:

- The version (Help → About) and platform.
- What an attacker gains, and what access they need to start.
- Steps to reproduce, or a proof of concept. If a document triggers it, attach
  a **minimal** one — never a real filing with personal details in it.

### What to expect

This project has one maintainer working on it part-time, so treat these as
intentions rather than guarantees:

- An acknowledgement within about a week.
- An assessment — confirmed, not a vulnerability, or already known — once it's
  been reproduced.
- A fix in the next release, with the version bumped so the in-app updater
  actually offers it.
- Credit in the release notes if you'd like it; say so, and tell me how you
  want to be named.

Please give a reasonable window to ship a fix before disclosing publicly.

## Known limitation, already tracked

`file_picker` is pinned to **10.x**, which carries a known Android path
traversal issue, because `appflowy_editor` 6.2.0 still calls the file_picker
v10 API and the fix only exists in v11. This is tracked in the open
[issue #2](https://github.com/TheSaltyKorean/md/issues/2) — no need to report
it again. The pin lifts as soon as AppFlowy moves to the v11 API.

## Scope

In scope: the Markdown Studio application itself — document parsing, the PDF
and print pipeline, file open/save, the file association and single-instance
handling, and the in-app updater.

Out of scope: the marketing site at markdownstudio.dev (a static GitHub Pages
site), vulnerabilities in third-party dependencies that are already public and
have no exploit path through this app, and reports produced solely by an
automated scanner with no demonstrated impact.
