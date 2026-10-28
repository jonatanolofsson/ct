# ct — checks mirror .github/workflows/ci.yml

check: lint test

lint:
    bash -n bin/ct bin/ct-autostart bin/ct-profile bin/ensure-nix install.sh
    perl -c bin/ct-scratch-guard
    shellcheck -x bin/ct bin/ct-autostart bin/ct-profile bin/ensure-nix install.sh

test:
    bats tests/
