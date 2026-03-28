{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.services.authentik;
  generatedSecretsDir = "${cfg.stateDir}/secrets";
  managedBlueprintsDir = "${cfg.stateDir}/blueprints";
  usesManagedSecretKey = cfg.secretKeyFile == null;
  usesManagedBootstrapPassword = cfg.bootstrap.enable && cfg.bootstrap.passwordFile == null;
  needsNetworkOnline = !(cfg.database.createLocally && cfg.redis.createLocally);
  managedBlueprintFiles = lib.mapAttrsToList (
    name: value:
    pkgs.writeText name (
      if builtins.isPath value then builtins.readFile value else value
    )
  ) cfg.blueprints.files;
  storedBlueprintsDir = pkgs.linkFarm "authentik-extra-blueprints" (
    map (file: {
      name = builtins.baseNameOf file;
      path = file;
    }) managedBlueprintFiles
  );
  effectiveSecretKeyFile =
    if cfg.secretKeyFile != null then cfg.secretKeyFile else "${generatedSecretsDir}/secret-key";
  effectiveBootstrapPasswordFile =
    if cfg.bootstrap.passwordFile != null then cfg.bootstrap.passwordFile else "${generatedSecretsDir}/bootstrap-password";

  boolString = value: if value then "true" else "false";

  renderValue =
    value:
    if builtins.isBool value then
      boolString value
    else
      toString value;

  packagedBlueprintsDir = pkgs.runCommand "authentik-packaged-blueprints-dir" {
    nativeBuildInputs = [ pkgs.gnused ];
  } ''
    set -eu

    env_path="$(${pkgs.gnused}/bin/sed -n 's@.*\(/nix/store/[^[:space:]]*-python[^[:space:]]*-env\)/bin.*@\1@p' ${cfg.package}/bin/ak | head -n 1)"
    if [ -z "$env_path" ]; then
      echo "Failed to determine Authentik Python environment from ${cfg.package}/bin/ak" >&2
      exit 1
    fi

    default_yml="$(${pkgs.findutils}/bin/find "$env_path/lib" -path '*/authentik/lib/default.yml' | head -n 1)"
    if [ -z "$default_yml" ]; then
      echo "Failed to locate authentik/lib/default.yml under $env_path" >&2
      exit 1
    fi

    blueprint_dir="$(${pkgs.gnused}/bin/sed -n 's@^blueprints_dir: @@p' "$default_yml" | head -n 1)"
    if [ -z "$blueprint_dir" ]; then
      echo "Failed to determine packaged blueprints_dir from $default_yml" >&2
      exit 1
    fi

    printf '%s' "$blueprint_dir" > "$out"
  '';

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

  mkAkScript =
    command:
    pkgs.writeShellScript "authentik-${lib.replaceStrings [ " " ] [ "-" ] command}" ''
      set -eu
      export TMPDIR=/dev/shm
      export PYTHONDONTWRITEBYTECODE=1
      export PYTHONUNBUFFERED=1
      ${renderExports baseEnvironment}
      export AUTHENTIK_SECRET_KEY="$(<${effectiveSecretKeyFile})"
      ${lib.optionalString (cfg.database.passwordFile != null) ''
        export AUTHENTIK_POSTGRESQL__PASSWORD="$(<${cfg.database.passwordFile})"
      ''}
      ${lib.optionalString cfg.bootstrap.enable ''
        export AUTHENTIK_BOOTSTRAP_PASSWORD="$(<${effectiveBootstrapPasswordFile})"
      ''}
      ${lib.optionalString (cfg.bootstrapEmail != null) ''
        export AUTHENTIK_BOOTSTRAP_EMAIL=${lib.escapeShellArg cfg.bootstrapEmail}
      ''}
      exec ${cfg.package}/bin/ak ${command}
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
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to a file containing the Authentik secret key.

        Leave this as `null` to let the module generate and persist a local
        secret in `${generatedSecretsDir}` on first boot.
      '';
    };

    bootstrapEmail = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "admin@example.com";
      description = "Optional bootstrap admin email address.";
    };

    bootstrap = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Whether to provide bootstrap admin credentials on first startup.";
      };

      passwordFile = lib.mkOption {
        type = lib.types.nullOr lib.types.path;
        default = null;
        description = ''
          Optional file containing the bootstrap admin password.

          Leave this as `null` to let the module generate and persist a local
          bootstrap password in `${generatedSecretsDir}` on first boot.
        '';
      };
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

    blueprints = {
      files = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.oneOf [
            lib.types.lines
            lib.types.path
          ]
        );
        default = { };
        example = {
          "paperless.yaml" = ''
            version: 1
            metadata:
              name: Paperless
            entries: []
          '';
        };
        description = ''
          Additional Authentik blueprint YAML files to merge into the managed
          blueprint directory.
        '';
      };

      extraDirs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "/var/lib/authentik/blueprints-local" ];
        description = ''
          Additional directories whose `.yaml` blueprint files should be merged
          into the managed blueprint directory before Authentik starts.

          This can be used for runtime-rendered blueprints that include secrets.
        '';
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
      {
        assertion = cfg.bootstrap.enable || cfg.bootstrap.passwordFile == null;
        message = "services.authentik.bootstrap.passwordFile is only valid when bootstrap is enabled.";
      }
    ];

    users.users.${cfg.user} = {
      isSystemUser = true;
      group = cfg.group;
      home = cfg.stateDir;
      createHome = true;
    };

    users.groups.${cfg.group} = { };

    environment.etc."authentik/config.yml".text = ''
      blueprints_dir: ${managedBlueprintsDir}
    '';

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
      "d ${generatedSecretsDir} 0750 ${cfg.user} ${cfg.group} -"
    ];

    systemd.services.authentik-prepare-secrets = {
      description = "Prepare persistent Authentik secrets";
      before = [
        "authentik-server.service"
      ] ++ lib.optionals cfg.worker.enable [
        "authentik-worker.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = cfg.user;
        Group = cfg.group;
        ExecStart = pkgs.writeShellScript "authentik-prepare-secrets" ''
          set -eu

          install -d -m 0750 ${lib.escapeShellArg generatedSecretsDir}

          ${lib.optionalString usesManagedSecretKey ''
            if [ ! -s ${lib.escapeShellArg effectiveSecretKeyFile} ]; then
              umask 0077
              ${pkgs.openssl}/bin/openssl rand -hex 64 > ${lib.escapeShellArg effectiveSecretKeyFile}
            fi
          ''}

          ${lib.optionalString (!usesManagedSecretKey) ''
            if [ ! -s ${lib.escapeShellArg effectiveSecretKeyFile} ]; then
              echo "Configured services.authentik.secretKeyFile is missing or empty: ${effectiveSecretKeyFile}" >&2
              exit 1
            fi
          ''}

          ${lib.optionalString usesManagedBootstrapPassword ''
            if [ ! -s ${lib.escapeShellArg effectiveBootstrapPasswordFile} ]; then
              umask 0077
              ${pkgs.openssl}/bin/openssl rand -base64 24 > ${lib.escapeShellArg effectiveBootstrapPasswordFile}
            fi
          ''}

          ${lib.optionalString (cfg.bootstrap.enable && !usesManagedBootstrapPassword) ''
            if [ ! -s ${lib.escapeShellArg effectiveBootstrapPasswordFile} ]; then
              echo "Configured services.authentik.bootstrap.passwordFile is missing or empty: ${effectiveBootstrapPasswordFile}" >&2
              exit 1
            fi
          ''}
        '';
        ReadWritePaths = [
          cfg.stateDir
          generatedSecretsDir
        ];
      };
    };

    systemd.services.authentik-prepare-blueprints = {
      description = "Prepare Authentik blueprints directory";
      before = [
        "authentik-migrate.service"
        "authentik-server.service"
      ] ++ lib.optionals cfg.worker.enable [
        "authentik-worker.service"
      ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        ExecStart = pkgs.writeShellScript "authentik-prepare-blueprints" ''
          set -eu

          install -d -m 0755 ${lib.escapeShellArg managedBlueprintsDir}
          rm -rf ${lib.escapeShellArg managedBlueprintsDir}/*

          packaged_blueprints_dir="$(cat ${packagedBlueprintsDir})"
          cp -a --no-preserve=ownership "$packaged_blueprints_dir"/. ${lib.escapeShellArg managedBlueprintsDir}/

          ${lib.optionalString (managedBlueprintFiles != [ ]) ''
            cp -a --no-preserve=ownership ${storedBlueprintsDir}/. ${lib.escapeShellArg managedBlueprintsDir}/
          ''}

          ${lib.concatMapStringsSep "\n" (
            dir: ''
              if [ -d ${lib.escapeShellArg dir} ]; then
                cp -a --no-preserve=ownership ${lib.escapeShellArg dir}/. ${lib.escapeShellArg managedBlueprintsDir}/
              fi
            ''
          ) cfg.blueprints.extraDirs}
        '';
        ReadWritePaths = [ managedBlueprintsDir ];
      };
    };

    systemd.services.authentik-migrate = {
      description = "Auth­entik database migrations";
      before = [
        "authentik-server.service"
      ] ++ lib.optionals cfg.worker.enable [
        "authentik-worker.service"
      ];
      after =
        [ "authentik-prepare-blueprints.service" "authentik-prepare-secrets.service" ]
        ++ lib.optionals needsNetworkOnline [ "network-online.target" ]
        ++ lib.optionals (!needsNetworkOnline) [ "network.target" ]
        ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ]
        ++ lib.optionals cfg.redis.createLocally [ "redis-authentik.service" ];
      requires = [ "authentik-prepare-blueprints.service" "authentik-prepare-secrets.service" ];
      wants =
        lib.optionals needsNetworkOnline [ "network-online.target" ]
        ++
        lib.optionals cfg.database.createLocally [ "postgresql.service" ]
        ++ lib.optionals cfg.redis.createLocally [ "redis-authentik.service" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        Type = "oneshot";
        ExecStart = mkAkScript "migrate";
        Restart = "no";
        RemainAfterExit = true;
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

    systemd.services.authentik-server = {
      description = "Auth­entik server";
      wantedBy = [ "multi-user.target" ];
      after = [
        "authentik-prepare-blueprints.service"
        "authentik-prepare-secrets.service"
        "authentik-migrate.service"
      ] ++ lib.optionals needsNetworkOnline [ "network-online.target" ]
        ++ lib.optionals (!needsNetworkOnline) [ "network.target" ]
        ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ]
        ++ lib.optionals cfg.redis.createLocally [ "redis-authentik.service" ];
      requires = [
        "authentik-prepare-blueprints.service"
        "authentik-prepare-secrets.service"
        "authentik-migrate.service"
      ];
      wants = lib.optionals needsNetworkOnline [ "network-online.target" ]
        ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ]
        ++ lib.optionals cfg.redis.createLocally [ "redis-authentik.service" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = mkAkScript "server";
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
      after = [
        "authentik-prepare-blueprints.service"
        "authentik-prepare-secrets.service"
        "authentik-migrate.service"
        "authentik-server.service"
      ];
      requires = [
        "authentik-prepare-blueprints.service"
        "authentik-prepare-secrets.service"
        "authentik-migrate.service"
      ];
      wants = [ "authentik-server.service" ];
      serviceConfig = {
        User = cfg.user;
        Group = cfg.group;
        WorkingDirectory = cfg.stateDir;
        ExecStart = mkAkScript "worker";
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
