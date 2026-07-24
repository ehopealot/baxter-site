#!/bin/sh
# Baxter remote installer -- the `curl | bash` bootstrap hosted at https://bax.bot.
#
#   curl -fsSL https://bax.bot/install.sh | bash
#
# It checks prerequisites, clones Baxter's latest RELEASE (a versioned vX.Y.Z tag,
# never un-released `main`), puts the `baxter` CLI on your PATH, scaffolds app/.env,
# and builds the container images -- then hands off. It does NOT start Baxter (needs a
# Discord token + a model key you supply) and does NOT install Docker (it checks +
# points you at the docs). The image build is skipped if the Docker daemon isn't
# running. Safe to re-run: an existing Baxter checkout is updated to the latest
# release, and a filled-in app/.env is never overwritten.
#
# Install into a custom directory (default ~/baxter):
#   curl -fsSL https://bax.bot/install.sh | bash -s -- /opt/baxter
#   BAXTER_DIR=/opt/baxter  curl -fsSL https://bax.bot/install.sh | bash
#
# NOTE: this is the landing repo's `install.sh`, served verbatim at bax.bot/install.sh
# -- re-upload after editing. Don't confuse it with baxter-ai's OWN install.sh, a
# different post-clone helper that only symlinks the CLI onto PATH (run at step 3).
#
# POSIX sh -- runs the same piped to `bash` or `sh`.
set -eu

# Colors only when stdout is a terminal (true under `curl | bash`; a pipe/file
# isn't). Real ESC bytes (via printf) so they render in both printf and the
# heredoc below -- a literal '\033' string would print raw through `cat`.
if [ -t 1 ]; then
  B=$(printf '\033[1m'); G=$(printf '\033[32m'); R=$(printf '\033[31m'); Y=$(printf '\033[33m'); Z=$(printf '\033[0m')
else
  B=''; G=''; R=''; Y=''; Z=''
fi
say()  { printf '%s\n' "$*"; }
step() { printf '%s\n' "${B}==>${Z} $*"; }
ok()   { printf '%s\n' "${G}ok${Z}  $*"; }
warn() { printf '%s\n' "${Y}note:${Z} $*"; }
die()  { printf '%s\n' "${R}error:${Z} $*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

REPO_URL="https://github.com/ehopealot/baxter-ai.git"
REPO_SLUG="ehopealot/baxter-ai"

# The latest STABLE release tag (vX.Y.Z) -- so installs track releases, never
# un-released `main`. Prefers GitHub's Releases API (which already excludes drafts +
# pre-releases); falls back to the highest semver tag via git, skipping pre-releases
# (tags with a '-'), when curl or the API is unavailable. Empty if there are none.
latest_release_tag() {
  if have curl; then
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" 2>/dev/null \
      | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$tag" ] && { printf '%s' "$tag"; return 0; }
  fi
  git ls-remote --tags --refs --sort=-v:refname "$REPO_URL" 'v*' 2>/dev/null \
    | sed 's#.*refs/tags/##' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1
}

# Everything that DOES anything lives in main(), invoked on the last line. `curl |
# bash` streams and executes as bytes arrive, so a dropped connection would run a
# truncated prefix -- but with the whole body inside a function, bash must parse
# the entire file before it can call main, so a cut-off download fails to parse and
# runs NOTHING instead of a half-script. (rustup / nvm / Homebrew do the same.)
main() {
  DEST="${1:-${BAXTER_DIR:-$HOME/baxter}}"
  # How baxter-ai builds its container images. Both targets depend on check-arch
  # (needs the daemon) but NOT check-env, so this runs without any keys set.
  BUILD_CMD="make build-app build-codapi"
  # Never let git block on a credential prompt (a private/typo'd repo would hang a
  # `curl | bash` forever). Fail fast instead, so the die messages below fire.
  export GIT_TERMINAL_PROMPT=0

  # --- 1. prerequisites (check + instruct; never auto-install) ---------------
  step "Checking prerequisites"
  missing=''
  have git    || missing="$missing git"
  have docker || missing="$missing docker"
  have make   || missing="$missing make"
  if [ -n "$missing" ]; then
    die "missing:${missing}. Install them, then re-run. Docker: https://docs.docker.com/engine/install/"
  fi
  docker compose version >/dev/null 2>&1 \
    || die "the 'docker compose' v2 plugin is required (found docker, but not compose v2). See https://docs.docker.com/compose/install/"
  ok "docker, docker compose v2, git, make"
  # Building the images needs the daemon (check-arch reads the daemon's arch);
  # clone/CLI/scaffold don't. Record whether it's up: if it's down we still
  # install and just skip the build (step 5) rather than blocking.
  if docker info >/dev/null 2>&1; then
    daemon_up=1
  else
    daemon_up=0
    warn "the docker daemon isn't reachable -- I'll skip the image build. Start it (or 'colima start', or add your user to the 'docker' group), then 'baxter up'."
  fi

  # --- 2. clone (or update an existing checkout; never clobber) ---------------
  # A NON-EMPTY dir that isn't Baxter is a clobber hazard; an empty/absent dir is
  # a valid clone target (git clones into an existing empty dir just fine).
  if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then
    if [ -d "$DEST/.git" ] && git -C "$DEST" remote get-url origin 2>/dev/null | grep -qi 'baxter-ai'; then
      step "Updating the existing checkout at $DEST"
      git -C "$DEST" fetch --tags --prune --prune-tags --force --quiet origin \
        || warn "couldn't fetch updates (offline?) -- keeping the current checkout"
      TAG=$(latest_release_tag)
      if [ -n "$TAG" ]; then
        git -C "$DEST" checkout --quiet "$TAG" \
          || die "couldn't check out release $TAG in $DEST (local changes, or an old shallow clone). Resolve it there, or move $DEST aside and re-run for a fresh clone."
      else
        git -C "$DEST" pull --ff-only \
          || die "git pull failed in $DEST (local changes, or the branch diverged). Resolve it there, or move $DEST aside and re-run."
      fi
    else
      die "$DEST already exists and isn't a Baxter checkout -- move it aside, or install elsewhere: curl -fsSL https://bax.bot/install.sh | bash -s -- /some/other/dir"
    fi
  else
    # Full clone (not --depth 1): baxter update switches between release TAGS, which a
    # shallow clone can't reliably fetch. The extra history is trivial next to the image build.
    TAG=$(latest_release_tag)
    if [ -n "$TAG" ]; then
      step "Cloning Baxter $TAG into $DEST"
      git clone --branch "$TAG" "$REPO_URL" "$DEST" \
        || die "git clone of $TAG failed -- is $REPO_URL public and reachable?"
    else
      warn "no published release found -- installing the latest main instead."
      step "Cloning Baxter (main) into $DEST"
      git clone "$REPO_URL" "$DEST" \
        || die "git clone failed -- is $REPO_URL public and reachable?"
    fi
  fi
  ok "source at $DEST ($(git -C "$DEST" describe --tags --always 2>/dev/null || echo unknown))"

  # --- 3. put the `baxter` CLI on PATH (the repo's own install.sh) -----------
  step "Installing the baxter CLI"
  ( cd "$DEST" && ./install.sh ) || die "installing the baxter CLI failed (see the output above)."

  # --- 4. scaffold app/.env (never overwrite a filled-in one) ----------------
  if [ -f "$DEST/app/.env" ]; then
    ok "keeping your existing app/.env"
  else
    cp "$DEST/app/.env.example" "$DEST/app/.env"
    chmod 600 "$DEST/app/.env"
    ok "scaffolded app/.env from the example"
  fi

  # --- 5. build the container images (needs the daemon; skip cleanly if down) --
  # Build only -- never start. Starting needs the Discord token + model key the
  # user supplies; building doesn't, so doing it here saves a multi-minute wait
  # on the first `baxter shell` / `baxter up`. Docker's output is noisy, so it's
  # captured to a log and only surfaced if the build fails (non-fatal: `baxter up`
  # would rebuild anyway).
  if [ "$daemon_up" = 1 ]; then
    step "Building Baxter's images (first run can take a few minutes)"
    build_log=$(mktemp 2>/dev/null || printf '%s' "${TMPDIR:-/tmp}/baxter-build.$$")
    if ( cd "$DEST" && $BUILD_CMD ) >"$build_log" 2>&1; then
      ok "images built"
      rm -f "$build_log"
    else
      warn "the image build didn't finish -- Baxter will build it on your first 'baxter up'. Last lines:"
      tail -n 12 "$build_log" >&2
      rm -f "$build_log"
    fi
  else
    warn "skipped the image build -- the Docker daemon isn't running. It'll build on your first 'baxter up'."
  fi

  # --- 6. next steps ---------------------------------------------------------
  say ""
  step "Baxter is installed at $DEST"
  cat <<EOF

${B}Next steps${Z} -- set one thing, then Baxter takes it from there:

  1. Give Baxter a model -- it needs a brain before it can help with anything else.
     Get an ${B}OpenRouter API key${Z} (https://openrouter.ai, the default) and set
     ${B}OPENROUTER_API_KEY${Z} in ${B}$DEST/app/.env${Z}.
  2. Run ${B}baxter shell${Z} and ask Baxter to finish setting up -- it walks you
     through the Discord bot token and the rest, and writes it in for you.

If 'baxter' isn't found, add its bin dir to PATH (the CLI installer noted it above).
Full setup -- other model backends, the optional mail/voice surfaces -- is in
$DEST/README.md.
EOF
}

main "$@"
