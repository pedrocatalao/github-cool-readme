#!/usr/bin/env bash
# Wires github-cool-readme into your profile repo (<you>/<you>): token secret, workflow,
# settings, first run, README. Safe to run again; it asks before changing anything.
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/pedrocatalao/github-cool-readme/v1/setup.sh)
#
# Options: --dry-run  show what would happen, change nothing
# Needs: gh (logged in) and git. Works with the bash that ships with macOS.

set -euo pipefail

TOOL_REPO="pedrocatalao/github-cool-readme"
REF="${COOL_README_REF:-v1}"   # the version of the action the workflow uses
WORKFLOW=".github/workflows/cool-readme.yml"
CONFIG="cool-readme.yml"
OUT="stats"
SECRET="CARDS_TOKEN"
START="<!-- cool-readme:start -->"
END="<!-- cool-readme:end -->"

DRY_RUN=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    -h|--help) echo "Usage: setup.sh [--dry-run]  (sets up README cards in your profile repo)"; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
warn() { printf '\033[33m  ! %s\033[0m\n' "$*"; }
die() { printf '\033[31merror: %s\033[0m\n' "$*" >&2; exit 1; }
step() { printf '\n'; bold "$*"; }

# Questions read from the terminal, so this also works when the script itself comes from a pipe.
# Without a terminal, every question takes its default.
HAVE_TTY=false
if (: < /dev/tty) 2>/dev/null; then HAVE_TTY=true; fi

ask() { # ask "Question" default(y/n) -> exit status
  local answer="" hint="[Y/n]"
  [ "$2" = n ] && hint="[y/N]"
  if $HAVE_TTY; then
    read -r -p "  $1 $hint " answer < /dev/tty || answer=""
  else
    info "$1 $hint (no terminal: $2)"
  fi
  answer="${answer:-$2}"
  case "$answer" in y|Y|yes|Yes) return 0 ;; *) return 1 ;; esac
}

run() { # run a command that changes something, or just show it in dry-run mode
  if $DRY_RUN; then info "(dry run) would run: $*"; else "$@"; fi
}

# --- Prerequisites ------------------------------------------------------------------------

step "Checking prerequisites"
command -v gh >/dev/null || die "the GitHub CLI (gh) is not installed: https://cli.github.com"
command -v git >/dev/null || die "git is not installed"
gh auth status >/dev/null 2>&1 || die "gh is not logged in; run: gh auth login"

LOGIN="$(gh api user --jq .login)"
PROFILE="$LOGIN/$LOGIN"
info "Logged in as $LOGIN"

# Pushing a workflow file over HTTPS needs the "workflow" scope; over SSH it doesn't.
PROTOCOL="$(gh config get git_protocol -h github.com 2>/dev/null || echo https)"
if [ "$PROTOCOL" != ssh ]; then
  SCOPES="$(gh api -i user 2>/dev/null | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')"
  case ", $SCOPES," in
    *", workflow,"*) ;;
    *)
      if [ -n "${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
        die "gh uses the token in GH_TOKEN/GITHUB_TOKEN, which lacks the \"workflow\" scope needed to add a workflow. Unset it to use your gh login, or use a token with that scope."
      fi
      info "Adding a workflow file needs the \"workflow\" scope on your gh login."
      ask "Grant it now (opens the browser)?" y || die "cannot continue without the workflow scope"
      gh auth refresh -h github.com -s workflow
      ;;
  esac
fi

# --- Profile repo -------------------------------------------------------------------------

step "Profile repo $PROFILE"
if gh repo view "$PROFILE" >/dev/null 2>&1; then
  info "Found it"
else
  info "It doesn't exist yet. Its README is what GitHub shows on your profile page."
  ask "Create $PROFILE as a public repo?" y || die "nothing to set up without a profile repo"
  run gh repo create "$PROFILE" --public --add-readme --description "My GitHub profile"
  if $DRY_RUN; then info "(dry run) stopping here: the rest needs the repo to exist"; exit 0; fi
fi

# --- Token --------------------------------------------------------------------------------

step "Token"
info "The workflow needs a classic personal access token with the \"repo\", \"read:org\" and \"read:user\" scopes,"
info "so the cards can count your private and organization work. It is stored as the secret $SECRET."
set_token=true
if gh secret list -R "$PROFILE" 2>/dev/null | awk '{print $1}' | grep -qx "$SECRET"; then
  info "$SECRET is already set. If it lacks the read:user scope, add it on GitHub (the token value stays the same)."
  ask "Replace it?" n || set_token=false
fi
if $set_token && $DRY_RUN; then
  info "(dry run) would ask for a token and store it as $SECRET"
elif $set_token; then
  $HAVE_TTY || die "pasting the token needs a terminal; run this script in one"
  url="https://github.com/settings/tokens/new?scopes=repo,read:org,read:user&description=README%20cards%20($PROFILE)"
  info "Create one here (scopes are filled in; pick an expiry, then Generate token):"
  info "$url"
  if command -v open >/dev/null; then open "$url"; elif command -v xdg-open >/dev/null; then xdg-open "$url" >/dev/null 2>&1 || true; fi
  while :; do
    read -r -s -p "  Paste the token (hidden): " TOKEN < /dev/tty; echo
    [ -n "$TOKEN" ] || continue
    headers="$(curl -sS -o /dev/null -D - -H "Authorization: token $TOKEN" https://api.github.com/user | tr -d '\r')"
    status="$(printf '%s\n' "$headers" | awk 'NR==1{print $2}')"
    scopes="$(printf '%s\n' "$headers" | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2}')"
    if [ "$status" != 200 ]; then warn "GitHub rejected that token (HTTP $status). Try again."; continue; fi
    case "$TOKEN" in
      github_pat_*) warn "That's a fine-grained token. Only classic tokens are tested; organization work may be missed."
                    ask "Use it anyway?" n || continue ;;
      *) case ", $scopes," in
           *", repo,"*) ;;
           *) warn "The token lacks the \"repo\" scope (has: ${scopes:-none}). Try again."; continue ;;
         esac
         case ", $scopes," in
           *", read:org,"*|*", admin:org,"*|*", write:org,"*) ;;
           *) warn "The token lacks \"read:org\"; organization work may be missed."; ask "Use it anyway?" n || continue ;;
         esac
         case ", $scopes," in
           *", read:user,"*|*", user,"*) ;;
           *) warn "The token lacks \"read:user\"; without it GitHub hides your private work. Try again."; continue ;;
         esac ;;
    esac
    break
  done
  printf '%s' "$TOKEN" | gh secret set "$SECRET" -R "$PROFILE"
  unset TOKEN
  info "Stored as $SECRET"
fi

# --- Workflow and settings ----------------------------------------------------------------

step "Workflow and settings"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh repo clone "$PROFILE" "$WORK/repo" -- --quiet --depth 1
cd "$WORK/repo"

if [ -f "$CONFIG" ]; then
  info "Keeping your $CONFIG"
  if grep -Eq '^style:[[:space:]]*oled' "$CONFIG" && [ -z "${COOL_README_REF:-}" ]; then
    REF=main
    warn "Your $CONFIG uses OLED cards, which are not in the v1 release yet, so the workflow will use the action from main."
  fi
else
  private=true; orgs=true
  ask "Count work in private repos? (only totals appear on the cards)" y || private=false
  ask "Count work in your organizations' repos?" y || orgs=false
  style=classic
  ask "Use the pinball-style OLED cards instead of the classic ones?" n && style=oled
  # The default (v1) release predates the OLED cards and rejects the "style" setting,
  # so classic cards leave it out, and OLED cards need the action from main.
  style_line=""
  if [ "$style" = oled ]; then
    style_line="style: oled"
    if [ -z "${COOL_README_REF:-}" ]; then
      REF=main
      warn "OLED cards are not in the v1 release yet, so the workflow will use the action from main."
    fi
  fi
  cat > "$CONFIG" <<EOF
# Settings: https://github.com/$TOOL_REPO#settings
user: $LOGIN
${style_line:+$style_line
}include:
  private: $private
  orgs: $orgs
EOF
  info "Adding $CONFIG"
fi
wanted="$(mktemp)"
gh api "repos/$TOOL_REPO/contents/examples/profile-workflow.yml?ref=$REF" -H "Accept: application/vnd.github.raw" \
  | sed "s#$TOOL_REPO@[A-Za-z0-9._-]*#$TOOL_REPO@$REF#" > "$wanted"
mkdir -p "$(dirname "$WORKFLOW")"
if [ ! -f "$WORKFLOW" ]; then
  cp "$wanted" "$WORKFLOW"
  info "Adding $WORKFLOW (runs daily, and on demand)"
elif ! cmp -s "$wanted" "$WORKFLOW"; then
  ask "$WORKFLOW differs from the current template. Replace it?" y && cp "$wanted" "$WORKFLOW"
else
  info "$WORKFLOW is up to date"
fi

# OLED cards are all one size, shown 400 wide; classic ones are a wide and a narrow card per row.
if grep -Eq '^style:[[:space:]]*oled' "$CONFIG" 2>/dev/null; then WIDE=400; NARROW=400; else WIDE=450; NARROW=350; fi

commit_and_push() { # commit_and_push "message"
  git add -A
  if git diff --cached --quiet; then info "Nothing to change"; return 1; fi
  git --no-pager diff --cached --stat
  if $DRY_RUN; then
    git --no-pager diff --cached
    info "(dry run) would commit \"$1\" and push to $PROFILE"
    git commit --quiet -m "$1" # only in the throwaway clone, so the next step shows just its own changes
    return 0
  fi
  ask "Commit \"$1\" and push to $PROFILE?" y || die "stopped; nothing was pushed"
  git commit --quiet -m "$1"
  git push --quiet
}
commit_and_push "Add README cards workflow" || true

# --- First run ----------------------------------------------------------------------------

step "First run"
if $DRY_RUN; then
  info "(dry run) would run the workflow and wait for the cards"
else
  wf="$(basename "$WORKFLOW")"
  runs() { gh run list -R "$PROFILE" -w "$wf" -L 20 --json databaseId --jq '.[].databaseId' 2>/dev/null || true; }
  before="$(runs)" # earlier runs, so the one started below can be told apart from them

  # GitHub needs a moment to register a new workflow before it can be started.
  started=false
  for _ in 1 2 3 4 5 6; do
    if gh workflow run "$wf" -R "$PROFILE" >/dev/null 2>&1; then started=true; break; fi
    sleep 5
  done
  $started || die "could not start the workflow; start it from the Actions tab of $PROFILE"

  # The new run takes a few seconds to show up in the list.
  run_id=""
  for _ in $(seq 1 20); do
    sleep 3
    for id in $(runs); do
      printf '%s\n' "$before" | grep -qx "$id" || { run_id="$id"; break; }
    done
    [ -n "$run_id" ] && break
  done
  [ -n "$run_id" ] || die "the workflow was started but its run didn't show up; check the Actions tab of $PROFILE"
  info "Generating the cards (usually 1-3 minutes)..."
  gh run watch "$run_id" -R "$PROFILE" --exit-status \
    || die "the workflow failed; see: gh run view $run_id -R $PROFILE --log-failed"
  git pull --quiet
fi

# --- README -------------------------------------------------------------------------------

step "README"
picture() { # picture card width alt
  printf '<picture>\n  <source media="(prefers-color-scheme: dark)" srcset="%s/%s-dark.svg">\n  <img src="%s/%s-light.svg" width="%s" alt="%s">\n</picture>\n' \
    "$OUT" "$1" "$OUT" "$1" "$2" "$3"
}
block="$(mktemp)"
{
  echo "$START"
  echo '<p align="center">'
  picture summary $WIDE "GitHub stats"
  picture languages $NARROW "Most used languages"
  echo '</p>'
  echo '<p align="center">'
  picture contributions $WIDE "Notable contributions"
  picture weekly $NARROW "Weekly rhythm"
  echo '</p>'
  echo "$END"
} > "$block"

touch README.md
if grep -qF "$START" README.md && grep -qF "$END" README.md; then
  # Replace only what's between the markers.
  awk -v start="$START" -v end="$END" -v block="$block" '
    $0 == start { while ((getline line < block) > 0) print line; skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }' README.md > README.md.new
  mv README.md.new README.md
  info "Updating the cards between the cool-readme markers"
else
  { [ -s README.md ] && echo; cat "$block"; } >> README.md
  info "Adding the cards at the end of README.md; move the marked block wherever you like"
fi
if grep -q 'github-readme-stats' README.md; then
  warn "README.md still has github-readme-stats images; remove them if these cards replace them."
fi
commit_and_push "Show README cards" || true

step "Done"
if $DRY_RUN; then
  info "Dry run: nothing was changed."
else
  info "Your profile: https://github.com/$LOGIN"
  info "The cards update daily. To refresh now: gh workflow run $(basename "$WORKFLOW") -R $PROFILE"
fi
