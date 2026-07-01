final: prev:
let
  lib = final.lib;

  # Patched hashview source, shared by the packages and every test tier.
  # The app has no env hooks and hardcodes MySQL/relative paths, so we inject a
  # handful of environment overrides and make create_app() testable. See the
  # substituteInPlace calls below for the exact, reviewable edits.
  patchedSrc = final.applyPatches {
    name = "hashview-patched-src";
    src = lib.cleanSource ../.;
    # Harden the agent-facing rule/wordlist download endpoints (subprocess.run
    # list-args + filename allow-list instead of os.system string) - matches the
    # regression tests in tests/security/.
    patches = [ ./0001-security-fix-command-injection.patch ];
    postPatch = ''
      # --- config.py: honor HASHVIEW_DATABASE_URI (socket / arbitrary override)
      substituteInPlace hashview/config.py \
        --replace-fail "from configparser import ConfigParser" "import os
from configparser import ConfigParser" \
        --replace-fail "    SQLALCHEMY_DATABASE_URI = (" "    SQLALCHEMY_DATABASE_URI = os.environ.get('HASHVIEW_DATABASE_URI') or ("

      # --- hashview.py: make the --no-ssl listener host/port configurable
      substituteInPlace hashview.py \
        --replace-fail "            app.run(debug=parsed_args.debug)" "            app.run(host=os.environ.get('HASHVIEW_HOST', '127.0.0.1'), port=int(os.environ.get('HASHVIEW_PORT', '5000')), debug=parsed_args.debug)"

      # --- __init__.py: create_app(testing, config_overrides) + skip flags
      substituteInPlace hashview/__init__.py \
        --replace-fail "import logging
import datetime" "import logging
import os
import datetime" \
        --replace-fail "def create_app():" "def create_app(testing=False, config_overrides=None):" \
        --replace-fail "    from hashview.config import Config
    app.config.from_object(Config)" "    from hashview.config import Config
    app.config.from_object(Config)
    if testing:
        app.config['TESTING'] = True
    if config_overrides:
        app.config.update(config_overrides)
    _skip_setup = app.config.get('HASHVIEW_SKIP_SETUP', os.environ.get('HASHVIEW_SKIP_SETUP'))
    _skip_gui = app.config.get('HASHVIEW_SKIP_GUI_SETUP', os.environ.get('HASHVIEW_SKIP_GUI_SETUP'))
    _disable_scheduler = app.config.get('HASHVIEW_DISABLE_SCHEDULER', os.environ.get('HASHVIEW_DISABLE_SCHEDULER'))" \
        --replace-fail "    scheduler.init_app(app)
    scheduler.start()" "    scheduler.init_app(app)
    if not _disable_scheduler:
        scheduler.start()" \
        --replace-fail "        logger.info('Upgrading Database if needed Progressing.')
        import alembic.command
        migrate_ext = current_app.extensions['migrate']
        config = migrate_ext.migrate.get_config(migrate_ext.directory)
        # set configure_logger so that migrations/env.py doesn't override the logging setup
        config.attributes['configure_logger'] = False
        alembic.command.upgrade(config, 'head')
        logger.info('Upgrading Database if needed is Complete.')" "        import alembic.command
        from sqlalchemy import inspect as _sa_inspect
        migrate_ext = current_app.extensions['migrate']
        config = migrate_ext.migrate.get_config(migrate_ext.directory)
        # set configure_logger so that migrations/env.py doesn't override the logging setup
        config.attributes['configure_logger'] = False
        # The upstream migration chain is drifted (models ahead of migrations)
        # and not MySQL-clean. For a fresh DB, build the schema straight from the
        # models and stamp it as current; only replay migrations on an existing
        # schema (upgrade path for pre-existing installs).
        if _sa_inspect(db.engine).has_table('users'):
            logger.info('Existing schema detected; running migrations.')
            alembic.command.upgrade(config, 'head')
        else:
            logger.info('Fresh database; creating schema from models.')
            db.create_all()
            alembic.command.stamp(config, 'head')
        logger.info('Database schema ready.')" \
        --replace-fail "    with app.app_context():
        setup_defaults_if_needed()

    app.before_request(do_gui_setup_if_needed)" "    if not _skip_setup:
        with app.app_context():
            setup_defaults_if_needed()

    if not _skip_gui:
        app.before_request(do_gui_setup_if_needed)"

      # --- hashview.py: skip the interactive CLI admin/settings prompts when
      # running headless (systemd). First-run admin + settings are created via
      # the GUI /setup flow instead (do_gui_setup_if_needed).
      substituteInPlace hashview.py \
        --replace-fail "            ensure_settings_cli(db)
            ensure_admin_account_cli(db, bcrypt)" "            if not os.environ.get('HASHVIEW_NONINTERACTIVE'):
                ensure_settings_cli(db)
                ensure_admin_account_cli(db, bcrypt)"

      # --- agent api.heartbeat: tolerate a non-JSON / unexpected response (the
      # server redirects to /setup while first-run setup is pending, and may be
      # briefly restarting) instead of crashing the agent with a JSONDecodeError.
      substituteInPlace install/hashview-agent/agent/api/api.py \
        --replace-fail "    response = http.post('/v1/agents/heartbeat', json.loads(json.dumps(message)))
    decoded_response = json.loads(response)
    if decoded_response['type'] == 'message' and decoded_response['status'] == 200:
        return decoded_response
    elif decoded_response['type'] == 'message' and decoded_response['status'] == 426:
        print('Our agent version is older than the servers. You need to upgrade your agent before continuing.')
        exit()
    else:
        print('we got an unexpected response type')
        print(str(decoded_response['type']))" "    response = http.post('/v1/agents/heartbeat', json.loads(json.dumps(message)))
    try:
        decoded_response = json.loads(response)
    except (ValueError, TypeError):
        # Server not ready (setup redirect / restart) - retry on next loop.
        return {'msg': 'Retry'}
    if decoded_response.get('type') == 'message' and decoded_response.get('status') == 200:
        return decoded_response
    elif decoded_response.get('type') == 'message' and decoded_response.get('status') == 426:
        print('Our agent version is older than the servers. You need to upgrade your agent before continuing.')
        exit()
    else:
        return {'msg': 'Retry'}"

      # --- models.py: the hashes.ciphertext VARCHAR(16383) is ~65534 bytes under
      # utf8mb4, which alone overflows MySQL's 65535 in-row limit and makes
      # create_all abort. It is unindexed, so store it off-page as TEXT.
      substituteInPlace hashview/models.py \
        --replace-fail "ciphertext = db.Column(db.String(16383), nullable=False)" "ciphertext = db.Column(db.Text, nullable=False)"

      # --- drop the historical SQLAlchemy pin (we run 2.x from nixpkgs)
      substituteInPlace requirements.txt \
        --replace-fail "sqlalchemy==1.4.27" "sqlalchemy"
    '';
  };

  hashviewPython = final.python3.override {
    self = hashviewPython;
    packageOverrides = import ./python-deps.nix;
  };

  runtimePyDeps = ps: with ps; [
    flask
    flask-wtf
    flask-sqlalchemy
    flask-login
    flask-mail
    flask-migrate
    flask-apscheduler
    wtforms-sqlalchemy
    email-validator
    packaging
    authlib
    requests
    mysql-connector
    bcrypt-flask
    transliterate
  ];

  agentPyDeps = ps: with ps; [ psutil requests ];

  testPyDeps = ps: (runtimePyDeps ps) ++ (with ps; [
    pytest
    pytest-base-url
    pytest-playwright
    playwright
  ]);

in
{
  inherit patchedSrc hashviewPython;

  hashviewRuntimePython = hashviewPython.withPackages runtimePyDeps;
  hashviewTestPython = hashviewPython.withPackages testPyDeps;

  hashview-web = final.callPackage ./hashview-web.nix {
    inherit patchedSrc;
    python = hashviewPython;
    pythonDeps = runtimePyDeps;
  };

  hashview-agent = final.callPackage ./hashview-agent.nix {
    inherit patchedSrc;
    python = hashviewPython;
    pythonDeps = agentPyDeps;
  };
}
