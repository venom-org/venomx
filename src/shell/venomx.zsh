# venomx shell integration for zsh. Load with: eval "$(venomx shell init --shell=zsh)"
# OSC 133 marks: A at each prompt, C with the
# percent-encoded command line before a command runs, D with its exit status.
# Only inside a venomx pane, and only once per shell.
if [[ -n ${VENOMX_PANE-} && -z ${_venomx_shell_init-} ]]; then
  typeset -g _venomx_shell_init=1 _venomx_ran=0
  _venomx_url() {
    emulate -L zsh
    setopt no_multibyte
    local s=$1 c
    local -i i
    REPLY=
    for (( i = 1; i <= ${#s}; i++ )); do
      c=${s[i]}
      case $c in
        [A-Za-z0-9._~/-]) REPLY+=$c ;;
        *) printf -v c '%%%02X' "'$c"; REPLY+=$c ;;
      esac
    done
  }
  _venomx_preexec() {
    local REPLY
    _venomx_url "$1"
    _venomx_ran=1
    print -rn -- $'\e]133;C;cmdline_url='"$REPLY"$'\a'
  }
  _venomx_precmd() {
    local s=$?
    if (( _venomx_ran )); then
      print -rn -- $'\e]133;D;'"$s"$'\a'
      _venomx_ran=0
    fi
    print -rn -- $'\e]133;A\a'
  }
  typeset -ga preexec_functions precmd_functions
  preexec_functions+=(_venomx_preexec)
  precmd_functions=(_venomx_precmd $precmd_functions)
fi
