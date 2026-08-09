# Platform — installer and releases

Distribution only. This repository holds the installer and the built release
bundle; the source lives elsewhere and is not public.

## Install

On a **clean Debian 12 (amd64)** machine:

```bash
curl -fsSL https://raw.githubusercontent.com/demon45k/vps-control-panel-releases/main/install.sh | sudo bash
```

About three minutes. It ends by printing the panel address and an administrator
password shown exactly once.

Non-interactive, for a script or an image build:

```bash
curl -fsSL https://raw.githubusercontent.com/demon45k/vps-control-panel-releases/main/install.sh -o install.sh
PANEL_DOMAIN=panel.example.com PLATFORM_ADMIN_EMAIL=you@example.com sudo -E bash install.sh
```

| Variable | Meaning |
|---|---|
| `PANEL_DOMAIN` | Where the panel will be reached. Blank uses the machine's own address. |
| `PLATFORM_ADMIN_EMAIL` | The first administrator. Omitted, no account is created and the installer says so. |
| `PLATFORM_BUNDLE` | A different release bundle — a URL or a local file. Defaults to the latest release here. |
| `PLATFORM_PACKAGE_DIR` | A directory of `.deb` files, instead of a bundle. |

## What it refuses

An installer that presses on is one whose failures land later, on somebody
else's afternoon. This one stops, and says which step and why.

- **A Proxmox host.** The control plane manages Proxmox and must not share its
  fate. Install it on a separate machine.
- **Anything but Debian 12 amd64.** Debian 13 warns and continues; everything
  else stops.
- **Another web server on :80 or :443.** Its own nginx is fine — that is a
  re-run, which is the one time anybody runs an installer twice.
- **A login account in the `platform` group.** That group is the entire access
  boundary for the master key, so a person inside it is the boundary gone.
- **Under about 2 GB of RAM or 5 GB free.** It would install, and then not work.

## After installing

The certificate is self-signed. That is correct rather than provisional while
there is no domain — the alternative is not "no certificate", it is a session
cookie travelling in the clear. Browsers will warn, and the warning is accurate:
nobody has vouched for it.

Then, before selling anything:

```bash
sudo platform-escrow-keys /root/platform-keys-$(date -u +%Y%m%d).tar.gz.gpg
```

Four pieces of key material, one copy each until you make more. Losing them
loses every certificate private key, every sealed backup, and the CA that every
node trusts — and no database backup brings any of it back.

## Verifying a download

Each release lists the bundle's SHA-256. The installer does not check it for
you, deliberately: a checksum published beside the file it describes proves the
two arrived together and nothing else.
