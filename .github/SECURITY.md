# Security Policy

## Supported versions

Dynotch is pre-1.x in spirit: only the latest release gets security fixes. If you're
on an older build, update to the most recent [release](https://github.com/ALIRAZA47/dynotch/releases/latest)
before reporting.

## Reporting a vulnerability

**Please don't open a public issue for a security problem.**

Report it privately to the maintainer, whichever way fits:

- If the repository's **Security** tab shows **Report a vulnerability**, use that — it
  opens a private advisory only you and the maintainer can see. (This is GitHub's private
  vulnerability reporting, which the maintainer turns on once the repository is public or
  on a plan that offers it.)
- Otherwise, email the maintainer privately. You'll find the address in the commit history
  (`git log`) or on the maintainer's GitHub profile.

Please include:

- What the problem is and how serious you think it is.
- Steps to reproduce it, or a short proof of concept.
- The Dynotch version and your macOS version.

You'll get an acknowledgement within a few days. Once there's a fix, it ships in a new
release and you'll be credited in the advisory unless you'd rather not be.

## What's in scope

Dynotch runs on your own Mac with no backend. What matters most here:

- The `dynotch://` URL scheme and the `dynotch` CLI — anything that lets another app or
  script make Dynotch do something it shouldn't.
- Handling of files dropped into the Tray.
- The code-signing setup in `scripts/`.
- Reading of system databases (Focus, notifications) behind Full Disk Access.

## What's expected and not a vulnerability

- Dynotch isn't notarized by Apple, so macOS warns on first launch. That's expected; the
  [README](../README.md#install) explains it.
- Features that read private system frameworks or files are documented and need the
  permissions macOS asks for.
