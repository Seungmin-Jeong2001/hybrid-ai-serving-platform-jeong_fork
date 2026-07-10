#!/usr/bin/env python3
"""Create or update Cloudflare DNS records for the private-cloud entrypoints."""

from __future__ import annotations

import argparse
import ipaddress
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


API_BASE = "https://api.cloudflare.com/client/v4"
DEFAULT_RECORDS = ("openstack", "k8s", "grafana", "argocd", "gitlab", "harbor", "minio", "minio-console")
DEFAULT_SSH_ALIASES = ("control-ssh", "build-ssh", "gpu-ssh", "gitlab-ssh", "harbor-ssh")


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise SystemExit(f"missing env: {name}")
    return value


def first_env(*names: str, default: str | None = None) -> str:
    for name in names:
        value = os.environ.get(name, "").strip()
        if value:
            return value
    if default is not None:
        return default
    raise SystemExit(f"missing env: {' or '.join(names)}")


def env_bool(name: str, default: bool = False) -> bool:
    value = os.environ.get(name, "").strip().lower()
    if not value:
        return default
    if value in {"true", "1", "yes", "on"}:
        return True
    if value in {"false", "0", "no", "off"}:
        return False
    raise SystemExit(f"{name} must be true or false; got: {value}")


def api_request(method: str, path: str, token: str, payload: dict | None = None) -> dict:
    body = None
    headers = {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
    }

    if payload is not None:
        body = json.dumps(payload, separators=(",", ":")).encode("utf-8")

    request = urllib.request.Request(
        f"{API_BASE}{path}",
        data=body,
        headers=headers,
        method=method,
    )

    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            data = json.load(response)
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", errors="replace")
        raise SystemExit(f"cloudflare api error {exc.code}: {detail}") from exc
    except urllib.error.URLError as exc:
        raise SystemExit(f"cloudflare api request failed: {exc}") from exc

    if not data.get("success"):
        raise SystemExit(f"cloudflare api returned failure: {json.dumps(data, ensure_ascii=False)}")

    return data


def list_records(zone_id: str, token: str, name: str) -> list[dict]:
    query = urllib.parse.urlencode({"name": name, "per_page": 100})
    data = api_request("GET", f"/zones/{zone_id}/dns_records?{query}", token)
    return list(data.get("result", []))


def record_payload(record_type: str, name: str, content: str, ttl: int) -> dict:
    return {
        "type": record_type,
        "name": name,
        "content": content,
        "ttl": ttl,
        "proxied": False,
    }


def upsert_record(zone_id: str, token: str, payload: dict, apply: bool) -> None:
    existing = list_records(zone_id, token, payload["name"])
    same_type = [record for record in existing if record.get("type") == payload["type"]]
    different_type = [record for record in existing if record.get("type") != payload["type"]]

    if different_type and not same_type:
        types = ", ".join(sorted({record.get("type", "unknown") for record in different_type}))
        raise SystemExit(f"{payload['name']} already exists with different record type(s): {types}")

    action = "update" if same_type else "create"
    print(f"{action}: {payload['type']} {payload['name']} -> {payload['content']} proxied=false ttl={payload['ttl']}")

    if not apply:
        return

    if same_type:
        record_id = same_type[0]["id"]
        api_request("PATCH", f"/zones/{zone_id}/dns_records/{record_id}", token, payload)
    else:
        api_request("POST", f"/zones/{zone_id}/dns_records", token, payload)


def delete_record(zone_id: str, token: str, payload: dict, apply: bool) -> None:
    existing = list_records(zone_id, token, payload["name"])
    same_type = [record for record in existing if record.get("type") == payload["type"]]

    if not same_type:
        print(f"skip: {payload['type']} {payload['name']} not found")
        return

    for record in same_type:
        print(f"delete: {payload['type']} {payload['name']} -> {record.get('content', '')}")
        if apply:
            api_request("DELETE", f"/zones/{zone_id}/dns_records/{record['id']}", token)


def desired_records(
    base_domain: str,
    tailscale_ip: str,
    ttl: int,
    services: tuple[str, ...],
    ssh_aliases: tuple[str, ...],
    internal_records: tuple[dict, ...] = (),
) -> list[dict]:
    ipaddress.ip_address(tailscale_ip)
    base = base_domain.rstrip(".")
    ssh_name = f"ssh.{base}"

    records = [record_payload("A", ssh_name, tailscale_ip, ttl)]
    for service in services:
        if service != "ssh":
            records.append(record_payload("CNAME", f"{service}.{base}", ssh_name, ttl))
    for alias in ssh_aliases:
        if alias != "ssh":
            records.append(record_payload("CNAME", f"{alias}.{base}", ssh_name, ttl))
    records.extend(internal_records)

    deduplicated = []
    seen = set()
    for record in records:
        key = (record["type"], record["name"])
        if key in seen:
            continue
        seen.add(key)
        deduplicated.append(record)
    return deduplicated


def parse_services(raw_services: str) -> tuple[str, ...]:
    services = []
    for service in raw_services.split(","):
        service = service.strip()
        if not service:
            continue
        if service == "git":
            service = "gitlab"
        services.append(service)
    if "gitlab" not in services:
        services.append("gitlab")
    return tuple(dict.fromkeys(services))


def parse_ssh_aliases(raw_aliases: str) -> tuple[str, ...]:
    aliases = []
    if raw_aliases.strip().lower() in {"", "none", "false", "disabled", "off"}:
        return ()
    for alias in raw_aliases.split(","):
        alias = alias.strip()
        if not alias:
            continue
        aliases.append(alias)
    return tuple(dict.fromkeys(aliases))


def parse_internal_records(raw_records: str, zone: str, ttl: int) -> tuple[dict, ...]:
    records = []
    seen = set()
    base = zone.rstrip(".")
    for item in raw_records.replace(";", ",").split(","):
        item = item.strip()
        if not item:
            continue
        if "=" not in item:
            raise SystemExit(f"internal DNS record must use name=ip format: {item}")
        name, ip = item.split("=", 1)
        name = name.strip().rstrip(".")
        ip = ip.strip()
        if not name or not ip:
            raise SystemExit(f"internal DNS record must use name=ip format: {item}")
        ipaddress.ip_address(ip)
        fqdn = name if name.endswith(f".{base}") or "." in name else f"{name}.{base}"
        key = ("A", fqdn)
        if key in seen:
            continue
        seen.add(key)
        records.append(record_payload("A", fqdn, ip, ttl))
    return tuple(records)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="apply changes to Cloudflare")
    parser.add_argument("--delete", action="store_true", help="delete desired records instead of upserting them")
    parser.add_argument(
        "--services",
        default=first_env(
            "PRIVATE_CLOUD_DNS_SERVICES",
            "HA_DNS_SERVICES",
            default=",".join(DEFAULT_RECORDS),
        ),
        help="comma-separated subdomains that should CNAME to ssh.<base-domain>",
    )
    parser.add_argument(
        "--ssh-aliases",
        default=first_env(
            "PRIVATE_CLOUD_DNS_SSH_ALIASES",
            "HA_DNS_SSH_ALIASES",
            default=",".join(DEFAULT_SSH_ALIASES),
        ),
        help="comma-separated SSH subdomains that should CNAME to ssh.<base-domain>",
    )
    args = parser.parse_args()

    token = require_env("CLOUDFLARE_API_TOKEN")
    zone_id = require_env("CLOUDFLARE_ZONE_ID")
    base_domain = first_env("PRIVATE_CLOUD_BASE_DOMAIN", "HA_BASE_DOMAIN", default="intp.me")
    tailscale_ip = first_env("PRIVATE_CLOUD_TAILSCALE_IP", "HA_TAILSCALE_IP")
    ttl = int(first_env("PRIVATE_CLOUD_DNS_TTL", "HA_CLOUDFLARE_DNS_TTL", default="120"))
    services = parse_services(args.services)
    ssh_aliases = parse_ssh_aliases(args.ssh_aliases)
    internal_enabled = env_bool("PRIVATE_CLOUD_INTERNAL_DNS_ENABLED", default=False)
    internal_zone = first_env(
        "PRIVATE_CLOUD_INTERNAL_DNS_ZONE",
        "HA_INTERNAL_DNS_ZONE",
        default=f"internal.{base_domain}",
    )
    internal_records = ()
    if internal_enabled:
        internal_records = parse_internal_records(
            os.environ.get("PRIVATE_CLOUD_INTERNAL_DNS_RECORDS", ""),
            internal_zone,
            ttl,
        )

    operation = "delete" if args.delete else "upsert"
    mode = "apply" if args.apply else "dry-run"
    print(f"mode: {mode}")
    print(f"operation: {operation}")
    print(f"zone: {zone_id}")
    print(f"base domain: {base_domain}")
    if internal_enabled:
        print(f"internal DNS zone: {internal_zone}")

    for payload in desired_records(base_domain, tailscale_ip, ttl, services, ssh_aliases, internal_records):
        if args.delete:
            delete_record(zone_id, token, payload, args.apply)
        else:
            upsert_record(zone_id, token, payload, args.apply)

    return 0


if __name__ == "__main__":
    sys.exit(main())
