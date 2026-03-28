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
  renderedBlueprintsDir = "${cfg.stateDir}/blueprints-rendered";
  defaultOauthScopeMappings = [
    "goauthentik.io/providers/oauth2/scope-openid"
    "goauthentik.io/providers/oauth2/scope-email"
    "goauthentik.io/providers/oauth2/scope-profile"
    "goauthentik.io/providers/oauth2/scope-offline_access"
  ];
  usesManagedSecretKey = cfg.secretKeyFile == null;
  usesManagedBootstrapPassword = cfg.bootstrap.enable && cfg.bootstrap.passwordFile == null;
  needsNetworkOnline = !(cfg.database.createLocally && cfg.redis.createLocally);
  storedBlueprintsDir = pkgs.linkFarm "authentik-extra-blueprints" (
    lib.mapAttrsToList (
      name: value: {
        inherit name;
        path = pkgs.writeText name (
          if builtins.isPath value then builtins.readFile value else value
        );
      }
    ) cfg.blueprints.files
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

    env_paths="$(${pkgs.gnugrep}/bin/grep -oE '/nix/store/[^[:space:]]*-python[^[:space:]]*-env' ${cfg.package}/bin/ak | ${pkgs.coreutils}/bin/sort -u || true)"
    if [ "$(${pkgs.coreutils}/bin/printf '%s\n' "$env_paths" | ${pkgs.gnugrep}/bin/grep -c . || true)" -ne 1 ]; then
      echo "Expected exactly one Authentik Python environment in ${cfg.package}/bin/ak, got:" >&2
      ${pkgs.coreutils}/bin/printf '%s\n' "$env_paths" >&2
      exit 1
    fi
    env_path="$(${pkgs.coreutils}/bin/printf '%s\n' "$env_paths")"

    blueprint_dir="$env_path/blueprints"
    if [ ! -d "$blueprint_dir" ]; then
      echo "Packaged blueprints directory does not exist under Authentik Python environment: $blueprint_dir" >&2
      exit 1
    fi

    printf '%s' "$blueprint_dir" > "$out"
  '';

  renderExports =
    attrs:
    lib.concatStringsSep "\n" (
      lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg (renderValue value)}") attrs
    );

  mkRenderedOidcApplicationScript =
    name:
    oidcCfg:
    let
      oidcSpec = builtins.toJSON {
        slug = oidcCfg.slug;
        displayName = oidcCfg.displayName;
        launchUrl = oidcCfg.launchUrl;
        clientId = oidcCfg.clientId;
        clientIdFile = if oidcCfg.clientIdFile == null then null else toString oidcCfg.clientIdFile;
        clientSecretFile = toString oidcCfg.clientSecretFile;
        redirectUris = oidcCfg.redirectUris;
        authorizationFlowSlug = oidcCfg.authorizationFlowSlug;
        invalidationFlowSlug = oidcCfg.invalidationFlowSlug;
        propertyMappings = oidcCfg.propertyMappings;
        signingKeyName = oidcCfg.signingKeyName;
      };
    in
    ''
      export AUTHENTIK_OIDC_BLUEPRINT_SPEC=${lib.escapeShellArg oidcSpec}
      ${pkgs.python3}/bin/python - <<'PY'
import json
import os
from pathlib import Path

spec = json.loads(os.environ["AUTHENTIK_OIDC_BLUEPRINT_SPEC"])
target = Path(os.environ["AUTHENTIK_BLUEPRINT_OUTPUT"])
client_id = spec.get("clientId")
client_id_file = spec.get("clientIdFile")
client_secret = Path(spec["clientSecretFile"]).read_text().strip()

if client_id_file:
    client_id = Path(client_id_file).read_text().strip()

if not client_id:
    raise SystemExit("OIDC client ID is empty")

if not client_secret:
    raise SystemExit(f"OIDC client secret file is empty: {spec['clientSecretFile']}")

property_mappings = "\n".join(
    f"        - !Find [authentik_providers_oauth2.scopemapping, [managed, {mapping}]]"
    for mapping in spec["propertyMappings"]
)
redirect_uris = "\n".join(
    f"        - matching_mode: strict\n          url: {uri}"
    for uri in spec["redirectUris"]
)
launch_url = spec["launchUrl"] or ""
meta_launch_url = (
    f"      meta_launch_url: {launch_url}\n"
    if launch_url
    else ""
)

target.write_text(
    "version: 1\n"
    f"metadata:\n  name: {spec['displayName']}\n"
    "entries:\n"
    "  - model: authentik_providers_oauth2.oauth2provider\n"
    f"    id: {spec['slug']}_provider\n"
    "    identifiers:\n"
    f"      name: {spec['slug']}\n"
    "    attrs:\n"
    f"      authorization_flow: !Find [authentik_flows.flow, [slug, {spec['authorizationFlowSlug']}]]\n"
    f"      invalidation_flow: !Find [authentik_flows.flow, [slug, {spec['invalidationFlowSlug']}]]\n"
    "      client_type: confidential\n"
    f"      client_id: {client_id}\n"
    f"      client_secret: {client_secret}\n"
    "      redirect_uris:\n"
    f"{redirect_uris}\n"
    "      property_mappings:\n"
    f"{property_mappings}\n"
    f"      signing_key: !Find [authentik_crypto.certificatekeypair, [name, {spec['signingKeyName']}]]\n"
    "  - model: authentik_core.application\n"
    "    identifiers:\n"
    f"      slug: {spec['slug']}\n"
    "    attrs:\n"
    f"      provider: !KeyOf {spec['slug']}_provider\n"
    f"      name: {spec['displayName']}\n"
    f"{meta_launch_url}"
)
PY
    '';

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

    applications.oidc = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              slug = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Authentik application and provider slug.";
              };

              displayName = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Human-readable Authentik application name.";
              };

              launchUrl = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Optional application launch URL shown in the Authentik UI.";
              };

              clientId = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "Static OIDC client ID exposed by the application.";
              };

              clientIdFile = lib.mkOption {
                type = lib.types.nullOr lib.types.path;
                default = null;
                description = "Optional file containing the OIDC client ID at runtime.";
              };

              clientSecretFile = lib.mkOption {
                type = lib.types.path;
                description = "Path to a file containing the OIDC client secret.";
              };

              redirectUris = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                description = "Allowed OIDC redirect URIs for this application.";
              };

              authorizationFlowSlug = lib.mkOption {
                type = lib.types.str;
                default = "default-provider-authorization-implicit-consent";
                description = "Authentik authorization flow slug to attach to this provider.";
              };

              invalidationFlowSlug = lib.mkOption {
                type = lib.types.str;
                default = "default-provider-invalidation-flow";
                description = "Authentik invalidation flow slug to attach to this provider.";
              };

              propertyMappings = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = defaultOauthScopeMappings;
                description = "Managed OAuth2 scope mappings to attach to this provider.";
              };

              signingKeyName = lib.mkOption {
                type = lib.types.str;
                default = "authentik Self-signed Certificate";
                description = "Authentik certificate keypair name used to sign tokens.";
              };

              fileName = lib.mkOption {
                type = lib.types.str;
                default = "${name}.yaml";
                description = "Filename to generate for this OIDC application blueprint.";
              };
            };
          }
        )
      );
      default = { };
      example = {
        paperless = {
          slug = "paperless-ngx";
          displayName = "Paperless NGX";
          launchUrl = "https://paperless.example.com/";
          clientId = "paperless-ngx";
          clientSecretFile = /run/secrets/paperless-oidc-client-secret;
          redirectUris = [
            "https://paperless.example.com/accounts/oidc/authentik/login/callback/"
          ];
        };
      };
      description = ''
        Declarative OIDC applications/providers to render into Authentik
        blueprints at runtime.
      '';
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

      rendered = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule (
            { name, ... }:
            {
              options = {
                fileName = lib.mkOption {
                  type = lib.types.str;
                  default = "${name}.yaml";
                  description = "Filename to write under the rendered blueprints directory.";
                };

                script = lib.mkOption {
                  type = lib.types.lines;
                  description = ''
                    Shell script fragment that writes the rendered blueprint to
                    `$AUTHENTIK_BLUEPRINT_OUTPUT`.
                  '';
                };
              };
            }
          )
        );
        default = { };
        example = {
          paperless = {
            fileName = "paperless-ngx.yaml";
            script = ''
              cat > "$AUTHENTIK_BLUEPRINT_OUTPUT" <<'EOF'
              version: 1
              metadata:
                name: Paperless NGX
              entries: []
              EOF
            '';
          };
        };
        description = ''
          Runtime-rendered blueprint files that should be generated before
          Authentik prepares its managed blueprint directory.

          Prefer `services.authentik.applications.oidc` for standard OAuth/OIDC
          application/provider pairs and use this lower-level escape hatch for
          custom blueprint generation.
        '';
      };
    };
  };

  config =
    let
      hasRenderedBlueprints = cfg.blueprints.rendered != { } || cfg.applications.oidc != { };
      effectiveBlueprintExtraDirs =
        lib.optionals hasRenderedBlueprints [ renderedBlueprintsDir ] ++ cfg.blueprints.extraDirs;
      renderBlueprintsScript = pkgs.writeShellScript "authentik-render-blueprints" ''
        set -euo pipefail
        umask 0077

        install -d -m 0750 ${lib.escapeShellArg renderedBlueprintsDir}
        ${pkgs.findutils}/bin/find ${lib.escapeShellArg renderedBlueprintsDir} -mindepth 1 -delete

        ${lib.concatMapStringsSep "\n" (
          name:
          let
            renderedCfg = cfg.blueprints.rendered.${name};
          in
          ''
            (
              export AUTHENTIK_BLUEPRINT_OUTPUT=${lib.escapeShellArg "${renderedBlueprintsDir}/${renderedCfg.fileName}"}
              ${renderedCfg.script}
            )
          ''
        ) (builtins.attrNames cfg.blueprints.rendered)}

        ${lib.concatMapStringsSep "\n" (
          name:
          let
            oidcCfg = cfg.applications.oidc.${name};
          in
          ''
            (
              export AUTHENTIK_BLUEPRINT_OUTPUT=${lib.escapeShellArg "${renderedBlueprintsDir}/${oidcCfg.fileName}"}
              ${mkRenderedOidcApplicationScript name oidcCfg}
            )
          ''
        ) (builtins.attrNames cfg.applications.oidc)}
      '';
    in
    lib.mkIf cfg.enable {
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
      {
        assertion =
          lib.all (
            oidcCfg: (oidcCfg.clientId != null) != (oidcCfg.clientIdFile != null)
          ) (builtins.attrValues cfg.applications.oidc);
        message = ''
          Each services.authentik.applications.oidc entry must set exactly one of
          clientId or clientIdFile.
        '';
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
      "d ${managedBlueprintsDir} 0750 ${cfg.user} ${cfg.group} -"
    ] ++ lib.optionals hasRenderedBlueprints [
      "d ${renderedBlueprintsDir} 0750 root root -"
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
      after = lib.optionals hasRenderedBlueprints [ "authentik-render-blueprints.service" ];
      requires = lib.optionals hasRenderedBlueprints [ "authentik-render-blueprints.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        ExecStart = pkgs.writeShellScript "authentik-prepare-blueprints" ''
          set -eu

          if [ -L ${lib.escapeShellArg managedBlueprintsDir} ]; then
            echo "Refusing to operate on symlinked blueprint directory: ${managedBlueprintsDir}" >&2
            exit 1
          fi

          if [ -e ${lib.escapeShellArg managedBlueprintsDir} ] && [ ! -d ${lib.escapeShellArg managedBlueprintsDir} ]; then
            echo "Blueprint path exists but is not a directory: ${managedBlueprintsDir}" >&2
            exit 1
          fi

          install -d -m 0750 ${lib.escapeShellArg managedBlueprintsDir}
          ${pkgs.findutils}/bin/find ${lib.escapeShellArg managedBlueprintsDir} -mindepth 1 -delete

          packaged_blueprints_dir="$(cat ${packagedBlueprintsDir})"
          cp -a --no-preserve=ownership "$packaged_blueprints_dir"/. ${lib.escapeShellArg managedBlueprintsDir}/

          ${lib.optionalString (cfg.blueprints.files != { }) ''
            cp -a --no-preserve=ownership ${storedBlueprintsDir}/. ${lib.escapeShellArg managedBlueprintsDir}/
          ''}

          ${lib.concatMapStringsSep "\n" (
            dir: ''
              if [ -d ${lib.escapeShellArg dir} ]; then
                cp -a --no-preserve=ownership ${lib.escapeShellArg dir}/. ${lib.escapeShellArg managedBlueprintsDir}/
              else
                echo "Warning: configured blueprint directory is missing: ${dir}" >&2
              fi
            ''
          ) effectiveBlueprintExtraDirs}

          chown -R ${lib.escapeShellArg cfg.user}:${lib.escapeShellArg cfg.group} ${lib.escapeShellArg managedBlueprintsDir}
          chmod -R u=rwX,g=rX,o= ${lib.escapeShellArg managedBlueprintsDir}
        '';
        ReadWritePaths = [ cfg.stateDir ];
      };
    };

    systemd.services.authentik-render-blueprints = lib.mkIf hasRenderedBlueprints {
      description = "Render Authentik runtime blueprints";
      before = [ "authentik-prepare-blueprints.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "root";
        Group = "root";
        ExecStart = renderBlueprintsScript;
        ReadWritePaths = [ cfg.stateDir ];
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
