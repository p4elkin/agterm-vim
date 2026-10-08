Throwaway spike for the Rebased overlay; results in `../20261007-rebased-overlay-verification.md`.

    ./build.sh /tmp/rbs1 /tmp/rbspike-proj        # plugin (javac + zip) into /tmp/rbs1/plugins, host, test repo
    /tmp/rbs1/spike /tmp/rbs1 /tmp/rbspike-proj will   # frame, hide/show, full screen, dialog, save at quit
    /tmp/rbs1/spike /tmp/rbs1 /tmp/rbspike-proj menu   # in-frame IDE menu and key routing

Copy a config dir from an earlier run into `/tmp/rbs1/config` to skip first-run dialogs. `build.sh ... ghostty`
links `libghostty-internal.a` and calls `ghostty_init` first.
