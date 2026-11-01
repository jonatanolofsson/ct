# ct — `just check` is what CI runs, in this repo's flake (`nix develop --command just check`); locally: `direnv exec . just check`

check: lint test

lint:
    bash -n bin/ct bin/ct-autostart bin/ct-profile bin/ensure-nix install.sh
    perl -c bin/ct-scratch-guard
    shellcheck -x bin/ct bin/ct-autostart bin/ct-profile bin/ensure-nix install.sh

test:
    bats tests/
