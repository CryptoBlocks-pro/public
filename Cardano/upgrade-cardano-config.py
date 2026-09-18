#!/usr/bin/env python3
"""Plan, but never install, a Praos configuration migration (stdlib only).

Run with --help for the CLI. All three output artifacts are always emitted on
success. config_before_sha256 hashes LIVE config; staged_config_sha256 hashes
--config. Unchanged staged config and selected topology retain their exact bytes.

Policy/defaults: missing advertise/trustable are false; publicRoots defaults to
[]; ledger discovery defaults to -1. Local groups require valency or hotValency;
warmValency defaults to the hot target. Targets are nonnegative signed-64-bit
integers, hot <= warm, including aggregate totals. They are NOT capped by the
number of DNS access points (one domain may resolve to multiple peers). A usable
local group has access points and a positive hot target.

Automatic recovery protects entire localRoots/Producers arrays, including order,
flags and custom metadata, not just addresses. Backup identity/coalescing is
byte-based. An undated candidate cannot outrank a differing dated candidate.
The paired Shelley genesis is the sibling basename referenced by backup config;
its Cardano genesis hash is BLAKE2b-256, not the SHA-256 dependency checksum.

Snapshot status: not-referenced, ignored-ledger-disabled, or validated-structural.
The modern NodeToClientVersion sanity range is 16..32767, NOT a target-version
decoder compatibility table. --target-version is validated and recorded, not
used to claim full Haskell decoding, network reachability, freshness, historical
deployment, or runtime compatibility. Unknown application metadata is retained.

Inputs must be regular files with no symlink path components. Output must be
separate from live files, backups and inputs. Output replacements are atomic per
file, with plan.json last, NOT a multi-file installation transaction. Callers
must check artifact/dependency hashes again before any later installation and
provide their own locking; concurrently hostile directory mutation is out of
scope. This program does not install, delete snapshots, or contact peers.
"""

import argparse
import difflib
import fnmatch
import hashlib
import ipaddress
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import tempfile
from datetime import datetime


MAX_INT = (1 << 63) - 1
P2P_KEYS = {"localRoots", "publicRoots", "bootstrapPeers", "useLedgerAfterSlot",
            "peerSnapshotFile"}
STRUCTURAL_WARNING = (
    "Structural validation only, not the full Haskell decoder: target-version "
    "protocol compatibility, snapshot freshness, peer reachability and ownership "
    "are not proven. Recheck dependency and output hashes before installation."
)


class PlanError(Exception):
    """An actionable validation or I/O failure."""


class UnsafePath(PlanError):
    """Do not turn unsafe current input paths into automatic recovery."""


def require(condition, message):
    if not condition:
        raise PlanError(message)


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def safe_path(value):
    # Check before resolve so symlinks (even link/../file) cannot be hidden.
    path = Path(value).absolute()
    for part in (path, *path.parents):
        if part.is_symlink():
            raise UnsafePath(f"Symlink path refused: {part}; supply real files/directories")
    return path.resolve()


def within(path, directory):
    return path == directory or directory in path.parents


class Inputs:
    """Cache the exact bytes used for decisions and their absolute-path hashes."""

    def __init__(self):
        self.data = {}

    def read(self, path):
        path = safe_path(path)
        if path not in self.data:
            try:
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as source:
                    require(stat.S_ISREG(os.fstat(source.fileno()).st_mode),
                            f"Input must be a regular file: {path}")
                    self.data[path] = source.read()
            except OSError as exc:
                raise PlanError(f"Cannot read {path}: {exc.strerror}") from exc
        return self.data[path]

    def document(self, path):
        return decode(self.read(path), str(path))

    def merge(self, other):
        for path, data in other.data.items():
            require(path not in self.data or self.data[path] == data,
                    f"Input changed while planning: {path}; retry with stable inputs")
            self.data[path] = data

    def hashes(self):
        return {str(path): sha256(data) for path, data in sorted(self.data.items())}


def decode(data, label):
    def pairs(items):
        result = {}
        for key, value in items:
            require(key not in result, f"Duplicate JSON key {key!r}")
            result[key] = value
        return result

    def number(text):
        value = float(text)
        require(math.isfinite(value), "Non-finite JSON number")
        return value

    def constant(text):
        raise PlanError(f"Non-standard JSON constant {text}")

    try:
        value = json.loads(data, object_pairs_hook=pairs, parse_float=number,
                           parse_constant=constant)
        require(isinstance(value, dict), "Expected a JSON object")
        return value
    except (ValueError, UnicodeError, PlanError, RecursionError) as exc:
        raise PlanError(f"Invalid JSON in {label}: {exc}") from exc


def integer(value, label, minimum=0, maximum=MAX_INT):
    require(type(value) is int and minimum <= value <= maximum,
            f"{label} must be an integer in {minimum}..{maximum} (not boolean)")
    return value


def boolean(value, label):
    require(type(value) is bool, f"{label} must be a boolean")
    return value


def array(value, label):
    require(isinstance(value, list), f"{label} must be an array")
    return value


def object_value(value, label):
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def path_reference(value, label):
    require(isinstance(value, str) and bool(value.strip()) and "\x00" not in value,
            f"{label} must be a nonempty path string")
    return Path(value)


def address(value, label, srv=False):
    require(isinstance(value, str) and bool(value) and value == value.strip(),
            f"{label} must be a nonempty IP address or DNS name")
    try:
        ipaddress.ip_address(value)
        require("%" not in value, f"{label}: scoped IP addresses are unsupported")
        return True
    except ValueError:
        pass
    name = value[:-1] if value.endswith(".") else value
    label_pattern = r"[A-Za-z0-9_](?:[A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?" if srv else (
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?")
    require(len(name) <= 253 and not re.fullmatch(r"[0-9.]+", name)
            and all(re.fullmatch(label_pattern, part) for part in name.split(".")),
            f"{label} is not a valid IP address or DNS name: {value!r}")
    return False


def access_point(value, label, snapshot=False, legacy=False):
    point = object_value(value, label)
    key = "addr" if legacy else "address"
    is_ip = address(point.get(key), f"{label}.{key}", srv=snapshot)
    if snapshot and "port" not in point:
        require(not is_ip, f"{label}: an IP relay requires a port; only DNS SRV may omit it")
    else:
        integer(point.get("port"), f"{label}.port", 1, 65535)


def config_mode(config, label):
    if "ConsensusMode" in config:
        require(config["ConsensusMode"] in ("PraosMode", "GenesisMode"),
                f"{label}.ConsensusMode is unknown; expected PraosMode, GenesisMode or missing")
    for key in ("EnableP2P", "PeerSharing"):
        if key in config:
            boolean(config[key], f"{label}.{key}")


def validate_snapshot(path, inputs, network_magic):
    snapshot = inputs.document(path)
    magic = integer(snapshot.get("NetworkMagic"), "snapshot.NetworkMagic", 0, (1 << 32) - 1)
    require(magic == network_magic,
            f"Snapshot NetworkMagic {magic} != expected {network_magic}: {path}")
    # A sanity bound only; do not pretend node release numbers identify decoders.
    integer(snapshot.get("NodeToClientVersion"), "snapshot.NodeToClientVersion", 16, 32767)
    point = object_value(snapshot.get("Point"), "snapshot.Point")
    integer(point.get("blockPointSlot"), "snapshot.Point.blockPointSlot", 0, (1 << 64) - 1)
    block_hash = point.get("blockPointHash")
    require(isinstance(block_hash, str) and re.fullmatch(r"[0-9a-fA-F]{64}", block_hash),
            "snapshot.Point.blockPointHash must be a 32-byte hexadecimal hash")
    pools = array(snapshot.get("bigLedgerPools"), "snapshot.bigLedgerPools")
    require(bool(pools), "snapshot.bigLedgerPools must be nonempty")
    previous = 0
    for i, pool in enumerate(pools):
        label = f"snapshot.bigLedgerPools[{i}]"
        object_value(pool, label)
        for key in ("accumulatedStake", "relativeStake"):
            value = pool.get(key)
            require(type(value) in (int, float) and 0 <= value <= 1,
                    f"{label}.{key} must be a finite numeric stake fraction in 0..1")
        accumulated = pool["accumulatedStake"]
        require(accumulated >= previous and accumulated >= pool["relativeStake"],
                f"{label}: accumulatedStake must be nondecreasing and >= relativeStake")
        previous = accumulated
        relays = array(pool.get("relays"), f"{label}.relays")
        require(bool(relays), f"{label}.relays must be nonempty")
        for j, relay in enumerate(relays):
            access_point(relay, f"{label}.relays[{j}]", snapshot=True)


def roots(groups, label, local=False):
    usable = False
    trustable = False
    total_hot = total_warm = 0
    for i, group in enumerate(array(groups, label)):
        prefix = f"{label}[{i}]"
        object_value(group, prefix)
        points = array(group.get("accessPoints"), f"{prefix}.accessPoints")
        for j, point in enumerate(points):
            access_point(point, f"{prefix}.accessPoints[{j}]")
        for key in ("advertise", "trustable", "behindFirewall"):
            if key in group:
                boolean(group[key], f"{prefix}.{key}")
        for key in ("valency", "hotValency", "warmValency"):
            if key in group:
                integer(group[key], f"{prefix}.{key}")
        if "diffusionMode" in group:
            require(group["diffusionMode"] in ("InitiatorOnly", "InitiatorAndResponder"),
                    f"{prefix}.diffusionMode is unsupported")
        if local:
            hot = integer(group.get("valency", group.get("hotValency")),
                          f"{prefix}.valency/hotValency")
            if "valency" in group and "hotValency" in group:
                require(group["valency"] == group["hotValency"],
                        f"{prefix}: conflicting valency and hotValency")
            warm = integer(group.get("warmValency", hot), f"{prefix}.warmValency")
            require(hot <= warm, f"{prefix}: hot valency must not exceed warmValency")
            total_hot += hot
            total_warm += warm
            integer(total_hot, f"{label} total hot valency")
            integer(total_warm, f"{label} total warm valency")
            active = bool(points) and hot > 0
            usable |= active
            trustable |= active and group.get("trustable", False)
        else:
            usable |= bool(points)
    return usable, trustable


def validate_topology(topology, role, files_dir, inputs, network_magic):
    """Return P2P flag, snapshot status, warnings; never mutate topology."""
    if "Producers" in topology:
        require(not P2P_KEYS.intersection(topology),
                "Mixed Producers/P2P topology is not supported")
        producers = array(topology["Producers"], "Producers")
        require(bool(producers), "Producers must be nonempty")
        for i, producer in enumerate(producers):
            access_point(producer, f"Producers[{i}]", legacy=True)
            integer(producer.get("valency"), f"Producers[{i}].valency", 1)
        return False, "not-referenced", []

    local = topology.get("localRoots")
    public = topology.get("publicRoots", [])
    local_usable, trusted = roots(local, "localRoots", local=True)
    public_usable, _ = roots(public, "publicRoots")
    ledger = integer(topology.get("useLedgerAfterSlot", -1), "useLedgerAfterSlot", -1)
    bootstrap = topology.get("bootstrapPeers")
    if bootstrap is not None:
        array(bootstrap, "bootstrapPeers")
        for i, peer in enumerate(bootstrap):
            access_point(peer, f"bootstrapPeers[{i}]")
        require(bool(bootstrap) or trusted,
                "bootstrapPeers=[] enables bootstrap and requires a usable nonempty "
                "trustable=true localRoots group; use null to disable bootstrap")

    if role == "bp":
        require(local_usable, "P2P BP requires usable nonempty localRoots with positive valency")
        require(all(not group.get("advertise", False) for group in local),
                "P2P BP requires localRoots advertise=false (or missing)")
        require(not public_usable, "P2P BP requires empty publicRoots accessPoints")
        require(bootstrap is None, "P2P BP requires bootstrapPeers=null or absent, not []")
        require(ledger == -1, "P2P BP requires ledger discovery disabled (useLedgerAfterSlot=-1)")

    warnings = []
    reference = topology.get("peerSnapshotFile")
    snapshot_status = "not-referenced"
    if reference is not None:
        relative = path_reference(reference, "peerSnapshotFile")
        if ledger == -1:
            snapshot_status = "ignored-ledger-disabled"
            warnings.append("peerSnapshotFile is retained but ignored: ledger discovery is disabled; "
                            "the snapshot was not read, changed or deleted.")
        else:
            # Even backup topology paths must resolve at the FINAL live location.
            snapshot_path = files_dir / relative
            validate_snapshot(snapshot_path, inputs, network_magic)
            snapshot_status = "validated-structural"
    if role == "relay":
        require(local_usable or public_usable or bool(bootstrap)
                or (ledger >= 0 and snapshot_status == "validated-structural"),
                "Relay has no usable local/public/bootstrap source or enabled ledger + valid snapshot")
    return True, snapshot_status, warnings


def protected_roots(topology):
    """None means original peer arrays cannot be established safely."""
    if not isinstance(topology, dict):
        return None
    protected = {key: topology[key] for key in ("localRoots", "Producers") if key in topology}
    if not protected or any(not isinstance(value, list) for value in protected.values()):
        return None
    return canonical(protected)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=True, allow_nan=False, indent=2)


def backup_timestamp(directory):
    match = re.search(r"(?<![0-9])([0-9]{8}T[0-9]{6}Z)$", directory.name)
    if match is None:
        return None
    try:
        return datetime.strptime(match[1], "%Y%m%dT%H%M%SZ")
    except ValueError as exc:
        raise PlanError(f"Invalid calendar timestamp in backup directory: {directory.name}") from exc


def genesis_hash(data, expected, label):
    require(isinstance(expected, str) and re.fullmatch(r"[0-9a-fA-F]{64}", expected),
            f"{label} must be a 32-byte hexadecimal genesis hash")
    require(hashlib.blake2b(data, digest_size=32).hexdigest() == expected.lower(),
            f"Backup Shelley genesis hash does not match {label}")


def candidate(path, files_dir, live_config, role, network_magic):
    path = safe_path(path)
    directory = path.parent
    require(path.name == "topology.json" and directory.parent == files_dir.parent
            and directory != files_dir and fnmatch.fnmatchcase(directory.name, "files-*-bak*"),
            "--topology-backup must name topology.json inside a same-node adjacent files-*-bak* directory")
    inputs = Inputs()
    config = inputs.document(directory / "config.json")
    config_mode(config, str(directory / "config.json"))
    require(config.get("ConsensusMode") == "PraosMode",
            "Backup config.json must explicitly declare ConsensusMode=PraosMode; "
            "missing mode, filename versions and Conway fields are not provenance")
    reference = path_reference(config.get("ShelleyGenesisFile"), "backup.ShelleyGenesisFile")
    require(reference.name not in ("", ".", ".."), "Backup ShelleyGenesisFile needs a sibling filename")
    genesis_path = directory / reference.name
    genesis_data = inputs.read(genesis_path)
    genesis = decode(genesis_data, str(genesis_path))
    magic = integer(genesis.get("networkMagic"), "backup Shelley networkMagic", 0, (1 << 32) - 1)
    require(magic == network_magic,
            f"Backup network magic {magic} != expected {network_magic}")
    if "ShelleyGenesisHash" in live_config:
        genesis_hash(genesis_data, live_config["ShelleyGenesisHash"], "live ShelleyGenesisHash")
    if "ShelleyGenesisHash" in config:
        genesis_hash(genesis_data, config["ShelleyGenesisHash"], "backup ShelleyGenesisHash")
    data = inputs.read(path)
    topology = decode(data, str(path))
    info = validate_topology(topology, role, files_dir, inputs, network_magic)
    if "EnableP2P" in config:
        require(config["EnableP2P"] is info[0], "Backup EnableP2P is incoherent with its topology")
    return {"path": path, "data": data, "topology": topology, "info": info,
            "inputs": inputs, "timestamp": backup_timestamp(directory)}


def recover(files_dir, live_config, current, role, network_magic, explicit, inputs):
    if explicit is not None:
        selected = candidate(explicit, files_dir, live_config, role, network_magic)
        inputs.merge(selected["inputs"])
        return selected
    original_roots = protected_roots(current)
    require(original_roots is not None,
            "Cannot establish original localRoots/Producers from current topology; automatic recovery "
            "is unsafe. Inspect a paired backup and pass --topology-backup explicitly")
    valid = []
    for directory in sorted(files_dir.parent.glob("files-*-bak*")):
        if directory == files_dir:
            continue
        path = directory / "topology.json"
        try:
            item = candidate(path, files_dir, live_config, role, network_magic)
            require(protected_roots(item["topology"]) == original_roots,
                    "localRoots/Producers differ (including flags/order/metadata); "
                    "automatic peer-list changes are refused; use --topology-backup after review")
            valid.append(item)
        except PlanError as exc:
            print(f"Excluded backup {path}: {exc}")
    require(bool(valid),
            "No eligible paired Praos backup. Review the exclusion reasons, repair the current "
            "topology/dependencies or pass a verified --topology-backup explicitly")
    dated = [item for item in valid if item["timestamp"] is not None]
    undated = [item for item in valid if item["timestamp"] is None]
    if dated:
        newest = max(item["timestamp"] for item in dated)
        contenders = [item for item in dated if item["timestamp"] == newest] + undated
    else:
        contenders = undated
    require(len({sha256(item["data"]) for item in contenders}) == 1,
            "Ambiguous undated or tied backup topologies: "
            + ", ".join(str(item["path"]) for item in contenders)
            + "; review semantic differences and pass --topology-backup explicitly")
    # Dated contenders sort first, then path for deterministic identical copies.
    selected = sorted(contenders, key=lambda item: (item["timestamp"] is None, str(item["path"])))[0]
    for item in valid:
        # These bytes informed ranking/coalescing; rejected backups need not be recorded.
        inputs.merge(item["inputs"])
    if len(contenders) > 1:
        print(f"Coalesced {len(contenders)} byte-identical backup topologies")
    return selected


def semantic_diff(label, before, after):
    print(f"Semantic diff ({label}):")
    if before is None:
        print("  Original JSON unavailable; selected object follows:")
        print(canonical(after))
        return
    old = canonical(before).splitlines()
    new = canonical(after).splitlines()
    if old == new:
        print("  No semantic changes.")
    else:
        print("\n".join(difflib.unified_diff(old, new, fromfile="before", tofile="after", lineterm="")))


def write_outputs(output_dir, files_dir, inputs, artifacts, topologies):
    output_dir = safe_path(output_dir)
    require(not within(output_dir, files_dir), "--output-dir must be outside the live files directory")
    for directory in files_dir.parent.glob("files-*-bak*"):
        require(not within(output_dir, directory), "--output-dir must be outside backup directories")
    protected = set(inputs.data)
    # Preserve current snapshots even when recovery selects a different reference.
    # Disabled references are not read and therefore are not in dependency hashes.
    for topology in topologies:
        reference = topology.get("peerSnapshotFile") if isinstance(topology, dict) else None
        if isinstance(reference, str) and "\x00" not in reference:
            protected.add((files_dir / reference).resolve())
    for name in artifacts:
        destination = safe_path(output_dir / name)
        require(destination not in protected, f"Output would overwrite an input/snapshot: {destination}")
        if destination.exists():
            require(destination.is_file(), f"Output is not a regular file: {destination}")
            require(all(not os.path.samefile(destination, path) for path in inputs.data),
                    f"Output is hard-linked to an input: {destination}")
    # Detect ordinary concurrent input edits before publishing any artifacts.
    for path, data in inputs.data.items():
        require(Inputs().read(path) == data, f"Input changed while planning: {path}; retry")
    output_dir.mkdir(parents=True, exist_ok=True)
    pending = []
    try:
        for name, data in artifacts.items():
            fd, temporary = tempfile.mkstemp(prefix=f".{name}.", dir=output_dir)
            pending.append((Path(temporary), output_dir / name))
            with os.fdopen(fd, "wb") as stream:
                stream.write(data)
                stream.flush()
                os.fsync(stream.fileno())
        for temporary, destination in pending:
            safe_path(destination)
            os.replace(temporary, destination)
    finally:
        for temporary, _ in pending:
            temporary.unlink(missing_ok=True)


def plan(args):
    files_dir = safe_path(args.files_dir)
    require(files_dir.is_dir(), f"--files-dir is not a directory: {files_dir}")
    staged_path = safe_path(args.config)
    inputs = Inputs()
    config_data = inputs.read(files_dir / "config.json")
    live_config = decode(config_data, str(files_dir / "config.json"))
    staged_data = inputs.read(staged_path)
    staged = decode(staged_data, str(staged_path))
    config_mode(live_config, "live config")
    config_mode(staged, "staged config")
    current_path = safe_path(files_dir / "topology.json")
    # Missing/unreadable current topology cannot supply the required before hash.
    current_data = inputs.read(current_path)
    current = None
    warnings = [STRUCTURAL_WARNING]
    try:
        current = decode(current_data, str(current_path))
        info = validate_topology(current, args.role, files_dir, inputs, args.network_magic)
        selected = {"path": current_path, "data": current_data, "topology": current, "info": info}
        invalid = None
    except UnsafePath:
        raise
    except PlanError as exc:
        invalid = str(exc)
        print(f"Current topology is invalid for proposed Praos/{args.role}: {invalid}")
    if invalid is not None or args.topology_backup is not None:
        selected = recover(files_dir, live_config, current, args.role, args.network_magic,
                           args.topology_backup, inputs)
        if invalid is not None:
            warnings.append(f"Recovery required: {invalid}")
        if args.topology_backup is not None:
            warnings.append("Explicit --topology-backup authorizes the selected peer-list changes; "
                            "paired provenance, role and final live dependencies were still checked.")
        if "ShelleyGenesisHash" not in live_config:
            warnings.append("Live ShelleyGenesisHash is absent; backup network identity is checked "
                            "by network magic only, not a live configured genesis hash.")
    p2p, snapshot_status, topology_warnings = selected["info"]
    warnings.extend(topology_warnings)
    normalized = dict(staged)
    normalized["ConsensusMode"] = "PraosMode"
    normalized["EnableP2P"] = p2p
    if args.role == "bp":
        normalized["PeerSharing"] = False
    normalized_data = staged_data if normalized == staged else (canonical(normalized) + "\n").encode()
    if p2p and selected["topology"].get("bootstrapPeers") is not None and (
            live_config.get("ConsensusMode") == "GenesisMode"
            or staged.get("ConsensusMode") == "GenesisMode"):
        warnings.append("Genesis->Praos activates bootstrapPeers that Genesis ignores, including "
                        "trustable local roots when bootstrapPeers=[]; review peer-discovery exposure.")
    recovered = selected["path"] != current_path
    decision = "explicit-backup" if args.topology_backup else ("automatic-backup" if recovered else "preserve")
    metadata = {
        "topology_p2p": p2p,
        "topology_source": str(selected["path"]),
        "topology_recovered": recovered,
        "topology_before_sha256": sha256(current_data),
        "topology_after_sha256": sha256(selected["data"]),
        "config_before_sha256": sha256(config_data),
        "config_after_sha256": sha256(normalized_data),
        "snapshot_status": snapshot_status,
        "warnings": warnings,
        "dependencies": inputs.hashes(),
        "staged_config_sha256": sha256(staged_data),
        "target_version": args.target_version,
        "role": args.role,
        "network_magic": args.network_magic,
        "decision": decision,
    }
    semantic_diff("live config -> planned config", live_config, normalized)
    semantic_diff("staged config -> Praos normalization", staged, normalized)
    semantic_diff("live topology -> selected topology", current, selected["topology"])
    print(f"Decision: {decision}; source={selected['path']}; P2P={p2p}; "
          f"ConsensusMode=PraosMode; role={args.role}; target={args.target_version}")
    print(f"Snapshot: {snapshot_status}; topology bytes copied exactly; live files are not modified.")
    for warning in warnings:
        print(f"Warning: {warning}")
    artifacts = {"config.json": normalized_data, "topology.json": selected["data"],
                 "plan.json": (canonical(metadata) + "\n").encode()}
    write_outputs(args.output_dir, files_dir, inputs, artifacts, (current, selected["topology"]))
    print(f"Plan written to {safe_path(args.output_dir)}")
    return metadata


def network_magic_arg(text):
    try:
        return integer(int(text), "--network-magic", 0, (1 << 32) - 1)
    except (ValueError, PlanError) as exc:
        raise argparse.ArgumentTypeError(str(exc)) from exc


def target_version_arg(text):
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", text):
        raise argparse.ArgumentTypeError("--target-version must be X.Y.Z (numeric release version)")
    return text


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--files-dir", required=True, type=Path)
    parser.add_argument("--config", required=True, type=Path, help="Staged proposed config input")
    parser.add_argument("--output-dir", required=True, type=Path, help="Separate planner output directory")
    parser.add_argument("--role", required=True, choices=("bp", "relay"))
    parser.add_argument("--network-magic", required=True, type=network_magic_arg)
    parser.add_argument("--topology-backup", type=Path, help="Explicit paired backup topology.json")
    parser.add_argument("--target-version", required=True, type=target_version_arg)
    args = parser.parse_args(argv)
    try:
        plan(args)
    except (PlanError, OSError, ValueError, RecursionError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())