# CIRRUS RStudio session environment for login shells.
#
# RStudio spawns its Terminal tab as `bash --login --posix`, and in POSIX mode
# bash expands \u from the uid rather than from the passwd entry -- verified:
#
#   $ bash          -c 'PS1="\u"; printf %s "${PS1@P}"'   ->  ncote
#   $ bash --posix  -c 'PS1="\u"; printf %s "${PS1@P}"'   ->  54321
#
# with nss_wrapper active and `whoami` answering ncote in both. So the prompt
# alone would read as a broken session while everything else worked. $USER is
# set correctly by the entrypoint, so use it.
#
# Only for interactive shells, and only when the default prompt is still in
# place: anyone who sets PS1 in their own ~/.profile or ~/.bashrc means it.
case "$-" in
    *i*)
        case "${PS1:-}" in
            # bash's stock prompts, and the Ubuntu default. Anything else is the
            # user's and is left alone.
            '\s-\v\$ '|'\s-\v\$'|'\u@\h:\w\$ '|'\h:\w\$ '|'$ '|'')
                if [ -n "${USER:-}" ]; then
                    PS1="${USER}@\h:\w\$ "
                fi
                ;;
        esac
        ;;
esac
