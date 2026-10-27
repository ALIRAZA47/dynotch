# Shows a notice in the notch when a shell command that ran for a while finishes.
# Source it from ~/.zshrc:
#
#     source /path/to/Dynotch.app/Contents/Resources/notify-long-commands.zsh
#
# It needs the dynotch command on your PATH. DYNOTCH_LONG_COMMAND sets the
# threshold in seconds (30 by default).

zmodload zsh/datetime
typeset -g _dynotch_started _dynotch_command

_dynotch_preexec() {
    _dynotch_started=$EPOCHREALTIME
    _dynotch_command=$1
}

_dynotch_precmd() {
    local exit_code=$?
    [[ -n $_dynotch_started ]] || return 0
    local seconds=$(( ${EPOCHREALTIME%.*} - ${_dynotch_started%.*} ))
    _dynotch_started=
    (( seconds >= ${DYNOTCH_LONG_COMMAND:-30} )) || return 0
    (( $+commands[dynotch] )) || return 0

    local took="${seconds}s"
    (( seconds >= 60 )) && took="$(( seconds / 60 ))m $(( seconds % 60 ))s"
    local detail="${_dynotch_command[1,90]} · $took"
    if (( exit_code == 0 )); then
        dynotch notify "Done" --detail "$detail" --symbol checkmark.circle.fill --tint green &!
    else
        dynotch notify "Failed" --detail "$detail" --symbol xmark.octagon.fill --tint red &!
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _dynotch_preexec
add-zsh-hook precmd _dynotch_precmd
