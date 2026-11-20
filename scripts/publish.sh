#!/usr/bin/env bash
#
# publish.sh — build the static Flatpak repo site for GitHub Pages in ./site from
# the app pointers in apps/*.json:
#
#   site/repo/                  OSTree repo (GPG-signed commits + summary, static deltas)
#   site/vintoware.flatpakrepo  `flatpak remote-add` file (embeds the public key)
#   site/<app-id>.flatpakref    one-click install file per app
#   site/index.html             install instructions + app list
#
# Each apps/<name>.json is written by that app's build repo (see README):
#   { "id", "arch", "branch", "version", "bundle_url", "bundle_sha256", "source" }
#
# Pages deployments replace the whole site, so the currently published repo is
# mirrored back first (latest commit of every ref). A bundle whose sha256 is already
# recorded in its ref's latest commit body is skipped. That keeps re-runs idempotent and
# means users only get an update when an app actually changed. New commits get the
# published one as their parent, so updates ship as static deltas. History is pruned
# to one parent to keep the site small.
#
# Env:
#   SITE_URL         https://<owner>.github.io/<repo>   (required)
#   GPG_PRIVATE_KEY  ASCII-armored signing key, no passphrase (required)
#   PROJECT_URL      homepage for the .flatpakrepo (default: https://github.com/$GITHUB_REPOSITORY)
#
set -euo pipefail

: "${SITE_URL:?SITE_URL must be set}"
: "${GPG_PRIVATE_KEY:?GPG_PRIVATE_KEY must be set}"
: "${PROJECT_URL:=https://github.com/${GITHUB_REPOSITORY:-vintoware/flatpak-repo}}"
: "${REMOTE_NAME:=vintoware}"
: "${REPO_TITLE:=vintoware Flatpak repo (unofficial builds)}"
: "${SITE_DIR:=site}"
SITE_URL="${SITE_URL%/}"

log(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

export GNUPGHOME; GNUPGHOME="$(mktemp -d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$GNUPGHOME" "$WORK"' EXIT
printf '%s\n' "$GPG_PRIVATE_KEY" | gpg --batch --quiet --import
KEY="$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')"
[ -n "$KEY" ] || { echo "GPG_PRIVATE_KEY did not contain a secret key" >&2; exit 1; }
GPG_ARGS=(--gpg-sign="$KEY" --gpg-homedir="$GNUPGHOME")
echo "Signing key: $KEY"

rm -rf "$SITE_DIR"; mkdir -p "$SITE_DIR"
REPO="$SITE_DIR/repo"
ostree init --mode=archive-z2 --repo="$REPO"

log "Restoring the published repo from $SITE_URL/repo"
if curl -fsI "$SITE_URL/repo/config" >/dev/null 2>&1; then
  # Our own previous output; signatures are verified on the users' side.
  ostree remote add --repo="$REPO" --no-gpg-verify published "$SITE_URL/repo"
  for ref in $(ostree remote refs --repo="$REPO" published | sed 's/^published://' | grep -E '^(app|runtime)/'); do
    ostree pull --repo="$REPO" --mirror published "$ref" \
      || echo "::warning::could not mirror $ref; it will be published without history"
  done
  ostree remote delete --repo="$REPO" published
else
  echo "nothing published yet; starting a new repo"
fi

shopt -s nullglob
APPS=(apps/*.json)
[ "${#APPS[@]}" -gt 0 ] || echo "::warning::no apps/*.json; publishing an empty repo"

LISTING=""
for f in "${APPS[@]}"; do
  id="$(jq -er .id "$f")"; arch="$(jq -er .arch "$f")"; branch="$(jq -r '.branch // "master"' "$f")"
  version="$(jq -er .version "$f")"; url="$(jq -er .bundle_url "$f")"; sha="$(jq -er .bundle_sha256 "$f")"
  source="$(jq -r '.source // ""' "$f")"
  ref="app/$id/$arch/$branch"
  LISTING+="<li><code>$id</code> $version ($arch)$( [ -n "$source" ] && printf ' &mdash; <a href="%s">source</a>' "$source")</li>"$'\n'

  if ostree show --repo="$REPO" "$ref" 2>/dev/null | grep -q "bundle-sha256: $sha"; then
    log "$ref: $version already published"
    continue
  fi

  log "$ref: importing $version"
  bundle="$WORK/$id.$arch.flatpak"
  curl -fL --retry 3 -o "$bundle" "$url"
  echo "$sha  $bundle" | sha256sum -c -

  src="$WORK/src-$id-$arch"
  rm -rf "$src"; ostree init --mode=archive-z2 --repo="$src"
  flatpak build-import-bundle --no-update-summary "$src" "$bundle"
  ostree refs --repo="$src" | grep -qx "$ref" \
    || { echo "bundle $url does not contain $ref (has: $(ostree refs --repo="$src" | tr '\n' ' '))" >&2; exit 1; }

  flatpak build-commit-from "${GPG_ARGS[@]}" --src-repo="$src" --src-ref="$ref" \
    --subject="$id $version" --body="bundle-sha256: $sha
source: $source" "$REPO" "$ref"
  rm -rf "$src" "$bundle"
done

log "Updating summary, appstream, static deltas; pruning history"
flatpak build-update-repo "${GPG_ARGS[@]}" --title="$REPO_TITLE" \
  --generate-static-deltas --prune --prune-depth=1 "$REPO"
flatpak repo "$REPO" || true

log "Writing site files"
GPG_B64="$(gpg --batch --export "$KEY" | base64 -w0)"

cat > "$SITE_DIR/$REMOTE_NAME.flatpakrepo" <<EOF
[Flatpak Repo]
Title=$REPO_TITLE
Url=$SITE_URL/repo/
Homepage=$PROJECT_URL
Comment=Unofficial Flatpak builds
GPGKey=$GPG_B64
EOF

for f in "${APPS[@]}"; do
  id="$(jq -er .id "$f")"; branch="$(jq -r '.branch // "master"' "$f")"
  cat > "$SITE_DIR/$id.flatpakref" <<EOF
[Flatpak Ref]
Name=$id
Branch=$branch
Url=$SITE_URL/repo/
SuggestRemoteName=$REMOTE_NAME
Homepage=$PROJECT_URL
IsRuntime=false
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
GPGKey=$GPG_B64
EOF
done

cat > "$SITE_DIR/index.html" <<EOF
<!doctype html>
<html lang="en">
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>vintoware Flatpak repo</title>
<style>
  body { font: 16px/1.5 system-ui, sans-serif; max-width: 46rem; margin: 2rem auto; padding: 0 1rem; color: #1d1d1f; background: #fff; }
  pre { background: #f2f2f4; padding: .75rem 1rem; overflow-x: auto; border-radius: 6px; }
  @media (prefers-color-scheme: dark) { body { color: #e8e8ea; background: #161618; } pre { background: #242428; } a { color: #8ab4ff; } }
</style>
<h1>vintoware Flatpak repo</h1>
<p>Unofficial Flatpak builds, signed with key <code>$KEY</code>.</p>
<h2>Add the repo</h2>
<pre>flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --user --if-not-exists $REMOTE_NAME $SITE_URL/$REMOTE_NAME.flatpakrepo</pre>
<h2>Apps</h2>
<ul>
$LISTING</ul>
<p>Install with <code>flatpak install --user $REMOTE_NAME &lt;app-id&gt;</code>; updates arrive with <code>flatpak update</code>.</p>
<p><a href="$PROJECT_URL">About this repo</a></p>
</html>
EOF

du -sh "$REPO"
echo "Site ready in $SITE_DIR"
