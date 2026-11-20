# vintoware Flatpak repo

A personal Flatpak repository served from GitHub Pages:
**https://vintoware.github.io/flatpak-repo/**

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --user --if-not-exists vintoware https://vintoware.github.io/flatpak-repo/vintoware.flatpakrepo
flatpak install --user vintoware com.slack.Slack
```

| App | Arch | Built by |
|-----|------|----------|
| `com.slack.Slack` (unofficial) | aarch64 | [slack-arm64-flatpak](https://github.com/vintoware/slack-arm64-flatpak) |

This repo doesn't build anything. It hosts and signs the bundles that app build repos produce.

## How it works

```
app build repo (e.g. slack-arm64-flatpak)
  │  builds <app>.flatpak, attaches it to a GitHub release
  │  pushes apps/<app>.<arch>.json  ← deploy key with write access to this repo only
  ▼
this repo: .github/workflows/publish.yml (on push to apps/**)
  │  scripts/publish.sh:
  │    mirror the published repo back from Pages (latest commit of every ref)
  │    for each apps/*.json whose bundle sha256 isn't published yet:
  │      download → verify sha256 → flatpak build-import-bundle → build-commit-from (GPG-signed)
  │    build-update-repo: signed summary, appstream, static deltas, prune to 1 parent
  │    write vintoware.flatpakrepo, <app-id>.flatpakref, index.html
  ▼
GitHub Pages (actions/deploy-pages)
```

Pointer file format (`apps/<name>.json`):

```json
{
  "id": "com.slack.Slack",
  "arch": "aarch64",
  "branch": "master",
  "version": "4.53.287",
  "bundle_url": "https://github.com/…/releases/download/v4.53.287/com.slack.Slack.aarch64.flatpak",
  "bundle_sha256": "…",
  "source": "https://github.com/…/releases/tag/v4.53.287"
}
```

Reruns are safe. Each published commit records its `bundle-sha256` in the commit body,
and a bundle that's already published is skipped. Users only get an update when an app
actually changed.

## Adding an app

1. Create a deploy key with write access to this repo (`ssh-keygen -t ed25519`, then
   `gh repo deploy-key add key.pub --allow-write -R vintoware/flatpak-repo`). Store the
   private half as a secret in the app's build repo.
2. Have the build repo publish its bundle somewhere public (e.g. a GitHub release) and
   push `apps/<app-id>.<arch>.json`. See `slack-arm64-flatpak`'s `build.yml`.

## Signing

Every commit and the summary are signed with the key in `vintoware-flatpak.gpg.asc`
(fingerprint `53642E94B0CC55BAB30D88A2347FA5BF6B767DC1`). The private key is the
`GPG_PRIVATE_KEY` repository secret (no passphrase). The `.flatpakrepo` and `.flatpakref`
files embed the public key. Rotating the key means every user has to re-add the remote.

## Limits

GitHub Pages sites are limited to 1 GB, with a soft bandwidth limit of 100 GB/month.
Because history is pruned to one parent, each app takes roughly its current size plus
one delta (Slack ≈ 125 MB).
