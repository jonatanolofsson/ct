# ct — checks mirror .github/workflows/ci.yml

check: lint test

lint:
    bash -n bin/ct bin/ct-autostart bin/ensure-nix install.sh
    shellcheck -x bin/ct bin/ct-autostart bin/ensure-nix install.sh

test:
    bats tests/
