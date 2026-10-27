# Shows a notice in the notch when a shell command that ran for a while finishes.
# Source it from ~/.zshrc:
#
#     source /path/to/Dynotch.app/Contents/Resources/notify-long-commands.zsh
#
# It calls the dynotch command that sits next to it in the app, or failing that one
# on your PATH. DYNOTCH_LONG_COMMAND sets the threshold in seconds (30 by default).
# The notice names the command alone, such as "make": its arguments can hold tokens
# and passwords, and the notch is on screen when you share it. To show them anyway,
# set DYNOTCH_LONG_COMMAND_DETAIL=full.

zmodload zsh/datetime
typeset -g _dynotch_started _dynotch_command
# The dynotch beside this file, found while it's being sourced.
typeset -g _dynotch_bin="${${(%):-%x}:A:h}/dynotch"

_dynotch_preexec() {
    _dynotch_started=$EPOCHREALTIME
    _dynotch_command=$1
}

# The command's name: the first word that isn't an assignment, an option or a wrapper like sudo.
_dynotch_name() {
    local word
    for word in ${(z)1}; do
        case $word in
            *=*|-*|sudo|doas|env|time|nohup|nice|caffeinate|command|exec|builtin|noglob) continue ;;
            *) print -r -- ${word:t}; return ;;
        esac
    done
    print -r -- command
}

_dynotch_precmd() {
    local exit_code=$?
    [[ -n $_dynotch_started ]] || return 0
    local seconds=$(( ${EPOCHREALTIME%.*} - ${_dynotch_started%.*} ))
    _dynotch_started=
    (( seconds >= ${DYNOTCH_LONG_COMMAND:-30} )) || return 0
    local bin=$_dynotch_bin
    [[ -x $bin ]] || bin=$commands[dynotch]
    [[ -n $bin ]] || return 0

    local took="${seconds}s"
    (( seconds >= 60 )) && took="$(( seconds / 60 ))m $(( seconds % 60 ))s"
    local what
    if [[ ${DYNOTCH_LONG_COMMAND_DETAIL:-name} == full ]]; then
        what=${_dynotch_command[1,90]}
    else
        what=$(_dynotch_name "$_dynotch_command")
    fi
    local detail="$what · $took"
    if (( exit_code == 0 )); then
        "$bin" notify "Done" --detail "$detail" --symbol checkmark.circle.fill --tint green &!
    else
        "$bin" notify "Failed" --detail "$detail" --symbol xmark.octagon.fill --tint red &!
    fi
}

autoload -Uz add-zsh-hook
add-zsh-hook preexec _dynotch_preexec
add-zsh-hook precmd _dynotch_precmd
