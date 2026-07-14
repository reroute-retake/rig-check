# RigCheck: auto-start the diagnostic suite on the primary console.
# On other TTYs (Alt+F2...) you get a normal root shell for debugging.
if [[ "$(tty)" == "/dev/tty1" ]]; then
    /usr/local/bin/rigcheck-launch
    echo
    echo "RigCheck finished. You are now in a root shell (run 'rigcheck-launch' to test again)."
fi
