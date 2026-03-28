{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.authentik;

  boolString = value: if value then "true" else "false";

  renderValue =
    value:
    if builtins.isBool value then
      boolString value
    else
      toString value;

  renderExports =
    attrs:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg (renderValue value)}") attrs
    );

  baseEnvironment =
    {
      AUTHENTIK_ERROR_REPORTING__ENABLED = false;
      AUTHENTIK_POSTGRESQL__HOST =
        if cfg.database.createLocally then "/run/postgresql" else cfg.database.host;
      AUTHENTIK_POSTGRESQL__NAME = cfg.database.name;
      AUTHENTIK_POSTGRESQL__USER = cfg.database.user;
      AUTHENTIK_REDIS__HOST =
        if cfg.redis.createLocally then "127.0.0.1" else cfg.redis.host;
      AUTHENTIK_REDIS__PORT =
        if cfg.redis.createLocally then config.services.redis.servers.authentik.port else cfg.redis.port;
    }
    // lib.optionalAttrs (cfg.domain != null) {
      AUTHENTIK_HOST = "https://${cfg.domain}";
    }
    // cfg.settings;

  mkServiceScript =
    role:
    pkgs.writeShellScript "authentik-${role}" ''
      set -eu
      export TMPDIR=/dev/shm
      export PYTHONDONTWRITEBYTECODE=1
      export PYTHONUNBUFFERED=1
      ${renderExports baseEnvironment}
      export AUTHENTIK_SECRET_KEY="$(<${cfg.secretKeyFile})"
      ${lib.optionalString (cfg.database.passwordFile != null) ''
        export AUTHENTIK_POSTGRESQL__PASSWORD="$(<${cfg.database.passwordFile})"
      ''}
      ${lib.optionalString (cfg.bootstrapPasswordFile != null) ''
        export AUTHENTIK_BOOTSTRAP_PASSWORD="$(<${cfg.bootstrapPasswordFile})"
      ''}
      ${lib.optionalString (cfg.bootstrapEmail != null) ''
        export AUTHENTIK_BOOTSTRAP_EMAIL=${lib.escapeShellArg cfg.bootstrapEmail}
      ''}
      exec ${cfg.package}/bin/ak ${role}
    '';

  localRedisPortDefault = 6379;
in
{
  options.services.authentik = {
    enable = lib.mkEnableOption "Auth­entik identity provider";

    package = lib.mkPackageOption pkgs "authentik" { };

    user = lib.mkOption {
      type = lib.types.str;
      default = "authentik";
      description = "User account under which Authentik runs.";
    };

    group = lib.mkOption {
      type = lib.types.str;
      default = "authentik";
      description = "Group account under which Authentik runs.";
    };

    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/authentik";
      description = "Base directory for Authentik state.";
    };

    mediaDir = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.stateDir}/media";
      description = "Directory for Authentik media uploads.";
    };

    domain = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "auth.example.com";
      description = "Public Authentik domain used for AUTHENTIK_HOST.";
    };

    secretKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to a file containing the Authentik secret key.";
    };

    bootstrapPasswordFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Optional file containing the initial bootstrap admin password.";
    };

    bootstrapEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "admin@example.com";
      description = "Optional bootstrap admin email address.";
    };

    settings = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.oneOf [
          lib.types.str
          lib.types.int
          lib.types.bool
        ]
      );
      default = { };
      example = {
        AUTHENTIK_LISTEN__HTTP = "0.0.0.0:9000";
      };
      description = ''
        Extra Authentik environment variables.

        Keys should be full Authentik environment names, such as
        `AUTHENTIK_EMAIL__HOST` or `AUTHENTIK_LISTEN__HTTP`.
      '';
    };

    database = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provision PostgreSQL locally on this machine.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "PostgreSQL host when not creating PostgreSQL locally.";
      };

      name = lib.mkOption {
        type = lib.types.str;
        default = "authentik";
        description = "PostgreSQL database name.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = cfg.user;
        description = "PostgreSQL database user.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = "Optional PostgreSQL password file.";
      };
    };

    redis = {
      createLocally = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provision Redis locally on this machine.";
      };

      host = lib.mkOption {
        type = lib.types.str;
        default = "127.0.0.1";
        description = "Redis host when not creating Redis locally.";
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = localRedisPortDefault;
        description = "Redis TCP port when not creating Redis locally.";
      };
    };

    worker = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to run the Authentik worker service.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.database.createLocally || cfg.database.host != "";
        message = "services.authentik.database.host must be set when PostgreSQL is external.";
      }
      {
        assertion = cfg.redis.createLocally || cfg.redis.host != "";
        message = "services.authentik.redis.host must be set when Redis is external.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
    };

    users.groups.${cfg.group} = { };

    services.postgresql = lib.mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ cfg.database.name ];
      ensureUsers = [
        {
          name = cfg.database.user;
          ensureDBOwnership = true;
        }
      ];
    };

    services.redis.servers.authentik = lib.mkIf cfg.redis.createLocally {
      enable = true;
      user = cfg.user;
      group = cfg.group;
      bind = "127.0.0.1";
      port = localRedisPortDefault;
    };

    systemd.tmpfiles.rules = [
      "d ${cfg.stateDir} 0750 ${cfg.user} ${cfg.group} -"
      "d ${cfg.mediaDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.authentik-server = {
      description = "Auth­entik server";
      wantedBy = [ "multi-user.target" ];
      after =
        [
          "network.target"
        ]
        ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ]
        ++ lib.optionals cfg.redis.createLocally [ "redis-authentik.service" ];
      wants =
        lib.optionals cfg.database.createLocally [ "postgresql.service" ]
        ++ lib.optionals cfg.redis.createLocally [ "redis-authentik.service" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = mkServiceScript "server";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          cfg.stateDir
          cfg.mediaDir
        ];
      };
    };

    systemd.services.authentik-worker = lib.mkIf cfg.worker.enable {
      description = "Auth­entik worker";
      wantedBy = [ "multi-user.target" ];
      after = [ "authentik-server.service" ];
      wants = [ "authentik-server.service" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = mkServiceScript "worker";
        Restart = "on-failure";
        RestartSec = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          cfg.stateDir
          cfg.mediaDir
        ];
      };
    };
  };
}
