# Unit tier: hermetic in-sandbox run of the in-process security tests
# (tests/security/test_command_injection_poc.py). No network, MySQL, hashcat or
# browser - just create_app(testing=True, config_overrides={sqlite memory}).
{ runCommand, hashviewTestPython, patchedSrc }:

runCommand "hashview-unit-tests"
{
  nativeBuildInputs = [ hashviewTestPython ];
} ''
  cp -r ${patchedSrc} src
  chmod -R u+w src
  cd src

  # Config's class body reads hashview/config.conf at import time (before the
  # per-app SQLite override lands), so a syntactically complete config must
  # exist. The DB creds here are never used - the tests override the URI. Use a
  # real SERVER_NAME (the example's "FQDN:PORT" breaks Werkzeug URL building).
  printf '%s\n' \
    '[SERVER]' 'SERVER_NAME = localhost' 'SECRET_KEY = test-secret-key' \
    '[database]' 'host = localhost' 'username = hashview' 'password = hashview' \
    '[SMTP]' 'server = localhost' 'port = 25' 'use_tls = False' \
    'username =' 'password =' 'default_sender = hashview@localhost' \
    > hashview/config.conf

  # Control dirs the download endpoints write into (always present at runtime).
  mkdir -p hashview/control/tmp hashview/control/rules hashview/control/wordlists

  export HOME=$TMPDIR
  # --noconftest: tests/conftest.py has autouse Playwright fixtures (page/
  # live_server) that would launch a browser; the security tests only use the
  # builtin monkeypatch fixture, so skip conftest entirely for this tier.
  python -m pytest --noconftest -m security tests/security -vv --no-header

  touch $out
''
