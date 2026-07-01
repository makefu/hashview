{ config, lib, pkgs, ... }:

let
  cfg = config.services.hashview;

  stateDir = "/var/lib/hashview";
  webWd = "${stateDir}/web";
  agentWd = "${stateDir}/agent";

  webAppDir = "${cfg.web.package}/share/hashview";
  agentAppDir = "${cfg.agent.package}/share/hashview-agent";

  # config.conf sections (secret injected at runtime, so not rendered here).
  # cfg.web.settings deep-merges on top, so any section/key can be extended.
  baseSettings = {
    SERVER = { SERVER_NAME = cfg.web.serverName; };
    database = {
      host = "localhost";
      username = cfg.database.user;
      # Unused: the real connection comes from HASHVIEW_DATABASE_URI. Present
      # only so config.py's Config class body parses without KeyError.
      password = "unused";
    };
    SMTP = {
      server = "localhost";
      port = "25";
      use_tls = "False";
      username = "";
      password = "";
      default_sender = "hashview@localhost";
    };
  };
  configConf = pkgs.writeText "hashview-config.conf"
    (lib.generators.toINI { } (lib.recursiveUpdate baseSettings cfg.web.settings));

  agentBaseSettings = {
    HASHVIEW = {
      server = cfg.agent.server;
      port = toString cfg.agent.port;
      use_ssl = if cfg.agent.useSsl then "True" else "False";
    };
    AGENT = {
      NAME = cfg.agent.name;
      HC_BIN_PATH = lib.getExe cfg.hashcat.package;
      # UUID injected at runtime from the persisted state file.
    };
  };
  agentConfigHead = pkgs.writeText "hashview-agent-config.conf"
    (lib.generators.toINI { } (lib.recursiveUpdate agentBaseSettings cfg.agent.settings));

  bin = {
    coreutils = pkgs.coreutils;
    gzip = pkgs.gzip;
    util-linux = pkgs.util-linux;
    curl = pkgs.curl;
    mariadb = cfg.database.package;
  };

  agentScheme = if cfg.agent.useSsl then "https" else "http";

  # Compose the SQLAlchemy URI (shell fragment setting $uri). connectionString
  # wins; otherwise a socket (default) or TCP URI, with an optional passwordFile.
  composeDbUri =
    if cfg.database.connectionString != null then ''
      uri=${lib.escapeShellArg cfg.database.connectionString}
    '' else ''
      pw=""
      ${lib.optionalString (cfg.database.passwordFile != null)
        ''pw=":$(cat ${lib.escapeShellArg cfg.database.passwordFile})"''}
      ${if cfg.database.host == null then
        ''uri="mysql+mysqlconnector://${cfg.database.user}$pw@/${cfg.database.name}?unix_socket=${cfg.database.socket}"''
      else
        ''uri="mysql+mysqlconnector://${cfg.database.user}$pw@${cfg.database.host}:${toString cfg.database.port}/${cfg.database.name}"''}
    '';

  # The DB password may come from a file, so the URI is composed at start time
  # inside the ExecStart wrapper (EnvironmentFile is parsed before ExecStartPre,
  # so a preStart-written env file would be too late for ExecStart).
  webStart = pkgs.writeShellScript "hashview-web-start" ''
    set -eu
    ${composeDbUri}
    export HASHVIEW_DATABASE_URI="$uri"
    exec ${lib.getExe cfg.web.package} --no-ssl
  '';

in
{
  options.services.hashview = {
    enable = lib.mkEnableOption "Hashview password-cracking manager";

    web = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run the Hashview web server.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.hashview-web;
        defaultText = lib.literalExpression "pkgs.hashview-web";
        description = "Hashview web server package.";
      };
      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Address the web server binds (behind nginx by default).";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 5000;
        description = "Port the web server binds.";
      };
      serverName = lib.mkOption {
        type = lib.types.str;
        default = "localhost";
        description = "SERVER_NAME written into config.conf.";
      };
      secretKeyFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File with the Flask SECRET_KEY. If null, a persistent key is generated
          once under the state directory.
        '';
      };
      settings = lib.mkOption {
        type = with lib.types; attrsOf (attrsOf str);
        default = { };
        example = lib.literalExpression ''
          { SMTP = { server = "smtp.example.com"; use_tls = "True"; }; }
        '';
        description = "Extra config.conf sections/keys, deep-merged over defaults.";
      };
      nginx = {
        enable = lib.mkEnableOption "an nginx reverse proxy terminating TLS in front of Hashview";
        hostName = lib.mkOption {
          type = lib.types.str;
          example = "hashview.example.com";
          description = "Virtual host name for the nginx proxy.";
        };
        enableACME = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Obtain a TLS certificate via ACME/Let's Encrypt.";
        };
        forceSSL = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Redirect HTTP to HTTPS.";
        };
      };
    };

    agent = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run a local Hashview agent.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.hashview-agent;
        defaultText = lib.literalExpression "pkgs.hashview-agent";
        description = "Hashview agent package.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = config.networking.hostName;
        defaultText = lib.literalExpression "config.networking.hostName";
        description = "Agent display name.";
      };
      server = lib.mkOption {
        type = lib.types.str;
        default = cfg.web.host;
        defaultText = lib.literalExpression "config.services.hashview.web.host";
        description = "Hashview server the agent connects to.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = cfg.web.port;
        defaultText = lib.literalExpression "config.services.hashview.web.port";
        description = "Hashview server port the agent connects to.";
      };
      useSsl = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Whether the agent talks TLS to the server.";
      };
      settings = lib.mkOption {
        type = with lib.types; attrsOf (attrsOf str);
        default = { };
        description = "Extra agent config.conf sections/keys, deep-merged over defaults.";
      };
    };

    hashcat.package = lib.mkOption {
      type = lib.types.package;
      default = pkgs.hashcat;
      defaultText = lib.literalExpression "pkgs.hashcat";
      description = "hashcat package the agent invokes (HC_BIN_PATH).";
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Provision a local MariaDB instance and the hashview database.";
      };
      package = lib.mkOption {
        type = lib.types.package;
        default = pkgs.mariadb;
        defaultText = lib.literalExpression "pkgs.mariadb";
        description = "MariaDB/MySQL server package for the local instance.";
      };
      name = lib.mkOption {
        type = lib.types.str;
        default = "hashview";
        description = "Database name.";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "hashview";
        description = "Database user.";
      };
      host = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Remote DB host. null (default) uses the local unix socket.";
      };
      port = lib.mkOption {
        type = lib.types.port;
        default = 3306;
        description = "Remote DB port (ignored for socket connections).";
      };
      socket = lib.mkOption {
        type = lib.types.str;
        default = "/run/mysqld/mysqld.sock";
        description = "MySQL unix socket path for local/socket connections.";
      };
      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          File containing the DB user password. When set, it is read at start
          and used in the connection string (never placed in the store). When
          null with a local socket, passwordless socket auth is used.
        '';
      };
      connectionString = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "mysql+mysqlconnector://user:pass@dbhost/hashview";
        description = "Full SQLAlchemy URI. Overrides all other database options.";
      };
    };
  };

  config = lib.mkIf cfg.enable {

    assertions = [
      {
        assertion = cfg.web.nginx.enable -> cfg.web.enable;
        message = "services.hashview.web.nginx requires services.hashview.web.enable.";
      }
    ];

    users.users.hashview = {
      isSystemUser = true;
      group = "hashview";
      home = stateDir;
    };
    users.groups.hashview = { };

    # ---- local MariaDB ------------------------------------------------------
    services.mysql = lib.mkIf cfg.database.createLocally {
      enable = true;
      package = cfg.database.package;
      # Some hashview model tables are VARCHAR-heavy; building them from the
      # models (create_all) exceeds InnoDB's 65535 in-row limit under strict
      # mode. Relaxing strict mode stores the overflow off-page (DYNAMIC row
      # format) instead of erroring.
      settings.mysqld = {
        innodb_strict_mode = 0;
        innodb_default_row_format = "dynamic";
      };
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [{
        name = cfg.database.user;
        ensurePermissions = { "${cfg.database.name}.*" = "ALL PRIVILEGES"; };
      }];
    };

    # Set the DB user's password from passwordFile (ensureUsers uses socket
    # auth; this switches it to password auth so the app can connect with creds).
    systemd.services.hashview-db-init = lib.mkIf (cfg.database.createLocally && cfg.database.passwordFile != null) {
      description = "Set Hashview database user password";
      after = [ "mysql.service" ];
      requires = [ "mysql.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
      };
      script = ''
        pw=$(cat ${lib.escapeShellArg cfg.database.passwordFile})
        ${bin.mariadb}/bin/mysql -u root <<SQL
        ALTER USER '${cfg.database.user}'@'localhost' IDENTIFIED BY '$pw';
        FLUSH PRIVILEGES;
        SQL
      '';
    };

    # ---- web service --------------------------------------------------------
    systemd.services.hashview-web = lib.mkIf cfg.web.enable {
      description = "Hashview web server";
      wantedBy = [ "multi-user.target" ];
      after = lib.optionals cfg.database.createLocally [ "mysql.service" "hashview-db-init.service" ];
      requires = lib.optionals cfg.database.createLocally
        ([ "mysql.service" ] ++ lib.optional (cfg.database.passwordFile != null) "hashview-db-init.service");

      environment = {
        HASHVIEW_HOST = cfg.web.host;
        HASHVIEW_PORT = toString cfg.web.port;
        HASHVIEW_NONINTERACTIVE = "1";
        PYTHONUNBUFFERED = "1";
      };

      serviceConfig = {
        User = "hashview";
        Group = "hashview";
        # Creates /var/lib/hashview and .../web (owned by hashview) before the
        # unit chdirs into WorkingDirectory (which happens before ExecStartPre).
        StateDirectory = "hashview hashview/web";
        WorkingDirectory = webWd;
        ExecStart = webStart;
        Restart = "on-failure";
        RestartSec = 3;
      };

      preStart = ''
        set -euo pipefail
        export PATH=${bin.coreutils}/bin:${bin.gzip}/bin:$PATH
        wd=${webWd}
        mkdir -p "$wd/hashview"

        # Copy the app code as REAL, writable files into the working tree so
        # Flask's current_app.root_path resolves here (writable), not the store.
        # Contents are merged over the persistent control/ssl dirs (which are not
        # part of the store tree, so they survive restarts).
        cp -rL --no-preserve=mode ${webAppDir}/hashview/. "$wd/hashview/"
        cp -L  --no-preserve=mode ${webAppDir}/hashview.py "$wd/hashview.py"

        # Writable dirs the app writes into (persist across restarts).
        mkdir -p "$wd/hashview/control/tmp" "$wd/hashview/control/rules" \
                 "$wd/hashview/control/wordlists" "$wd/hashview/control/hashes" \
                 "$wd/hashview/control/outfiles" "$wd/hashview/ssl"

        # Seed the tiny best64 rule; rockyou (130MB) is intentionally skipped -
        # default-wordlist seeding is best-effort and wrapped in try/except.
        if [ ! -f "$wd/hashview/control/rules/best64.rule" ]; then
          gunzip -c ${webAppDir}/install/best64.rule.gz > "$wd/hashview/control/rules/best64.rule"
        fi

        # Top-level paths the app references relative to CWD.
        ln -sfn ${webAppDir}/migrations "$wd/migrations"
        ln -sfn ${webAppDir}/install "$wd/install"

        # config.conf: real file (replaces any symlink from the loop), with the
        # SECRET_KEY injected from a file so sessions survive restarts.
        secret_file=${if cfg.web.secretKeyFile != null then toString cfg.web.secretKeyFile else "\"$wd/secret_key\""}
        ${lib.optionalString (cfg.web.secretKeyFile == null) ''
          if [ ! -f "$wd/secret_key" ]; then
            # 64 hex chars from 32 bytes. Read a bounded amount with od so the
            # reader terminates on its own; piping /dev/urandom into `head -c`
            # closes the pipe early and leaves `tr` killed by SIGPIPE, which
            # trips pipefail and fails the whole pre-start.
            (umask 077; od -An -tx1 -N32 /dev/urandom | tr -d ' \n' > "$wd/secret_key")
          fi
        ''}
        rm -f "$wd/hashview/config.conf"
        install -m640 ${configConf} "$wd/hashview/config.conf"
        secret=$(cat "$secret_file")
        sed -i "/^\[SERVER\]$/a SECRET_KEY = $secret" "$wd/hashview/config.conf"
      '';
    };

    # ---- agent service ------------------------------------------------------
    systemd.services.hashview-agent = lib.mkIf cfg.agent.enable {
      description = "Hashview cracking agent";
      wantedBy = [ "multi-user.target" ];
      after = [ "hashview-web.service" ];

      environment.PYTHONUNBUFFERED = "1";

      serviceConfig = {
        User = "hashview";
        Group = "hashview";
        StateDirectory = "hashview hashview/agent";
        WorkingDirectory = agentWd;
        ExecStart = lib.getExe cfg.agent.package;
        Restart = "on-failure";
        RestartSec = 5;
      };

      preStart = ''
        set -euo pipefail
        export PATH=${bin.coreutils}/bin:$PATH
        wd=${agentWd}
        mkdir -p "$wd/agent" "$wd/control/tmp" "$wd/control/outfiles" \
                 "$wd/control/hashes" "$wd/control/rules" "$wd/control/wordlists"

        # Symlink agent code + VERSION.TXT from the store.
        for f in ${agentAppDir}/agent/*; do
          ln -sfn "$f" "$wd/agent/$(basename "$f")"
        done
        ln -sfn ${agentAppDir}/VERSION.TXT "$wd/VERSION.TXT"

        # Persist a stable agent UUID across restarts.
        if [ ! -f "$wd/uuid" ]; then
          ${bin.util-linux}/bin/uuidgen > "$wd/uuid"
        fi
        uuid=$(cat "$wd/uuid")

        # Render agent/config.conf, injecting the persisted UUID into [AGENT]
        # (appending at EOF would land it under the wrong section).
        install -m640 ${agentConfigHead} "$wd/agent/config.conf"
        sed -i "/^\[AGENT\]$/a UUID = $uuid" "$wd/agent/config.conf"

        # Wait for the Hashview server to actually serve before starting: the
        # agent's HTTP session has an aggressive urllib3 retry/backoff (total=100)
        # that blocks for a very long time if the first request hits a server
        # that is not up yet. Bounded so a genuinely-down remote still proceeds.
        for _ in $(seq 1 90); do
          ${bin.curl}/bin/curl -sfk -o /dev/null "${agentScheme}://${cfg.agent.server}:${toString cfg.agent.port}/login" && break
          sleep 2
        done || true
      '';
    };

    # ---- nginx reverse proxy ------------------------------------------------
    services.nginx = lib.mkIf cfg.web.nginx.enable {
      enable = true;
      recommendedProxySettings = true;
      virtualHosts.${cfg.web.nginx.hostName} = {
        enableACME = cfg.web.nginx.enableACME;
        forceSSL = cfg.web.nginx.forceSSL;
        locations."/".proxyPass = "http://${cfg.web.host}:${toString cfg.web.port}";
      };
    };
  };
}
