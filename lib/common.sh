# shellcheck shell=bash
# Shared by secret-take and secret-keys. Sourced, never run.
#
# Nothing in here prints a secret value or passes one to another program as an
# argument: values travel in shell variables and on pipes only.

clip_read() {
  timeout 2s wl-paste --no-newline --type text 2>/dev/null || true
}

# Why a string is not accepted as a key from the clipboard, or nothing when it
# is. A key is one unbroken run of at least eight characters. A single quote is
# refused because .env readers disagree on how to escape one.
why_not_a_key() {
  local v=$1
  if [[ -z $v ]]; then
    echo empty
  elif [[ $v == *$'\n'* ]]; then
    echo lines
  elif [[ $v == *[[:space:]]* ]]; then
    echo spaces
  elif [[ $v == *\'* ]]; then
    echo quote
  elif ((${#v} < 8)); then
    echo short
  fi
}

plausible() {
  [[ -z $(why_not_a_key "$1") ]]
}

# Published prefixes that say which service issued a key, longest first where
# one is the start of another. Used to suggest a name; never to reject a key.
KNOWN_PREFIXES=(
  "sk-ant- ANTHROPIC_API_KEY"
  "sk-or- OPENROUTER_API_KEY"
  "sk-proj- OPENAI_API_KEY"
  "sk_live_ STRIPE_SECRET_KEY"
  "sk_test_ STRIPE_SECRET_KEY"
  "pk_live_ STRIPE_PUBLISHABLE_KEY"
  "pk_test_ STRIPE_PUBLISHABLE_KEY"
  "whsec_ STRIPE_WEBHOOK_SECRET"
  "github_pat_ GITHUB_TOKEN"
  "ghp_ GITHUB_TOKEN"
  "gho_ GITHUB_TOKEN"
  "glpat- GITLAB_TOKEN"
  "xoxb- SLACK_BOT_TOKEN"
  "xoxp- SLACK_USER_TOKEN"
  "AKIA AWS_ACCESS_KEY_ID"
  "AIza GOOGLE_API_KEY"
  "hf_ HF_TOKEN"
  "gsk_ GROQ_API_KEY"
  "r8_ REPLICATE_API_TOKEN"
  "SG. SENDGRID_API_KEY"
  "re_ RESEND_API_KEY"
  "xai- XAI_API_KEY"
  "pplx- PERPLEXITY_API_KEY"
  "tvly- TAVILY_API_KEY"
  "fc- FIRECRAWL_API_KEY"
  "npm_ NPM_TOKEN"
  "dop_v1_ DIGITALOCEAN_TOKEN"
  "tskey- TAILSCALE_AUTHKEY"
  "sbp_ SUPABASE_ACCESS_TOKEN"
  "sk- OPENAI_API_KEY"
)

# Sets KEY_HINT (the few leading characters it is safe to show) and KEY_GUESS
# (a likely variable name, or empty when the prefix is not a known one).
describe_key() {
  local v=$1 pair prefix n
  KEY_HINT=
  KEY_GUESS=
  for pair in "${KNOWN_PREFIXES[@]}"; do
    prefix=${pair%% *}
    if [[ $v == "$prefix"* ]]; then
      KEY_HINT=$prefix
      KEY_GUESS=${pair#* }
      return 0
    fi
  done
  # Unknown issuer: show an eighth of the key, four characters at most.
  n=$((${#v} / 8))
  ((n > 4)) && n=4
  KEY_HINT=${v:0:n}
  return 0
}

# How git treats a file: not-git, ignored, not-ignored or tracked. A tracked
# file is reported apart because adding it to .gitignore would not untrack it.
git_state() {
  local dir=${1%/*} base=${1##*/}
  if [[ $(git -C "$dir" rev-parse --is-inside-work-tree 2>/dev/null) != true ]]; then
    echo not-git
  elif git --literal-pathspecs -C "$dir" ls-files --error-unmatch -- "$base" >/dev/null 2>&1; then
    echo tracked
  elif git -C "$dir" check-ignore -q -- "$base" 2>/dev/null; then
    echo ignored
  else
    echo not-ignored
  fi
}

# Names another version control system when a folder is under one. This tool
# checks git only, so for these it cannot say whether the file is kept out.
other_vcs() {
  local dir=$1
  while [[ -n $dir && $dir != / ]]; do
    if [[ -d $dir/.hg ]]; then echo Mercurial; return 0; fi
    if [[ -d $dir/.jj ]]; then echo Jujutsu; return 0; fi
    if [[ -d $dir/.svn ]]; then echo Subversion; return 0; fi
    if [[ -d $dir/.pijul ]]; then echo Pijul; return 0; fi
    if [[ -e $dir/.fslckout || -e $dir/_FOSSIL_ ]]; then echo Fossil; return 0; fi
    dir=${dir%/*}
  done
  return 0
}

ENV_SQ="^'([^']*)'"
ENV_DQ='^"(([^"\\]|\\.)*)"'

# Reads NAME from a .env file into ENV_VALUE. Returns 1 when the name is not in
# the file. When a name repeats, the last one wins, as it does when the file is
# sourced by a shell.
env_get() {
  local file=$1 name=$2 line rest found=1
  ENV_VALUE=
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?$name[[:space:]]*=(.*)$ ]]; then
      rest=${BASH_REMATCH[2]}
      rest=${rest#"${rest%%[![:space:]]*}"}
      if [[ $rest =~ $ENV_SQ ]]; then
        rest=${BASH_REMATCH[1]}
      elif [[ $rest =~ $ENV_DQ ]]; then
        rest=${BASH_REMATCH[1]}
        rest=${rest//\\\"/\"}
        rest=${rest//\\\$/\$}
        rest=${rest//\\\\/\\}
      else
        [[ $rest == \#* ]] && rest=
        rest=${rest%%[[:space:]]#*}
        rest=${rest%"${rest##*[![:space:]]}"}
      fi
      ENV_VALUE=$rest
      found=0
    fi
  done <"$file"
  return $found
}

# The line that stores NAME=value: bare when every character is safe unquoted,
# single-quoted (literal) otherwise.
env_line() {
  local name=$1 value=$2
  if [[ $value =~ ^[A-Za-z0-9_.:/+=@%,-]+$ ]]; then
    ENV_LINE="$name=$value"
  else
    ENV_LINE="$name='$value'"
  fi
}

is_name() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

# An absolute path with symlinks in the directory part resolved, for a file
# that may not exist yet. Prints nothing when the directory is missing.
resolve_file() {
  local file=$1 dir
  [[ -L $file ]] && file=$(realpath -- "$file")
  dir=$(dirname -- "$file")
  [[ -d $dir ]] || return 1
  printf '%s/%s\n' "$(realpath -- "$dir")" "$(basename -- "$file")"
}
