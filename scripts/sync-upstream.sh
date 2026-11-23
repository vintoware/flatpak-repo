#!/usr/bin/env bash
#
# sync-upstream.sh — keep apps/<id>.<arch>.json pointing at the latest Flatpak bundles
# that an upstream project attaches to its own GitHub releases, for apps that have no
# build repo of ours. Each upstream/<id>.json describes one app:
#
#   {
#     "id": "org.example.App", "branch": "stable", "repo": "owner/name",
#     "minisign_pubkey": "RW…",                       # optional; verified when set
#     "assets": { "x86_64": "app-{tag}-amd64.flatpak", "aarch64": "app-{tag}-arm64.flatpak" }
#   }
#
# Only the latest stable release is considered (GitHub's /releases/latest skips
# drafts and prereleases). A pointer is rewritten only when the asset's sha256 differs
# from the published one, after the download matches GitHub's digest and, when a key is
# pinned, the upstream minisign signature (<asset>.minisig). If a release is missing an
# arch's bundle, that arch keeps its current pointer. publish.sh does the rest.
#
# Prints one "<name> <version> (<arch>, …)" line per updated app to $CHANGES_FILE
# (default: /dev/null), for the commit message.
#
# Env: GITHUB_TOKEN (optional, raises the API rate limit), CHANGES_FILE
#
set -euo pipefail

: "${CHANGES_FILE:=/dev/null}"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

api(){
  curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
    ${GITHUB_TOKEN:+-H "Authorization: Bearer $GITHUB_TOKEN"} "https://api.github.com/$1"
}

shopt -s nullglob
for cfg in upstream/*.json; do
  id="$(jq -er .id "$cfg")"; repo="$(jq -er .repo "$cfg")"
  branch="$(jq -r '.branch // "master"' "$cfg")"; pubkey="$(jq -r '.minisign_pubkey // ""' "$cfg")"
  release="$(api "repos/$repo/releases/latest")"
  tag="$(jq -er .tag_name <<<"$release")"; version="${tag#v}"
  echo "$id: upstream $repo latest is $tag"

  updated=()
  for arch in $(jq -r '.assets | keys[]' "$cfg"); do
    name="$(jq -er --arg a "$arch" '.assets[$a]' "$cfg")"; name="${name//\{tag\}/$tag}"
    pointer="apps/$id.$arch.json"
    asset="$(jq -c --arg n "$name" '.assets[] | select(.name == $n)' <<<"$release")"
    if [ -z "$asset" ]; then
      echo "::warning::$id: $tag has no $name; keeping the current $arch pointer"
      continue
    fi
    url="$(jq -er .browser_download_url <<<"$asset")"
    digest="$(jq -r '.digest // "" | sub("^sha256:"; "")' <<<"$asset")"
    if [ -n "$digest" ] && [ -f "$pointer" ] && [ "$(jq -r .bundle_sha256 "$pointer")" = "$digest" ]; then
      echo "$id/$arch: $tag already in $pointer"
      continue
    fi

    bundle="$WORK/$name"
    curl -fsSL --retry 3 -o "$bundle" "$url"
    sha="$(sha256sum "$bundle" | cut -d' ' -f1)"
    if [ -n "$digest" ] && [ "$sha" != "$digest" ]; then
      echo "$id/$arch: $name sha256 $sha does not match GitHub's digest $digest" >&2; exit 1
    fi
    if [ -n "$pubkey" ]; then
      curl -fsSL --retry 3 -o "$bundle.minisig" "$url.minisig"
      minisign -Vq -P "$pubkey" -m "$bundle" -x "$bundle.minisig" \
        || { echo "$id/$arch: bad minisign signature on $name" >&2; exit 1; }
    fi
    if [ -f "$pointer" ] && [ "$(jq -r .bundle_sha256 "$pointer")" = "$sha" ]; then
      echo "$id/$arch: $tag already in $pointer"
      rm -f "$bundle" "$bundle.minisig"; continue
    fi

    jq -n --arg id "$id" --arg arch "$arch" --arg branch "$branch" --arg version "$version" \
      --arg url "$url" --arg sha "$sha" --arg source "$(jq -r .html_url <<<"$release")" \
      '{id: $id, arch: $arch, branch: $branch, version: $version,
        bundle_url: $url, bundle_sha256: $sha, source: $source}' > "$pointer"
    echo "$id/$arch: updated $pointer to $tag"
    updated+=("$arch")
    rm -f "$bundle" "$bundle.minisig"
  done

  if [ "${#updated[@]}" -gt 0 ]; then
    list="$(printf '%s, ' "${updated[@]}")"
    echo "${id##*.} $version (${list%, })" >> "$CHANGES_FILE"
  fi
done
