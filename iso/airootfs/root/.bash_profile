# RigCheck: auto-start on tty1 (bash variant; releng default shell is zsh — see .zlogin)
if [ "$(tty)" = "/dev/tty1" ]; then
    /usr/local/bin/rigcheck-launch
    echo
    echo "RigCheck finished. You are now in a root shell (run 'rigcheck-launch' to test again)."
fi
