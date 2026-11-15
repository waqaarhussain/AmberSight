#!/usr/bin/env python3
"""Prepare the local VPS login and HTTPS before publishing its port."""
import argparse
import getpass
import ipaddress
import os
from pathlib import Path
import subprocess
import tempfile
import warnings

from argon2 import PasswordHasher
import tomlkit


def atomic_write(path, text, uid=1000, gid=1000):
    fd, temporary = tempfile.mkstemp(prefix=".vps-", dir=path.parent)
    try:
        os.fchmod(fd, 0o600)
        if os.geteuid() == 0:
            os.fchown(fd, uid, gid)
        with os.fdopen(fd, "w") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def read_env(path):
    return dict(line.split("=", 1) for line in path.read_text().splitlines()
                if "=" in line and not line.lstrip().startswith("#")) if path.exists() else {}


def update_env(path, **values):
    lines = path.read_text().splitlines() if path.exists() else []
    output = [line for line in lines if line.partition("=")[0] not in values]
    output.extend(f"{key}={value}" for key, value in values.items())
    atomic_write(path, "\n".join(output) + "\n", uid=0, gid=0)


def public_address(env):
    saved = env.get("AMBERSIGHT_PUBLIC_IP", "").strip()
    if saved:
        return str(ipaddress.IPv4Address(saved))
    # Prefer a public address already assigned to this VPS, without an external lookup.
    result = subprocess.run(["hostname", "-I"], capture_output=True, text=True, check=False)
    for value in result.stdout.split():
        try:
            address = ipaddress.ip_address(value)
            if address.version == 4 and address.is_global:
                return str(address)
        except ValueError:
            pass
    # Handles VPS providers that NAT the public IP to a private interface.
    result = subprocess.run(["curl", "-4fsS", "--connect-timeout", "5", "--max-time", "10",
                             "https://api.ipify.org"], capture_output=True, text=True, check=False)
    if result.returncode == 0:
        try:
            address = ipaddress.IPv4Address(result.stdout.strip())
            if address.is_global:
                return str(address)
        except ValueError:
            pass
    with open("/dev/tty", "w") as terminal, open("/dev/tty", "r") as terminal_input:
        terminal.write("VPS public IPv4 address: ")
        terminal.flush()
        address = ipaddress.IPv4Address(terminal_input.readline().strip())
    if not address.is_global:
        raise ValueError("Enter the VPS public IPv4 address.")
    return str(address)


def password_hash():
    # Refuse getpass's echoing fallback; never put the password in args, env or logs.
    with open("/dev/tty", "w") as terminal, warnings.catch_warnings():
        warnings.simplefilter("error", getpass.GetPassWarning)
        while True:
            first = getpass.getpass("Password for waqaar (at least 12 characters): ", stream=terminal)
            again = getpass.getpass("Confirm password: ", stream=terminal)
            if first != again:
                terminal.write("Passwords did not match. Try again.\n")
            elif len(first) < 12 or first != first.strip():
                terminal.write("Use at least 12 characters, without spaces at the beginning or end.\n")
            else:
                return PasswordHasher(time_cost=2, memory_cost=19456, parallelism=1).hash(first)


def prepare(config, template, env_file):
    original = config.read_text() if config.exists() else template.read_text()
    doc = tomlkit.parse(original)
    server = doc.setdefault("server", tomlkit.table())
    users = server.setdefault("users", tomlkit.aot())
    matches = [u for u in users if u.get("username", "").strip() == "waqaar"]
    if len(matches) > 1:
        raise ValueError("Duplicate waqaar accounts found. Resolve them before publishing.")
    user = matches[0] if matches else tomlkit.table()
    # Use a real existing hash on updates; never reset the chosen password automatically.
    if not str(user.get("password", "")).startswith("$argon2"):
        user["password"] = password_hash()
    user.update(username="waqaar", admin=True, disabled=False, role="")
    if not matches:
        users.append(user)
    legacy = server.get("auth", {})
    if legacy.get("username", "").strip() == "waqaar":
        del server["auth"]
    if server.get("demo_user", "").strip() == "waqaar":
        del server["demo_user"]
    address = public_address(read_env(env_file))
    server.update(bind="0.0.0.0", port=8090, tls=True)
    names = server.setdefault("tls_names", tomlkit.array())
    if address not in names:
        names.append(address)
    doc.setdefault("storage", tomlkit.table()).setdefault("data_dir", "/data")
    # The template's relative data folder is for native installs, not this container.
    if not config.exists():
        doc["storage"]["data_dir"] = "/data"
    rendered = tomlkit.dumps(doc)
    tomlkit.parse(rendered)
    if config.exists() and rendered != original:
        atomic_write(config.with_name("config.toml.before-vps"), original)
    atomic_write(config, rendered)
    update_env(env_file, AMBERSIGHT_PUBLIC_IP=address)
    print(f"Login configured: waqaar. Dashboard address: https://{address}:8090")


def publish(config, env_file):
    doc = tomlkit.parse(config.read_text())
    server = doc.get("server", {})
    user = next((u for u in server.get("users", []) if u.get("username") == "waqaar"), {})
    if not (server.get("tls") and user.get("password", "").startswith("$argon2")
            and user.get("admin") and not user.get("disabled", False)):
        raise ValueError("Refusing public access without HTTPS and the configured account.")
    update_env(env_file, AMBERSIGHT_BIND_IP="0.0.0.0")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=["prepare", "publish"])
    parser.add_argument("config", type=Path)
    parser.add_argument("env_file", type=Path)
    parser.add_argument("--template", type=Path)
    args = parser.parse_args()
    try:
        if args.action == "prepare":
            if args.template is None:
                parser.error("prepare requires --template")
            prepare(args.config, args.template, args.env_file)
        else:
            publish(args.config, args.env_file)
    except (OSError, ValueError, EOFError, KeyboardInterrupt, getpass.GetPassWarning) as error:
        raise SystemExit(f"VPS configuration stopped: {error}") from None


if __name__ == "__main__":
    main()
