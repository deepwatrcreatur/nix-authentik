# nix-authentik

`nix-authentik` provides a reusable NixOS module for running [Authentik](https://goauthentik.io/) natively from the packages already available in `nixpkgs`.

This flake does not try to replace `nixpkgs` packaging. Instead, it fills the operational gap:
- systemd services for `ak server` and `ak worker`
- a dedicated migration unit for first boot and upgrades
- optional local PostgreSQL provisioning
- optional local Redis provisioning
- filesystem layout for persistent state and media
- runtime secret handling for the Authentik secret key and bootstrap password
- optional first-boot generation of persistent local secrets when no secret files
  are supplied

## Why this exists

`nixpkgs` already ships:
- `pkgs.authentik`
- `pkgs.authentik.proxy`
- `pkgs.authentik.outposts.{proxy,ldap,radius}`

What it does not currently provide is a NixOS service module that turns those packages into a clean deployment model.

## Scope

This first version is intentionally narrow:
- native Authentik server and worker services
- external or locally managed PostgreSQL
- external or locally managed Redis
- environment-based Authentik settings

It does not yet try to make Authentik applications, providers, or outposts declarative.

It now supports managed blueprints, so applications and providers can be
declared through Authentik's native blueprint system without hand-driving the
admin UI.

## Quick Start

Add the flake as an input:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nix-authentik.url = "github:deepwatrcreatur/nix-authentik";
  };
}
```

Then import the module:

```nix
{
  imports = [
    nix-authentik.nixosModules.default
  ];

  services.authentik = {
    enable = true;
    domain = "auth.example.com";
    secretKeyFile = /run/secrets/authentik-secret-key;
    bootstrap.passwordFile = /run/secrets/authentik-bootstrap-password;
    blueprints.files."example-app.yaml" = ''
      version: 1
      metadata:
        name: Example app
      entries: []
    '';
  };
}
```

## Example

The flake includes a minimal example NixOS configuration:

```bash
nix build .#nixosConfigurations.authentik-example.config.system.build.toplevel
```

## Main Options

### `services.authentik.enable`
Enable the Authentik module.

### `services.authentik.secretKeyFile`
Optional file path containing the Authentik secret key.

If omitted, the module generates and persists a local secret key in
`/var/lib/authentik/secrets/secret-key` on first boot.

### `services.authentik.bootstrap.passwordFile`
Optional file path containing the bootstrap admin password.

If omitted, the module can generate and persist a local bootstrap password on
first boot.

### `services.authentik.domain`
Optional public domain used to set `AUTHENTIK_HOST`.

### `services.authentik.settings`
Extra Authentik environment variables, keyed by the full environment name:

```nix
services.authentik.settings = {
  AUTHENTIK_LISTEN__HTTP = "0.0.0.0:9000";
};
```

### `services.authentik.database.createLocally`
When enabled, the module provisions PostgreSQL locally and configures Authentik to use `/run/postgresql`.

### `services.authentik.redis.createLocally`
When enabled, the module provisions a local Redis instance and configures Authentik to use it over loopback TCP.

### `services.authentik.blueprints.files`
Additional Authentik blueprint YAML files to merge into the managed blueprint
directory.

### `services.authentik.blueprints.extraDirs`
Additional directories whose `.yaml` files should be merged into the managed
blueprint directory before Authentik starts. This is useful when a blueprint
needs to be rendered at runtime from secrets.

## First-Boot Secrets

For quick starts and dedicated hosts, the module can manage its own persistent
local secrets:

- `secretKeyFile = null` generates `/var/lib/authentik/secrets/secret-key`
- `bootstrap.passwordFile = null` generates `/var/lib/authentik/secrets/bootstrap-password`

These files are created once with restrictive permissions and then reused across
restarts and rebuilds.

## Boot Flow

The module now models the initial startup sequence explicitly:

1. `authentik-prepare-secrets.service` ensures persistent local secrets exist.
2. `authentik-migrate.service` runs `ak migrate`.
3. `authentik-server.service` starts only after migrations complete.
4. `authentik-worker.service` starts after both migration and server startup.

That avoids the first-boot race where server or worker come up against a
half-migrated database.

## Managed Blueprints

`nix-authentik` now manages a merged blueprint directory under
`/var/lib/authentik/blueprints` and points Authentik at it via
`/etc/authentik/config.yml`.

That managed directory contains:
- Authentik's packaged default blueprints
- any `services.authentik.blueprints.files`
- any directories listed in `services.authentik.blueprints.extraDirs`

This keeps the native Authentik defaults intact while allowing additional
declarative application/provider blueprints.

## Development Direction

Likely next steps:
- declarative reverse-proxy helpers
- first-class outpost support
- optional declarative bootstrap helpers
- integration examples for Paperless, Grafana, and Caddy forward auth
