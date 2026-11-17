# CIRRUS RStudio session environment for login shells (the Terminal tab).

# The session's ssh-agent, for bao-getkey and ssh to Casper/Derecho. It normally
# arrives through the environment (bin/cirrus-rsession); this is a fallback for
# a shell that lost it. Only when unset, so a user's own agent is left alone.
if [ -z "${SSH_AUTH_SOCK:-}" ] && [ -S "${CIRRUS_RSTUDIO_STATE_DIR:-/tmp/cirrus-rstudio}/ssh-agent.sock" ]; then
    SSH_AUTH_SOCK="${CIRRUS_RSTUDIO_STATE_DIR:-/tmp/cirrus-rstudio}/ssh-agent.sock"
    export SSH_AUTH_SOCK
fi

# Show the user name in the prompt. With the uid mapped through nss_wrapper,
# bash's \u can render as the bare uid, which looks like a broken session.
# Only the stock prompts are replaced; a PS1 the user set is left alone.
case "$-" in
    *i*)
        case "${PS1:-}" in
            '\s-\v\$ '|'\s-\v\$'|'\u@\h:\w\$ '|'\h:\w\$ '|'$ '|'')
                [ -n "${USER:-}" ] && PS1="${USER}@\h:\w\$ "
                ;;
        esac
        ;;
esac
