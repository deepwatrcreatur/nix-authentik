# nix-authentik

`nix-authentik` provides a reusable NixOS module for running [Authentik](https://goauthentik.io/) natively from the packages already available in `nixpkgs`.

This flake does not try to replace `nixpkgs` packaging. Instead, it fills the operational gap:
- systemd services for `ak server` and `ak worker`
- optional local PostgreSQL provisioning
- optional local Redis provisioning
- filesystem layout for persistent state and media
- runtime secret handling for the Authentik secret key and bootstrap password

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
    bootstrapPasswordFile = /run/secrets/authentik-bootstrap-password;
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
Required file path containing the Authentik secret key.

### `services.authentik.bootstrapPasswordFile`
Optional file path containing the bootstrap admin password.

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

## Development Direction

Likely next steps:
- declarative reverse-proxy helpers
- first-class outpost support
- optional declarative bootstrap helpers
- integration examples for Paperless, Grafana, and Caddy forward auth
