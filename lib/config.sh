# shellcheck shell=bash
# Settings: the schema (config/settings.schema), validation, and the interactive wizard.
# Sourced by lib/common.sh. Nothing here needs root.
#
#   configure_main [options]   the wizard behind `./setup.sh configure`
#   cfg_ensure KEY...          make sure those settings are valid, asking only for the ones that are not
#   cfg_apply_defaults         load_config uses it: schema defaults for settings missing from node.env
#
# Test seam: HS_INPUT=file supplies the answers (one per line, empty line = accept the default).

if [[ -n ${HS_CONFIG_LOADED:-} ]]; then return 0; fi
HS_CONFIG_LOADED=1

declare -ga CFG_KEYS=()
declare -gA CFG_SCOPE=() CFG_LEVEL=() CFG_TYPE=() CFG_DEFAULT=() CFG_WHEN=() CFG_PROMPT=() CFG_HELP=() CFG_GROUP=()
declare -gA CFG_VAL=()
declare -ga CFG_EXTRA=()
declare -gA CFG_FORCED=()
CFG_NORM='' CFG_ERR='' CFG_DEF='' CFG_DEF_SRC=''

# ---- interaction -------------------------------------------------------------

# _hs_tty_ok  - can /dev/tty really be opened? (it can exist without a controlling terminal)
_hs_tty_ok() { (: </dev/tty) 2>/dev/null; }

# is_interactive  - may we ask the user? (no with --yes, and no without a terminal)
is_interactive() {
  [[ ${ASSUME_YES:-0} != 1 ]] || return 1
  [[ -n ${HS_INPUT:-} ]] && return 0
  [[ -t 0 ]] && _hs_tty_ok
}

_hs_input_open() {
  if [[ -n ${HS_INPUT:-} && -z ${HS_INPUT_OPEN:-} ]]; then
    exec 9<"$HS_INPUT" || die "cannot read the answers file $HS_INPUT"
    export HS_INPUT_OPEN=1
  fi
}

# read_answer "prompt"  - sets ANSWER (trimmed); reads the terminal, or HS_INPUT when set
read_answer() {
  local p=$1
  if [[ -n ${HS_INPUT:-} ]]; then
    _hs_input_open
    printf '%s' "$p" >&2
    IFS= read -r -u 9 ANSWER || [[ -n $ANSWER ]] || die "the scripted answers (HS_INPUT) ran out at: $p"
    printf '%s\n' "$ANSWER" >&2
  else
    _hs_tty_ok || die "there is no terminal to ask on: $p  (give the value as an option, or use --yes for the defaults)"
    IFS= read -r -p "$p" ANSWER </dev/tty || die "input ended at: $p"
  fi
  ANSWER=${ANSWER%$'\r'}
  ANSWER=${ANSWER#"${ANSWER%%[![:space:]]*}"}
  ANSWER=${ANSWER%"${ANSWER##*[![:space:]]}"}
}

# ask_yesno "Question?" [y|n]  - status 0 for yes. Without a terminal (or with --yes) the default answers.
ask_yesno() {
  local q=$1 def=${2:-n} hint
  if [[ $def == y ]]; then hint='Y/n'; else hint='y/N'; fi
  if ! is_interactive; then [[ $def == y ]]; return; fi
  while :; do
    read_answer "$q [$hint] "
    case ${ANSWER,,} in
      '') [[ $def == y ]]; return ;;
      y | yes) return 0 ;;
      n | no) return 1 ;;
      *) warn "please answer y or n" ;;
    esac
  done
}

# ask_flag VAR "Question?" [y|n]  - set VAR to 1/0 unless a command-line flag already did
ask_flag() {
  local var=$1 q=$2 def=${3:-n}
  [[ -z ${!var:-} ]] || return 0
  if ask_yesno "$q" "$def"; then printf -v "$var" '%s' 1; else printf -v "$var" '%s' 0; fi
}

# ask_text VAR "Question" [default]  - set VAR from the answer unless it is already set; an empty answer takes the default
ask_text() {
  local var=$1 q=$2 def=${3:-}
  [[ -z ${!var:-} ]] || return 0
  if ! is_interactive; then printf -v "$var" '%s' "$def"; return 0; fi
  read_answer "$q${def:+ [$def]}: "
  printf -v "$var" '%s' "${ANSWER:-$def}"
}

# ---- schema ------------------------------------------------------------------

cfg_schema_load() {
  [[ ${#CFG_KEYS[@]} -eq 0 ]] || return 0
  local f=${HS_SCHEMA:-$HS_ROOT/config/settings.schema} line group='' key scope level type def when prompt help
  [[ -f $f ]] || die "missing $f"
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    case $line in
      '#>'*) group=${line#'#>'}; group=${group# }; continue ;;
      '#'* | '') continue ;;
    esac
    IFS='|' read -r key scope level type def when prompt help <<<"$line"
    CFG_KEYS+=("$key")
    CFG_SCOPE[$key]=$scope CFG_LEVEL[$key]=$level CFG_TYPE[$key]=$type CFG_DEFAULT[$key]=$def
    CFG_WHEN[$key]=$when CFG_PROMPT[$key]=$prompt CFG_HELP[$key]=$help CFG_GROUP[$key]=$group
  done <"$f"
}

cfg_reset_values() {
  CFG_VAL=()
  CFG_EXTRA=()
}

# cfg_expand "text with {KEY}"  - fill in other settings' current values
cfg_expand() {
  local s=$1 k
  for k in $(grep -o '{[A-Z0-9_]*}' <<<"$s" | tr -d '{}'); do s=${s//"{$k}"/${CFG_VAL[$k]-}}; done
  printf '%s' "$s"
}

# cfg_net a.b.c.d/p  - the network address of that interface address, e.g. 192.168.1.150/24 -> 192.168.1.0/24
cfg_net() {
  local ip=${1%/*} p=${1#*/} a b c d n mask
  p=$((10#$p))
  IFS=. read -r a b c d <<<"$ip"
  n=$(((a << 24) | (b << 16) | (c << 8) | d))
  if ((p == 0)); then mask=0; else mask=$(((0xFFFFFFFF << (32 - p)) & 0xFFFFFFFF)); fi
  n=$((n & mask))
  printf '%d.%d.%d.%d/%d' $((n >> 24 & 255)) $((n >> 16 & 255)) $((n >> 8 & 255)) $((n & 255)) "$p"
}

cfg_detect() {
  local ip c
  case $1 in
    laptop_ip) ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}' ;;
    router_ip) ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "via") { print $(i + 1); exit }}' ;;
    lan_cidr)
      ip=${CFG_VAL[LAPTOP_IP]-}
      [[ -n $ip ]] || return 0
      c=$(ip -4 -o addr show 2>/dev/null | awk -v ip="$ip" '{ split($4, a, "/"); if (a[1] == ip) print $4 }' | head -1)
      cfg_net "${c:-$ip/24}"
      ;;
    admin_user)
      c=${SUDO_USER:-$(id -un 2>/dev/null)}
      [[ $c != root && $c != hermes ]] && printf '%s' "$c"
      ;;
    desktop_ip)
      # someone setting this up over SSH is usually on the desktop
      c=${SSH_CLIENT:-}
      c=${c%% *}
      cfg_valid_ip "$c" && [[ $c != "${CFG_VAL[LAPTOP_IP]-}" ]] && printf '%s' "$c"
      ;;
  esac
  return 0
}

# cfg_default KEY  - sets CFG_DEF (the default value) and CFG_DEF_SRC (schema | detected)
cfg_default() {
  local d=${CFG_DEFAULT[$1]} name fb v
  CFG_DEF_SRC=schema
  if [[ $d == auto:* ]]; then
    d=${d#auto:}
    name=${d%%=*}
    fb=${d#*=}
    v=$(cfg_detect "$name" 2>/dev/null || true)
    if [[ -n $v ]]; then CFG_DEF=$v CFG_DEF_SRC=detected; else CFG_DEF=$fb; fi
    return 0
  fi
  CFG_DEF=$(cfg_expand "$d")
}

# ---- validation --------------------------------------------------------------

cfg_valid_ip() {
  [[ $1 =~ ^(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])(\.(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])){3}$ ]]
}

# cfg_validate TYPE VALUE  - status 0 if valid; CFG_NORM holds the normalised value, CFG_ERR the complaint
cfg_validate() {
  local type=$1 v=$2 lo hi w
  local -a words=()
  CFG_NORM=$v CFG_ERR=''
  if [[ $type != optmodel && -z $v ]]; then CFG_ERR='a value is required'; return 1; fi
  if [[ $v == *[\'\"\`\$]* || $v == *$'\n'* || $v == *$'\r'* ]]; then CFG_ERR='quotes, $ and backticks are not allowed'; return 1; fi
  if [[ $v == *\\* && $type != winpath ]]; then CFG_ERR='backslashes are not allowed here'; return 1; fi
  case $v in
    *yourorg* | *yourrepo* | 12345678+* | *CHANGEME* | *\<*) CFG_ERR='that is still the example value'; return 1 ;;
  esac
  case $type in
    ip)
      cfg_valid_ip "$v" || { CFG_ERR='expected an IPv4 address like 192.168.1.150'; return 1; }
      ;;
    cidr)
      if [[ $v =~ ^([0-9.]+)/([0-9]{1,2})$ ]]; then
        lo=${BASH_REMATCH[1]} hi=${BASH_REMATCH[2]}   # cfg_valid_ip below clobbers BASH_REMATCH
      else
        lo='' hi=0
      fi
      if [[ -n $lo ]] && cfg_valid_ip "$lo" && ((10#$hi >= 8 && 10#$hi <= 30)); then
        CFG_NORM=$(cfg_net "$v")
      else
        CFG_ERR='expected a network like 192.168.1.0/24 (prefix 8 to 30)'
        return 1
      fi
      ;;
    port)
      if ! { [[ $v =~ ^[1-9][0-9]{0,4}$ ]] && ((v <= 65535)); }; then CFG_ERR='expected a port number from 1 to 65535'; return 1; fi
      ;;
    int:*)
      lo=${type#int:}
      hi=${lo#*-}
      lo=${lo%-*}
      if ! { [[ $v =~ ^[0-9]{1,9}$ ]] && ((10#$v >= lo && 10#$v <= hi)); }; then CFG_ERR="expected a whole number from $lo to $hi"; return 1; fi
      CFG_NORM=$((10#$v))
      ;;
    bool01)
      case ${v,,} in
        1 | y | yes | true | on) CFG_NORM=1 ;;
        0 | n | no | false | off) CFG_NORM=0 ;;
        *) CFG_ERR='answer y or n'; return 1 ;;
      esac
      ;;
    unixuser)
      if ! { [[ $v =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] && [[ $v != root ]]; }; then CFG_ERR='expected a lower-case Linux user name (not root)'; return 1; fi
      ;;
    ghname)
      if ! { [[ $v =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$ ]] && [[ $v != *--* ]]; }; then
        CFG_ERR='expected a GitHub user or organisation name (letters, digits, single hyphens)'
        return 1
      fi
      ;;
    repos)
      CFG_NORM=$(tr -s '[:space:]' ' ' <<<"$v")
      CFG_NORM=${CFG_NORM# }
      CFG_NORM=${CFG_NORM% }
      [[ -n $CFG_NORM ]] || { CFG_ERR='a value is required'; return 1; }
      read -r -a words <<<"$CFG_NORM"   # an array: no globbing of '*'
      for w in "${words[@]}"; do
        if ! { [[ $w =~ ^[A-Za-z0-9._-]+$ ]] && [[ $w != . && $w != .. ]]; }; then
          CFG_ERR="'$w' is not a repository name (names only, no owner/ prefix)"
          return 1
        fi
      done
      ;;
    noreply)
      [[ $v =~ ^([0-9]+\+)?[A-Za-z0-9-]+@users\.noreply\.github\.com$ ]] ||
        { CFG_ERR='expected ID+name@users.noreply.github.com (machine account > Settings > Emails)'; return 1; }
      ;;
    model | optmodel)
      if [[ $type == optmodel && ( -z $v || $v == - ) ]]; then CFG_NORM=''; return 0; fi
      [[ $v =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._:+-]+$ ]] || { CFG_ERR='expected an OpenRouter model ID like vendor/model-name'; return 1; }
      ;;
    gguf)
      [[ $v =~ ^[A-Za-z0-9._-]+\.gguf$ ]] || { CFG_ERR='expected a file name ending in .gguf'; return 1; }
      ;;
    url)
      [[ $v =~ ^https://[A-Za-z0-9._~:/?#@!\&*+,\;=%-]+$ ]] || { CFG_ERR='expected an https:// URL without spaces or quotes'; return 1; }
      ;;
    time)
      if [[ $v =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        CFG_NORM=$(printf '%02d:%s' "$((10#${BASH_REMATCH[1]}))" "${BASH_REMATCH[2]}")
      else
        CFG_ERR='expected a time like 01:00 (24-hour)'
        return 1
      fi
      ;;
    winpath)
      [[ $v =~ ^[A-Za-z]:\\[A-Za-z0-9._\\-]+$ ]] || { CFG_ERR='expected a Windows folder without spaces, like C:\llama'; return 1; }
      CFG_NORM=${v%\\}
      ;;
    alias)
      [[ $v =~ ^[A-Za-z][A-Za-z0-9._-]*$ ]] || { CFG_ERR='expected a name starting with a letter (then letters, digits, dots, dashes)'; return 1; }
      case ${v,,} in
        true | false | yes | no | on | off | null | y | n) CFG_ERR="'$v' would be read as a yes/no/null value in the YAML config"; return 1 ;;
      esac
      ;;
    text) ;;
    choice:*)
      lo=${type#choice:}
      for w in ${lo//,/ }; do [[ $v == "$w" ]] && return 0; done
      CFG_ERR="choose one of: ${lo//,/, }"
      return 1
      ;;
    *) CFG_ERR="unknown setting type '$type' in the schema"; return 1 ;;
  esac
  return 0
}

# ---- reading and writing node.env ----------------------------------------------

# cfg_unquote "text after KEY="  - the value the shell would assign: '...' and "..." segments, \x escapes,
# stops at the first unquoted blank (a trailing # comment). Never evaluates anything.
cfg_unquote() {
  local s=$1 out='' c mode=bare i=0 n
  s=${s#"${s%%[![:space:]]*}"}
  n=${#s}
  while ((i < n)); do
    c=${s:i:1}
    case $mode in
      bare)
        case $c in
          "'") mode=single ;;
          '"') mode=double ;;
          \\) i=$((i + 1)); out+=${s:i:1} ;;
          ' ' | $'\t') break ;;
          *) out+=$c ;;
        esac
        ;;
      single) if [[ $c == "'" ]]; then mode=bare; else out+=$c; fi ;;
      double)
        case $c in
          '"') mode=bare ;;
          \\)
            if [[ ${s:i+1:1} == [\"\\\$\`] ]]; then i=$((i + 1)); out+=${s:i:1}; else out+=$c; fi
            ;;
          *) out+=$c ;;
        esac
        ;;
    esac
    i=$((i + 1))
  done
  printf '%s' "$out"
}

cfg_parse_env() {
  local f=$1 line k v
  [[ -f $f ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'}
    [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ $line =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      k=${BASH_REMATCH[2]}
      v=$(cfg_unquote "${BASH_REMATCH[3]}")
      if [[ -n ${CFG_SCOPE[$k]+x} ]]; then CFG_VAL[$k]=$v; else CFG_EXTRA+=("$line"); fi
    else
      CFG_EXTRA+=("$line")   # anything else that is not a comment is kept as found
    fi
  done <"$f"
}

# A 0.1.0-style file pins the model file but has no *_QUANT: read the quantization off the file name
# so choosing the file and the quantization cannot disagree.
cfg_infer_quants() {
  local pair q f
  for pair in LAPTOP DESKTOP; do
    q=${pair}_QUANT f=${pair}_MODEL_FILE
    if [[ -z ${CFG_VAL[$q]+x} && ${CFG_VAL[$f]-} =~ -(UD-Q[0-9]_K_XL)\.gguf$ ]]; then CFG_VAL[$q]=${BASH_REMATCH[1]}; fi
  done
}

# Derived advanced settings that still equal their derived value are forgotten, so they follow
# whatever the settings they derive from become (switching the quantization switches the file).
cfg_drop_derived() {
  local k
  for k in "${CFG_KEYS[@]}"; do
    [[ ${CFG_DEFAULT[$k]} == *\{*\}* && ${CFG_LEVEL[$k]} == advanced && -n ${CFG_VAL[$k]+x} ]] || continue
    [[ ${CFG_VAL[$k]} == "$(cfg_expand "${CFG_DEFAULT[$k]}")" ]] && unset "CFG_VAL[$k]"
  done
}

cfg_quote() {
  local v=$1
  if [[ $v =~ ^[A-Za-z0-9._/:@+,=-]*$ ]]; then printf '%s' "$v"; else printf "'%s'" "${v//\'/\'\\\'\'}"; fi
}

# cfg_write_env FILE|-  - write every setting, grouped and commented ("-" = stdout)
cfg_write_env() {
  local out=$1 k group='' v tmp
  if [[ $out == - ]]; then tmp=$(mktemp); else
    [[ ! -L $out ]] || out=$(readlink -f "$out")
    mkdir -p "$(dirname "$out")" || die "cannot create $(dirname "$out")"
    tmp=$(mktemp "$(dirname "$out")/.node.env.XXXXXX") || die "cannot write in $(dirname "$out")"
  fi
  {
    printf '%s\n' '# HarnessSetup settings - written by ./setup.sh configure.' \
      '# Safe to edit by hand, or run ./setup.sh configure again (it offers these values as the defaults).' \
      '# NO secrets belong here: tokens and API keys are always typed into prompts and stored elsewhere.'
    for k in "${CFG_KEYS[@]}"; do
      if [[ ${CFG_GROUP[$k]} != "$group" ]]; then
        group=${CFG_GROUP[$k]}
        printf '\n# ---- %s ----\n' "$group"
      fi
      v=${CFG_VAL[$k]-}
      if [[ ${CFG_DEFAULT[$k]} == *\{*\}* && ${CFG_LEVEL[$k]} == advanced && $v == "$(cfg_expand "${CFG_DEFAULT[$k]}")" ]]; then
        printf '# %s=%s   (derived from other settings; uncomment to override)\n' "$k" "$(cfg_quote "$v")"
      elif [[ -z ${CFG_VAL[$k]+x} ]]; then
        printf '# %s\n# %s=   (not set yet: you will be asked when a step needs it)\n' "${CFG_PROMPT[$k]}" "$k"
      else
        printf '# %s\n%s=%s\n' "${CFG_PROMPT[$k]}" "$k" "$(cfg_quote "$v")"
      fi
    done
    if ((${#CFG_EXTRA[@]})); then
      printf '\n# ---- Other settings (kept as found) ----\n'
      printf '%s\n' "${CFG_EXTRA[@]}"
    fi
  } >"$tmp"
  if [[ $out == - ]]; then cat "$tmp"; rm -f "$tmp"; return 0; fi
  chmod 644 "$tmp"
  mv "$tmp" "$out" || { rm -f "$tmp"; die "could not save $out"; }
}

# ---- asking --------------------------------------------------------------------

cfg_in_scope() {
  case ${CFG_SCOPE[$1]} in
    both) return 0 ;;
    "${CFG_WIZARD_SCOPE:-laptop}") return 0 ;;
    *) return 1 ;;
  esac
}

cfg_when_ok() {
  local w=${CFG_WHEN[$1]}
  [[ -z $w ]] && return 0
  [[ ${CFG_VAL[${w%%=*}]-} == "${w#*=}" ]]
}

# cfg_value_ok KEY  - does the setting have a usable value (in the file, or a literal default)?
cfg_value_ok() {
  local k=$1 v
  if [[ -n ${CFG_VAL[$k]+x} ]]; then
    v=${CFG_VAL[$k]}
  else
    [[ ${CFG_DEFAULT[$k]} == auto:* ]] && return 1
    v=$(cfg_expand "${CFG_DEFAULT[$k]}")
  fi
  cfg_validate "${CFG_TYPE[$k]}" "$v"
}

# cfg_take_default KEY [noauto]  - keep the current value, else adopt the default (when it is valid).
# With "noauto", detected (auto:) defaults are not adopted silently.
cfg_take_default() {
  local k=$1
  [[ -z ${CFG_VAL[$k]+x} ]] || return 0
  if [[ ${CFG_DEFAULT[$k]} == auto:* ]]; then
    # a detected default is only adopted for settings this wizard owns, and never silently when asked not to
    [[ ${2:-} == noauto ]] && return 0
    cfg_in_scope "$k" || return 0
  fi
  cfg_default "$k"
  [[ -n $CFG_DEF ]] || return 0
  if cfg_validate "${CFG_TYPE[$k]}" "$CFG_DEF"; then CFG_VAL[$k]=$CFG_NORM; fi
}

cfg_fill_rest() {
  local k
  for k in "${CFG_KEYS[@]}"; do cfg_take_default "$k" "${1:-}"; done
}

# cfg_prompt KEY  - ask one setting until the answer is valid
cfg_prompt() {
  local key=$1 def='' src=current hint opts='' i w ans type
  type=${CFG_TYPE[$key]}
  def=${CFG_VAL[$key]-}
  if [[ -n $def ]] && ! cfg_validate "$type" "$def"; then
    warn "the current value of $key is not usable ($CFG_ERR); ignoring it"
    unset "CFG_VAL[$key]"
    def=''
  fi
  if [[ -z ${CFG_VAL[$key]+x} ]]; then
    cfg_default "$key"
    def=$CFG_DEF src=$CFG_DEF_SRC
  fi
  printf '\n' >&2
  fold -s -w 74 <<<"${CFG_HELP[$key]}" | sed 's/^/  /' >&2
  case $type in
    bool01)
      if [[ $def == 1 ]]; then hint='Y/n'; else hint='y/N'; fi
      ;;
    choice:*)
      opts=${type#choice:}
      i=1
      for w in ${opts//,/ }; do
        printf '    %d) %s\n' "$i" "$w" >&2
        i=$((i + 1))
      done
      hint=${def:-none}
      ;;
    *)
      hint=$def
      if [[ -z $hint ]]; then
        if [[ $type == optmodel ]]; then hint=none; else hint=required; fi
      fi
      ;;
  esac
  if [[ $src == detected ]]; then hint="$hint, detected"; fi
  while :; do
    read_answer "  ${CFG_PROMPT[$key]} [$hint]: "
    ans=$ANSWER
    [[ -n $ans ]] || ans=$def
    if [[ $type == choice:* && $ans =~ ^[0-9]+$ ]]; then
      i=1
      for w in ${opts//,/ }; do
        if [[ $i == "$ans" ]]; then ans=$w; fi
        i=$((i + 1))
      done
    fi
    if cfg_validate "$type" "$ans"; then CFG_VAL[$key]=$CFG_NORM; return 0; fi
    warn "$CFG_ERR"
  done
}

cfg_summary() {
  local k v
  printf '\n' >&2
  for k in "${CFG_KEYS[@]}"; do
    [[ ${CFG_LEVEL[$k]} == basic ]] || continue
    cfg_in_scope "$k" || continue
    cfg_when_ok "$k" || continue
    v=${CFG_VAL[$k]-}
    if [[ ${CFG_TYPE[$k]} == bool01 ]]; then
      if [[ $v == 1 ]]; then v=yes; else v=no; fi
    fi
    printf '  %-36s %s\n' "${CFG_PROMPT[$k]}" "${v:-(not set yet)}" >&2
  done
}

# _cfg_pass LEVEL DEFAULTS  - ask (or just default) every in-scope setting of that level
_cfg_pass() {
  local lvl=$1 defaults=$2 k grp=''
  for k in "${CFG_KEYS[@]}"; do
    [[ ${CFG_LEVEL[$k]} == "$lvl" ]] || continue
    cfg_in_scope "$k" || continue
    cfg_when_ok "$k" || continue
    [[ -z ${CFG_FORCED[$k]+x} ]] || continue
    if ((defaults)); then cfg_take_default "$k"; continue; fi
    if [[ ${CFG_GROUP[$k]} != "$grp" ]]; then
      grp=${CFG_GROUP[$k]}
      printf '\n\033[1m== %s ==\033[0m\n' "$grp" >&2
    fi
    cfg_prompt "$k"
  done
}

# configure_main [options]  - the wizard
#   --advanced        also ask the advanced settings (ports, contexts, model files, folders)
#   --only KEY...     ask just these settings (even if they already have values)
#   --set KEY=VALUE   set a value without asking (repeatable; validated)
#   --defaults, --yes accept current values / defaults / detected values without asking
#   --scope laptop|desktop   whose questions to ask (default laptop)
#   --file FILE       settings file (default config/node.env)
#   --print           show the result instead of saving it
#   --answers FILE    read answers from FILE instead of the terminal
configure_main() {
  local file=${NODE_ENV:-$HS_ROOT/config/node.env} advanced=0 defaults=0 print=0 k kv last
  local -a only=() sets=() invalid=() missing=()
  CFG_WIZARD_SCOPE=laptop
  while (($#)); do
    case $1 in
      --advanced) advanced=1 ;;
      --defaults | --yes | -y) defaults=1 ;;
      --print) print=1 ;;
      --only) shift; while (($#)) && [[ $1 != -* ]]; do only+=("$1"); shift; done; continue ;;
      --set) sets+=("${2:?--set needs KEY=VALUE}"); shift ;;
      --scope) CFG_WIZARD_SCOPE=${2:?--scope needs laptop or desktop}; shift ;;
      --file) file=${2:?--file needs a path}; shift ;;
      --answers) HS_INPUT=${2:?--answers needs a file}; export HS_INPUT; shift ;;
      --dry-run) print=1 ;;
      *) die "configure: unknown option $1" ;;
    esac
    shift
  done
  [[ $CFG_WIZARD_SCOPE == laptop || $CFG_WIZARD_SCOPE == desktop ]] || die "--scope must be laptop or desktop"
  cfg_schema_load
  cfg_reset_values
  cfg_parse_env "$file"
  cfg_infer_quants
  cfg_drop_derived
  for kv in "${sets[@]}"; do
    k=${kv%%=*}
    [[ -n ${CFG_SCOPE[$k]+x} ]] || die "--set: unknown setting '$k'"
    cfg_validate "${CFG_TYPE[$k]}" "${kv#*=}" || die "--set $k: $CFG_ERR"
    CFG_VAL[$k]=$CFG_NORM
  done

  if ((${#only[@]})); then
    for k in "${only[@]}"; do
      [[ -n ${CFG_SCOPE[$k]+x} ]] || die "configure: unknown setting '$k'"
      is_interactive || die "configure --only needs a terminal (or use --set $k=VALUE)"
      cfg_prompt "$k"
    done
    cfg_fill_rest noauto
  else
    if ((defaults)); then :; elif is_interactive; then
      cat >&2 <<MSG

HarnessSetup settings. Press Enter to accept the value in [brackets].
Nothing secret is asked for here; the file is $file
MSG
    else
      die "configure needs a terminal to ask on. Use --defaults to accept the defaults, and --set KEY=VALUE for the rest."
    fi
    CFG_FORCED=()
    for kv in "${sets[@]}"; do CFG_FORCED[${kv%%=*}]=1; done
    _cfg_pass basic "$defaults"
    if ((advanced)); then
      _cfg_pass advanced "$defaults"
    elif ((!defaults)) && ask_yesno $'\nReview the advanced settings too (ports, context sizes, model files, folders)?' n; then
      _cfg_pass advanced "$defaults"
    fi
  fi
  ((${#only[@]})) || cfg_fill_rest

  # what is still wrong or missing? (a targeted --only edit does not judge the rest of the file)
  for k in "${CFG_KEYS[@]}"; do
    ((${#only[@]})) && break
    [[ ${CFG_LEVEL[$k]} == basic ]] || continue
    cfg_in_scope "$k" || continue
    cfg_when_ok "$k" || continue
    if [[ -z ${CFG_VAL[$k]-} && ${CFG_TYPE[$k]} != optmodel ]]; then missing+=("$k")
    elif [[ -n ${CFG_VAL[$k]-} ]] && ! cfg_validate "${CFG_TYPE[$k]}" "${CFG_VAL[$k]}"; then invalid+=("$k ($CFG_ERR)"); fi
  done
  if ((${#invalid[@]})); then
    for last in "${invalid[@]}"; do warn "invalid setting: $last"; done
    die "fix those in $file, or run ./setup.sh configure to be asked again"
  fi
  if [[ -n ${CFG_VAL[ADMIN_USER]-} && ${CFG_VAL[ADMIN_USER]-} == "${CFG_VAL[AGENT_USER]-hermes}" ]]; then
    warn "the admin account and the agent account are both '${CFG_VAL[ADMIN_USER]}': the agent should have its own account"
  fi
  if [[ ${CFG_VAL[DESKTOP_IP]-} == "${CFG_VAL[LAPTOP_IP]-x}" ]]; then warn "the laptop and the desktop have the same IP address"; fi
  if [[ ${CFG_VAL[NIGHT_ENABLED]-0} == 1 && ${CFG_VAL[NIGHT_START]-} == "${CFG_VAL[NIGHT_END]-}" ]]; then warn "the overnight tier starts and ends at the same time"; fi

  if ((print)); then
    cfg_write_env -
    return 0
  fi
  if ((${#only[@]})); then
    cfg_write_env "$file"
    ok "saved $file"
    return 0
  fi
  cfg_summary
  if ((!defaults)) && is_interactive; then
    ask_yesno $'\n'"Save these settings to $file?" y || die "not saved"
  fi
  cfg_write_env "$file"
  ok "saved $file"
  if ((${#missing[@]})); then
    warn "not set yet: ${missing[*]} (you will be asked when a step needs them, or run ./setup.sh configure)"
  fi
  return 0
}

# cfg_ensure KEY...  - each setting must have a valid value. Ask for the ones that do not (and save them).
cfg_ensure() {
  local file=${NODE_ENV:-$HS_ROOT/config/node.env} k
  local -a bad=()
  cfg_schema_load
  cfg_reset_values
  cfg_parse_env "$file"
  cfg_infer_quants
  cfg_drop_derived
  for k in "$@"; do
    [[ -n ${CFG_SCOPE[$k]+x} ]] || continue
    cfg_when_ok "$k" || continue
    cfg_value_ok "$k" || bad+=("$k")
  done
  ((${#bad[@]})) || return 0
  if ! is_interactive; then
    die "these settings are missing or invalid: ${bad[*]}. Run ./setup.sh configure --only ${bad[*]}  (or ./setup.sh configure --set KEY=VALUE)"
  fi
  log "this step needs: ${bad[*]}"
  for k in "${bad[@]}"; do cfg_prompt "$k"; done
  cfg_fill_rest noauto
  cfg_write_env "$file"
  ok "saved to $file"
}

# cfg_apply_defaults  - load_config: export schema defaults for settings that node.env did not set.
# Detected defaults (auto:) are never applied silently.
cfg_apply_defaults() {
  local k d
  cfg_schema_load
  CFG_VAL=()
  for k in "${CFG_KEYS[@]}"; do
    if [[ -n ${!k+x} ]]; then CFG_VAL[$k]=${!k}; fi
  done
  cfg_infer_quants
  for k in LAPTOP_QUANT DESKTOP_QUANT; do
    if [[ -z ${!k+x} && -n ${CFG_VAL[$k]+x} ]]; then export "$k=${CFG_VAL[$k]}"; fi
  done
  for k in "${CFG_KEYS[@]}"; do
    [[ -z ${!k+x} ]] || continue
    d=${CFG_DEFAULT[$k]}
    [[ -n $d && $d != auto:* ]] || continue
    d=$(cfg_expand "$d")
    CFG_VAL[$k]=$d
    export "$k=$d"
  done
}
