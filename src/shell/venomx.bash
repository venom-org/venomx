# venomx shell integration for bash 4.4+. Load with: eval "$(venomx shell init --shell=bash)"
# OSC 133 marks: A at each prompt, C with the
# percent-encoded command line before a command runs (PS0), D with its exit
# status. Only inside a venomx pane, and only once per shell.
if [[ -n ${VENOMX_PANE-} && -z ${_venomx_shell_init-} ]]; then
  _venomx_shell_init=1
  _venomx_url() {
    local LC_ALL=C s=$1 c i
    REPLY=
    for (( i = 0; i < ${#s}; i++ )); do
      c=${s:i:1}
      case $c in
        [A-Za-z0-9._~/-]) REPLY+=$c ;;
        *) printf -v c '%%%02X' "'$c"; REPLY+=$c ;;
      esac
    done
  }
  # PS0 runs in a subshell after the line is read: the line is the newest
  # history entry only if history grew since the prompt.
  _venomx_c() {
    local REPLY line=
    if [[ ${HISTCMD-} != "${_venomx_hist-}" ]]; then
      line=$(HISTTIMEFORMAT= builtin history 1)
      line=${line#*[0-9]  }
    fi
    _venomx_url "$line"
    printf '\e]133;C;cmdline_url=%s\a' "$REPLY"
  }
  _venomx_prompt() {
    local s=$?
    printf '\e]133;D;%d\a\e]133;A\a' "$s"
    _venomx_hist=$HISTCMD
    return $s
  }
  PS0='$(_venomx_c)'"${PS0-}"
  PROMPT_COMMAND="_venomx_prompt${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
fi
