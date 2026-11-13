# venomx shell integration for fish. Load with: venomx shell init --shell=fish | source
# OSC 133 marks: A at each prompt, C with the
# percent-encoded command line before a command runs, D with its exit status.
# Only inside a venomx pane, and only once per shell.
if set -q VENOMX_PANE; and not set -q _venomx_shell_init
    set -g _venomx_shell_init 1
    function _venomx_preexec --on-event fish_preexec
        printf '\e]133;C;cmdline_url=%s\a' (string escape --style=url -- $argv[1])
    end
    function _venomx_postexec --on-event fish_postexec
        printf '\e]133;D;%d\a' $status
    end
    function _venomx_prompt --on-event fish_prompt
        printf '\e]133;A\a'
    end
end
