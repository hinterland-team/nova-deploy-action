#!/usr/bin/env bash
# the nova deploy build step (docs/contract.md section 2). action.yml runs it inside the checkout
# of the calling repo: for every gradle project in nova-deploy.json it writes local.properties,
# runs the unit tests and builds the apks, then publishes one github release per app.
# needs git, jq, gh and java. env from action.yml: NOVA_KEYSTORE_B64, NOVA_KEYSTORE_PASSWORD,
# NOVA_APP_PROPERTIES (optional), GH_TOKEN, GH_REPO (owner/name of the calling repo), BUILD_NUMBER.
#
# dry run on a laptop, with apks that are already built and a stand-in gh first on the PATH:
#   SKIP_BUILD=1 BUILD_NUMBER=12 GH_REPO=owner/repo PATH="<dir with a fake gh>:$PATH" bash release.sh
# REPO_DIR = the checkout to work in (default: the current directory).
# COMMIT_SHA / COMMIT_SUBJECT / COMMIT_AUTHOR replace what git says (for a folder without commits).
set -euo pipefail

fail() {
  echo "::error::$*"
  exit 1
}

cd "${REPO_DIR:-.}"

config=nova-deploy.json
n="${BUILD_NUMBER:?BUILD_NUMBER is missing}"
repo="${GH_REPO:-${GITHUB_REPOSITORY:-}}"
[ -n "$repo" ] || fail "GH_REPO is missing (owner/name of the repo to release in)"

# ---- check nova-deploy.json ----

[ -f "$config" ] || fail "$config is missing in the repo root"
jq empty "$config" 2>/dev/null || fail "$config is not valid JSON"
jq -e '(.apps | type) == "array" and (.apps | length) > 0' "$config" >/dev/null 2>&1 ||
  fail "$config needs an \"apps\" list with at least one app"
bad=$(jq -r '
  def text: type == "string" and length > 0;
  .apps | to_entries[] | .key as $i | .value as $a
  | if ($a | type) != "object" then "apps[\($i)] is not an object"
    else
      [ (if ($a.id | text) and ($a.id | test("^[a-z0-9-]+$")) then empty else "id (lower case, digits and -)" end),
        (if ($a.name | text) then empty else "name" end),
        (if ($a.project | text) and ($a.project | test("^[A-Za-z0-9._/-]+$")) and ($a.project | test("(^|/)\\.\\.(/|$)") | not)
          then empty else "project (a folder in the repo)" end),
        (if ($a.module | text) and ($a.module | test("^[A-Za-z0-9._-]+$")) then empty else "module" end),
        (if ($a.package | text) and ($a.package | test("^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$"))
          then empty else "package (an Android applicationId)" end),
        (if ($a.launch | IN("home", "app", "none")) then empty else "launch (home, app or none)" end) ]
      | if length > 0 then "apps[\($i)] \($a.id // "" | tostring): " + join(", ") else empty end
    end' "$config")
[ -z "$bad" ] || fail "$config has broken entries: $(echo "$bad" | paste -sd ';' -)"
dupes=$(jq -r '[.apps[].id] | group_by(.) | map(select(length > 1) | .[0]) | join(", ")' "$config")
[ -z "$dupes" ] || fail "$config lists these app ids more than once: $dupes"

mapfile -t apps < <(jq -c '.apps[]' "$config")
mapfile -t projects < <(jq -r '[.apps[].project] | unique | .[]' "$config")
for project in "${projects[@]}"; do
  [ -f "$project/gradlew" ] || fail "$project/gradlew is missing (\"project\" in $config is the Gradle project folder)"
done

sha="${COMMIT_SHA:-$(git rev-parse HEAD)}"
subject="${COMMIT_SUBJECT:-$(git log -1 --format=%s "$sha")}"
author="${COMMIT_AUTHOR:-$(git log -1 --format=%an "$sha")}"
branch="${GITHUB_REF_NAME:-main}"
run_id="${GITHUB_RUN_ID:-0}"
run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/$run_id"
version_code=$((1000 + n))
version_name="b$n-${sha:0:7}"
tmp="${RUNNER_TEMP:-$(mktemp -d)}"
out="$tmp/nova-apks"
mkdir -p "$out"

want_cert=""
apk_of() { jq -r '"\(.project)/\(.module)/build/outputs/apk/debug/\(.module)-debug.apk"' <<<"$1"; }

if [ "${SKIP_BUILD:-}" != 1 ]; then
  # ---- signing key + local.properties for every project ----

  # a build signed with another key can never update the robot
  [ -n "${NOVA_KEYSTORE_B64:-}" ] && [ -n "${NOVA_KEYSTORE_PASSWORD:-}" ] ||
    fail "the signing key is missing: set the repo secrets NOVA_KEYSTORE_B64 and NOVA_KEYSTORE_PASSWORD"
  keystore="$tmp/nova-robot.jks"
  printf '%s' "$NOVA_KEYSTORE_B64" | tr -d ' \r\n' | base64 --decode >"$keystore" 2>/dev/null ||
    fail "NOVA_KEYSTORE_B64 is not valid base64"
  [ -s "$keystore" ] || fail "NOVA_KEYSTORE_B64 decodes to an empty file"
  # the apks get checked against this key after the build
  command -v keytool >/dev/null || fail "keytool is missing (it comes with the JDK)"
  want_cert="$(keytool -list -v -keystore "$keystore" -storepass:env NOVA_KEYSTORE_PASSWORD -alias nova 2>/dev/null |
    sed -n 's/^[[:space:]]*SHA256: //p' | tr -d ':\r' | tr 'A-F' 'a-f' | head -n 1 || true)"
  [ -n "$want_cert" ] || fail "the keystore has no key with alias nova, or NOVA_KEYSTORE_PASSWORD does not open it"

  # backslashes are escapes in .properties files
  prop() { printf '%s=%s\n' "$1" "${2//\\/\\\\}"; }
  for project in "${projects[@]}"; do
    chmod +x "$project/gradlew"
    {
      # the app's own build settings first; the signing keys below win over any in there
      if [ -n "${NOVA_APP_PROPERTIES:-}" ]; then printf '%s\n' "$NOVA_APP_PROPERTIES" | tr -d '\r'; fi
      prop signing.storeFile "$keystore"
      prop signing.storePassword "$NOVA_KEYSTORE_PASSWORD"
      prop signing.keyAlias nova
      prop signing.keyPassword "$NOVA_KEYSTORE_PASSWORD"
    } >"$project/local.properties"
  done

  # ---- tests first: a failing test is a failed deployment ----

  for project in "${projects[@]}"; do
    echo "testing $project"
    (cd "$project" && ./gradlew testDebugUnitTest)
  done

  # ---- build: one gradle call per project with all its modules ----

  for project in "${projects[@]}"; do
    mapfile -t tasks < <(jq -r --arg p "$project" '[.apps[] | select(.project == $p) | ":\(.module):assembleDebug"] | unique | .[]' "$config")
    echo "building $project: ${tasks[*]} as $version_name ($version_code)"
    (cd "$project" && ./gradlew "${tasks[@]}" -PversionCode="$version_code" -PversionName="$version_name")
  done
fi

# ---- every apk has to be there, with the package, version and key the release will claim ----

build_tools="$(ls -d "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-/nonexistent}}"/build-tools/*/ 2>/dev/null | sort -V | tail -n 1 || true)"
sdk_tool() {
  local f
  for f in "$build_tools$1" "$build_tools$1.exe" "$build_tools$1.bat"; do
    if [ -n "$build_tools" ] && [ -f "$f" ]; then
      echo "$f"
      return
    fi
  done
}
aapt2="$(sdk_tool aapt2)"
apksigner="$(sdk_tool apksigner)"
for a in "${apps[@]}"; do
  apk="$(apk_of "$a")"
  [ -f "$apk" ] || fail "$apk is missing after the build"
  if [ -n "$aapt2" ]; then
    want_pkg="$(jq -r .package <<<"$a")"
    badging="$("$aapt2" dump badging "$apk" 2>/dev/null | head -n 1 | tr -d '\r' || true)"
    got_pkg="$(sed -n "s/.* name='\([^']*\)'.*/\1/p" <<<"$badging")"
    got_code="$(sed -n "s/.* versionCode='\([^']*\)'.*/\1/p" <<<"$badging")"
    [ "$got_pkg" = "$want_pkg" ] || fail "$apk is package '$got_pkg', $config says '$want_pkg'"
    # the robot compares versionCodes, so the app's build has to use -PversionCode
    [ "$got_code" = "$version_code" ] ||
      fail "$apk has versionCode '$got_code', expected $version_code: the app's build.gradle.kts has to read -PversionCode and -PversionName"
  else
    echo "::warning::aapt2 not found, package and versionCode of $apk not checked"
  fi
  # the robot only takes an update signed with the same key as the installed app
  if [ -n "$want_cert" ] && [ -n "$apksigner" ]; then
    got_cert="$("$apksigner" verify --print-certs "$apk" 2>/dev/null | tr -d '\r' |
      sed -n 's/^Signer #1 certificate SHA-256 digest: //p' | head -n 1 || true)"
    [ "$got_cert" = "$want_cert" ] ||
      fail "$apk is not signed with the shared key: the app's build has to sign the debug build with signing.* from local.properties"
  elif [ -n "$want_cert" ]; then
    echo "::warning::apksigner not found, the signing key of $apk not checked"
  fi
done

# ---- publish: tag <id>-b<N>, asset <id>-b<N>.apk, meta as a json block in the body ----

built_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
for a in "${apps[@]}"; do
  id="$(jq -r .id <<<"$a")"
  name="$(jq -r .name <<<"$a")"
  tag="$id-b$n"
  asset="$out/$tag.apk"
  cp "$(apk_of "$a")" "$asset"
  sha256="$(sha256sum "$asset" | cut -d' ' -f1)"
  size="$(wc -c <"$asset" | tr -d ' ')"

  meta="$(jq -n \
    --argjson entry "$a" \
    --argjson build "$n" \
    --argjson versionCode "$version_code" \
    --arg versionName "$version_name" \
    --arg sha256 "$sha256" \
    --argjson size "$size" \
    --arg commit "$sha" \
    --arg commitMessage "$subject" \
    --arg author "$author" \
    --arg branch "$branch" \
    --argjson runId "$run_id" \
    --arg runUrl "$run_url" \
    --arg builtAt "$built_at" \
    '{app: $entry.id, name: $entry.name, package: $entry.package, launch: $entry.launch,
      build: $build, versionCode: $versionCode, versionName: $versionName, sha256: $sha256, size: $size,
      commit: $commit, commitMessage: $commitMessage, author: $author, branch: $branch,
      runId: $runId, runUrl: $runUrl, builtAt: $builtAt}')"

  notes="$out/$tag.md"
  printf '%s\n\n```json\n%s\n```\n' "$subject" "$meta" >"$notes"

  # a re-run keeps the run number: never touch a release that is out already
  if gh release view "$tag" --repo "$repo" >/dev/null 2>&1; then
    echo "::warning::release $tag exists already, left as it is"
    continue
  fi
  gh release create "$tag" "$asset" \
    --repo "$repo" \
    --title "$name b$n" \
    --target "$sha" \
    --latest=false \
    --notes-file "$notes"
  echo "published $tag ($size bytes, sha256 $sha256)"
done
