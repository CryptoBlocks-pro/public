"""Synthetic, temporary-directory-only CLI and validation tests. No live fixtures."""

import copy
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "upgrade-cardano-config.py"
SPEC = importlib.util.spec_from_file_location("upgrade_cardano_config", SCRIPT)
PLANNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PLANNER)
MAGIC = 42


def point(host="relay.example", port=3001):
    return {"address": host, "port": port}


def topology():
    return {"localRoots": [{"accessPoints": [point()], "advertise": False,
                            "trustable": False, "valency": 1}],
            "publicRoots": [], "bootstrapPeers": None, "useLedgerAfterSlot": -1}


def snapshot():
    return {"NetworkMagic": MAGIC, "NodeToClientVersion": 23,
            "Point": {"blockPointSlot": 123, "blockPointHash": "ab" * 32},
            "bigLedgerPools": [{"accumulatedStake": 0.6, "relativeStake": 0.6,
                                "relays": [point(), {"address": "srv.example"}]}]}


def digest(data):
    return hashlib.sha256(data).hexdigest()


class PlannerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="cardano-planner-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.files = self.root / "node" / "files"
        self.files.mkdir(parents=True)
        self.stage = self.root / "staged" / "config.json"
        self.out = self.root / "output"
        self.genesis = {"networkMagic": MAGIC, "fixture": "synthetic Shelley genesis"}
        self.genesis_data = self.write(self.files / "shelley-genesis.json", self.genesis)
        self.config = {"ConsensusMode": "PraosMode", "EnableP2P": True,
                       "PeerSharing": True, "ShelleyGenesisFile": "shelley-genesis.json",
                       "ShelleyGenesisHash": hashlib.blake2b(self.genesis_data, digest_size=32).hexdigest()}
        self.write(self.files / "config.json", self.config)
        self.write(self.stage, self.config)
        self.write(self.files / "topology.json", topology())

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        data = value if isinstance(value, bytes) else (json.dumps(value, indent=2) + "\n").encode()
        path.write_bytes(data)
        return data

    def backup(self, name="files-11.0.1-bak-20260918T010203Z", topo=None,
               config=None, genesis=None):
        directory = self.files.parent / name
        paired = copy.deepcopy(self.config if config is None else config)
        self.write(directory / "config.json", paired)
        self.write(directory / "topology.json", topology() if topo is None else topo)
        ref = paired.get("ShelleyGenesisFile", "shelley-genesis.json")
        self.write(directory / Path(ref).name, self.genesis_data if genesis is None else genesis)
        return directory / "topology.json"

    def invalidate_bp(self):
        current = topology()
        current["useLedgerAfterSlot"] = 0
        self.write(self.files / "topology.json", current)
        return current

    def run_cli(self, role="relay", backup=None, success=True, output=None, config=None, extra=()):
        args = [sys.executable, str(SCRIPT), "--files-dir", str(self.files),
                "--config", str(config or self.stage), "--output-dir", str(output or self.out),
                "--role", role, "--network-magic", str(MAGIC), "--target-version", "11.1.2"]
        if backup is not None:
            args += ["--topology-backup", str(backup)]
        args += list(extra)
        # Snapshot all non-output fixture bytes and inode metadata around EVERY CLI call.
        output_path = output or self.out
        before = self.inventory(exclude=output_path)
        result = subprocess.run(args, text=True, capture_output=True,
                                env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"}, timeout=15)
        self.assertEqual(before, self.inventory(exclude=output_path), "Input files were mutated")
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertNotIn("Traceback", result.stderr)
        return result

    def inventory(self, exclude=None):
        result = {}
        for path in self.root.rglob("*"):
            if exclude is not None and (path == exclude or exclude in path.parents):
                continue
            if path.is_file() and not path.is_symlink():
                info = path.stat()
                result[str(path)] = (path.read_bytes(), info.st_ino, info.st_mode, info.st_mtime_ns)
        return result

    def metadata(self, output=None):
        return json.loads(((output or self.out) / "plan.json").read_bytes())

    def assert_dependency(self, path, metadata=None):
        meta = metadata or self.metadata()
        self.assertEqual(meta["dependencies"][str(path.resolve())], digest(path.read_bytes()))

    def test_normal_praos_bytes_and_metadata_contract(self):
        raw = b'{ "ConsensusMode":"PraosMode", "EnableP2P":true, "PeerSharing":true }\r\n'
        self.write(self.stage, raw)
        topo_data = self.write(self.files / "topology.json", json.dumps(topology()).encode() + b"  \n")
        result = self.run_cli()
        meta = self.metadata()
        self.assertEqual((self.out / "config.json").read_bytes(), raw)
        self.assertEqual((self.out / "topology.json").read_bytes(), topo_data)
        self.assertEqual(set(p.name for p in self.out.iterdir()), {"config.json", "topology.json", "plan.json"})
        self.assertIs(meta["topology_p2p"], True)
        self.assertIs(meta["topology_recovered"], False)
        self.assertEqual(meta["topology_source"], str(self.files / "topology.json"))
        self.assertEqual(meta["topology_before_sha256"], digest(topo_data))
        self.assertEqual(meta["topology_after_sha256"], digest(topo_data))
        self.assertEqual(meta["config_before_sha256"], digest((self.files / "config.json").read_bytes()))
        self.assertEqual(meta["config_after_sha256"], digest(raw))
        self.assertEqual(meta["staged_config_sha256"], digest(raw))
        self.assertEqual(meta["snapshot_status"], "not-referenced")
        self.assertIsInstance(meta["warnings"], list)
        self.assertEqual(meta["target_version"], "11.1.2")
        for path in (self.stage, self.files / "config.json", self.files / "topology.json"):
            self.assert_dependency(path)
        self.assertIn("Semantic diff", result.stdout)
        self.assertIn("Decision: preserve", result.stdout)

    def test_genesis_conversion_with_valid_snapshot_and_bootstrap_warning(self):
        self.config["ConsensusMode"] = "GenesisMode"
        self.write(self.files / "config.json", self.config)
        self.write(self.stage, self.config)
        topo = topology()
        topo.update(useLedgerAfterSlot=0, peerSnapshotFile="snapshots/peers.json", bootstrapPeers=[point()])
        raw = self.write(self.files / "topology.json", topo)
        self.write(self.files / "snapshots" / "peers.json", snapshot())
        result = self.run_cli()
        planned = json.loads((self.out / "config.json").read_bytes())
        self.assertEqual(planned["ConsensusMode"], "PraosMode")
        self.assertTrue(planned["PeerSharing"])
        self.assertEqual((self.out / "topology.json").read_bytes(), raw)
        self.assertEqual(self.metadata()["snapshot_status"], "validated-structural")
        self.assert_dependency(self.files / "snapshots" / "peers.json")
        self.assertIn("Genesis->Praos activates bootstrapPeers", result.stdout)
        self.assertIn("not the full Haskell decoder", result.stdout)

    def test_disabled_bp_snapshot_retained_not_read_and_peer_sharing_disabled(self):
        topo = topology()
        topo["peerSnapshotFile"] = "peer-snapshot.json"
        raw = self.write(self.files / "topology.json", topo)
        peer_file = self.files / "peer-snapshot.json"
        self.write(peer_file, b"deliberately malformed inactive snapshot")
        self.run_cli(role="bp")
        self.assertEqual(peer_file.read_bytes(), b"deliberately malformed inactive snapshot")
        self.assertEqual((self.out / "topology.json").read_bytes(), raw)
        self.assertEqual(self.metadata()["snapshot_status"], "ignored-ledger-disabled")
        self.assertNotIn(str(peer_file), self.metadata()["dependencies"])
        self.assertIs(json.loads((self.out / "config.json").read_bytes())["PeerSharing"], False)

    def test_disabled_missing_snapshot_allowed(self):
        topo = topology()
        topo["peerSnapshotFile"] = "missing.json"
        self.write(self.files / "topology.json", topo)
        self.run_cli()
        self.assertEqual(self.metadata()["snapshot_status"], "ignored-ledger-disabled")

    def test_bp_discovery_rejected_without_backups(self):
        for change in ({"useLedgerAfterSlot": 0}, {"bootstrapPeers": [point()]},
                       {"publicRoots": [{"accessPoints": [point()]}]},
                       {"localRoots": []}):
            with self.subTest(change=change):
                topo = topology()
                topo.update(change)
                self.write(self.files / "topology.json", topo)
                result = self.run_cli(role="bp", success=False)
                self.assertIn("P2P BP requires", result.stdout)
                self.assertFalse(self.out.exists())

    def test_bp_advertising_rejected(self):
        topo = topology()
        topo["localRoots"][0]["advertise"] = True
        self.write(self.files / "topology.json", topo)
        self.assertIn("advertise=false", self.run_cli(role="bp", success=False).stdout)

    def test_legacy_bp_preserves_producers_without_hostname_inference(self):
        topo = {"Producers": [{"addr": "public.example", "port": 3001, "valency": 2}]}
        raw = self.write(self.files / "topology.json", topo)
        self.run_cli(role="bp")
        planned = json.loads((self.out / "config.json").read_bytes())
        self.assertFalse(planned["EnableP2P"])
        self.assertFalse(planned["PeerSharing"])
        self.assertEqual((self.out / "topology.json").read_bytes(), raw)
        self.assertFalse(self.metadata()["topology_p2p"])

    def test_legacy_missing_valency_and_empty_producers_rejected(self):
        for producers in ([], [{"addr": "relay.example", "port": 3001}],
                          [{"addr": "relay.example", "port": 3001, "valency": 0}]):
            with self.subTest(producers=producers):
                self.write(self.files / "topology.json", {"Producers": producers})
                self.run_cli(success=False)

    def test_mixed_topology_rejected(self):
        topo = topology()
        topo["Producers"] = [{"addr": "relay.example", "port": 3001, "valency": 1}]
        self.write(self.files / "topology.json", topo)
        self.assertIn("Mixed Producers/P2P", self.run_cli(success=False).stdout)

    def test_missing_enable_p2p_and_consensus_normalized(self):
        self.write(self.files / "config.json", {})
        self.write(self.stage, {"PeerSharing": False})
        self.run_cli()
        planned = json.loads((self.out / "config.json").read_bytes())
        self.assertEqual(planned, {"ConsensusMode": "PraosMode", "EnableP2P": True, "PeerSharing": False})

    def test_custom_config_and_topology_metadata_retained(self):
        custom = {**self.config, "ConsensusMode": "GenesisMode", "metrics": {"port": 9999},
                  "ConwayGenesisFile": "not-mode-evidence.json", "custom": [1, {"keep": True}]}
        self.write(self.stage, custom)
        topo = topology()
        topo["localRoots"][0]["operatorTag"] = {"note": "do not change"}
        topo["custom"] = {"preserve": [False, None, "extra"]}
        raw = self.write(self.files / "topology.json", topo)
        self.run_cli()
        expected = {**custom, "ConsensusMode": "PraosMode"}
        self.assertEqual(json.loads((self.out / "config.json").read_bytes()), expected)
        self.assertEqual((self.out / "topology.json").read_bytes(), raw)

    def test_unknown_original_and_proposed_modes_fail_even_with_explicit_backup(self):
        backup = self.backup()
        for path in (self.files / "config.json", self.stage):
            for mode in ("UnknownMode", None, False, {}, 1):
                with self.subTest(path=path, mode=mode):
                    self.write(path, {**self.config, "ConsensusMode": mode})
                    result = self.run_cli(backup=backup, success=False)
                    self.assertIn("ConsensusMode is unknown", result.stderr)
                    self.write(path, self.config)

    def test_local_only_missing_optional_defaults_needs_no_snapshot(self):
        topo = {"localRoots": [{"accessPoints": [point()], "hotValency": 1}]}
        raw = self.write(self.files / "topology.json", topo)
        self.run_cli(role="bp")
        self.assertEqual((self.out / "topology.json").read_bytes(), raw)
        self.assertEqual(self.metadata()["snapshot_status"], "not-referenced")

    def test_bootstrap_null_empty_and_nonempty_semantics(self):
        for bootstrap, trusted, success in ((None, False, True), ([], False, False),
                                             ([], True, True), ([point()], False, True)):
            with self.subTest(bootstrap=bootstrap, trusted=trusted):
                topo = topology()
                topo["bootstrapPeers"] = bootstrap
                topo["localRoots"][0]["trustable"] = trusted
                self.write(self.files / "topology.json", topo)
                self.run_cli(success=success)

    def test_bootstrap_empty_trusted_but_empty_or_zero_valency_is_not_source(self):
        for change in ({"accessPoints": []}, {"valency": 0}):
            with self.subTest(change=change):
                topo = topology()
                topo["bootstrapPeers"] = []
                topo["localRoots"][0].update(trustable=True, **change)
                self.write(self.files / "topology.json", topo)
                self.assertIn("requires a usable", self.run_cli(success=False).stdout)

    def test_bp_rejects_empty_bootstrap_even_with_trusted_roots(self):
        topo = topology()
        topo["bootstrapPeers"] = []
        topo["localRoots"][0]["trustable"] = True
        self.write(self.files / "topology.json", topo)
        self.assertIn("not []", self.run_cli(role="bp", success=False).stdout)

    def test_relay_public_or_bootstrap_only_source(self):
        for extra in ({"publicRoots": [{"accessPoints": [point()]}]}, {"bootstrapPeers": [point()]}):
            with self.subTest(extra=extra):
                topo = {"localRoots": [], **extra}
                self.write(self.files / "topology.json", topo)
                self.run_cli()

    def test_ledger_only_requires_valid_snapshot(self):
        topo = {"localRoots": [], "useLedgerAfterSlot": 0}
        self.write(self.files / "topology.json", topo)
        self.assertIn("no usable", self.run_cli(success=False).stdout)
        topo["peerSnapshotFile"] = "peer-snapshot.json"
        self.write(self.files / "topology.json", topo)
        self.write(self.files / "peer-snapshot.json", snapshot())
        self.run_cli()

    def test_local_roots_with_ledger_enabled_do_not_require_unreferenced_snapshot(self):
        topo = topology()
        topo["useLedgerAfterSlot"] = 0
        self.write(self.files / "topology.json", topo)
        self.run_cli()

    def test_newest_valid_timestamp_auto_selected_not_mtime_or_version(self):
        self.invalidate_bp()
        older = self.backup("files-99.0.0-bak-20260917T230000Z", topo={**topology(), "note": "older"})
        selected = self.backup("files-1.0.0-bak-20260918T010000Z", topo={**topology(), "note": "newer"})
        os.utime(older, (2000000000, 2000000000))
        os.utime(selected, (1000000000, 1000000000))
        self.run_cli(role="bp")
        meta = self.metadata()
        self.assertEqual(meta["topology_source"], str(selected))
        self.assertTrue(meta["topology_recovered"])
        self.assertEqual((self.out / "topology.json").read_bytes(), selected.read_bytes())
        for name in ("config.json", "topology.json", "shelley-genesis.json"):
            self.assert_dependency(selected.parent / name)

    def test_valid_current_ignores_backups_unless_explicit(self):
        changed = topology()
        changed["localRoots"][0]["accessPoints"] = [point("approved.example")]
        backup = self.backup(topo=changed)
        self.run_cli()
        self.assertFalse(self.metadata()["topology_recovered"])
        self.assertNotIn(str(backup), self.metadata()["dependencies"])
        result = self.run_cli(backup=backup)
        self.assertTrue(self.metadata()["topology_recovered"])
        self.assertIn("approved.example", result.stdout)

    def test_wrong_backup_network_rejected_even_explicit(self):
        self.invalidate_bp()
        backup = self.backup(genesis={"networkMagic": MAGIC + 1})
        self.assertIn("network magic", self.run_cli(role="bp", success=False).stdout)
        self.assertIn("network magic", self.run_cli(role="bp", backup=backup, success=False).stderr)

    def test_backup_requires_sibling_genesis_even_with_absolute_live_reference(self):
        self.invalidate_bp()
        config = {**self.config, "ShelleyGenesisFile": str(self.files / "shelley-genesis.json")}
        backup = self.backup(config=config)
        self.run_cli(role="bp")
        self.assert_dependency(backup.parent / "shelley-genesis.json")
        self.assertNotIn(str(self.files / "shelley-genesis.json"), self.metadata()["dependencies"])
        (backup.parent / "shelley-genesis.json").unlink()
        result = self.run_cli(role="bp", backup=backup, success=False)
        self.assertIn(str(backup.parent / "shelley-genesis.json"), result.stderr)

    def test_backup_genesis_hash_must_match_live_even_if_magic_matches(self):
        self.invalidate_bp()
        backup = self.backup(genesis={**self.genesis, "different": True})
        self.assertIn("live ShelleyGenesisHash", self.run_cli(role="bp", backup=backup, success=False).stderr)

    def test_no_live_genesis_hash_allows_magic_evidence_with_warning(self):
        del self.config["ShelleyGenesisHash"]
        self.write(self.files / "config.json", self.config)
        self.invalidate_bp()
        self.backup()
        result = self.run_cli(role="bp")
        self.assertIn("network magic only", result.stdout)

    def test_backup_mode_must_be_explicit_praos_not_filename_or_conway(self):
        self.invalidate_bp()
        for mode in (None, "GenesisMode"):
            with self.subTest(mode=mode):
                config = {**self.config, "ConwayGenesisFile": "conway-genesis.json"}
                if mode is None:
                    del config["ConsensusMode"]
                else:
                    config["ConsensusMode"] = mode
                backup = self.backup(config=config)
                result = self.run_cli(role="bp", backup=backup, success=False)
                self.assertIn("explicitly declare", result.stderr)

    def test_backup_p2p_coherence_and_missing_p2p_allowed(self):
        backup = self.backup(config={**self.config, "EnableP2P": False})
        self.assertIn("incoherent", self.run_cli(backup=backup, success=False).stderr)
        config = dict(self.config)
        del config["EnableP2P"]
        self.backup(config=config)
        self.run_cli(backup=backup)

    def test_different_local_roots_auto_refused_explicit_allowed(self):
        self.invalidate_bp()
        topo = topology()
        topo["localRoots"][0]["accessPoints"] = [point("other.example")]
        backup = self.backup(topo=topo)
        result = self.run_cli(role="bp", success=False)
        self.assertIn("localRoots/Producers differ", result.stdout)
        result = self.run_cli(role="bp", backup=backup)
        self.assertIn("other.example", result.stdout)
        self.assertEqual((self.out / "topology.json").read_bytes(), backup.read_bytes())

    def test_local_root_flag_changes_auto_refused(self):
        self.invalidate_bp()
        topo = topology()
        topo["localRoots"][0]["trustable"] = True
        self.backup(topo=topo)
        self.assertIn("localRoots/Producers differ", self.run_cli(role="bp", success=False).stdout)

    def test_bad_peer_candidate_excluded_not_blocking_safe_older_candidate(self):
        self.invalidate_bp()
        safe = self.backup("files-1-bak-20260917T000000Z")
        topo = topology()
        topo["localRoots"][0]["accessPoints"] = [point("other.example")]
        self.backup("files-1-bak-20260918T000000Z", topo=topo)
        result = self.run_cli(role="bp")
        self.assertIn("Excluded backup", result.stdout)
        self.assertEqual(self.metadata()["topology_source"], str(safe))

    def test_malformed_current_requires_explicit_recovery(self):
        self.write(self.files / "topology.json", b'{"localRoots": [')
        backup = self.backup()
        self.assertIn("Cannot establish original", self.run_cli(success=False).stderr)
        self.run_cli(backup=backup)
        self.assertEqual(self.metadata()["topology_before_sha256"], digest(b'{"localRoots": ['))

    def test_ambiguous_undated_candidates(self):
        self.invalidate_bp()
        a = self.backup("files-1-bak", topo={**topology(), "note": "a"})
        self.backup("files-2-bak", topo={**topology(), "note": "b"})
        self.assertIn("Ambiguous", self.run_cli(role="bp", success=False).stderr)
        self.run_cli(role="bp", backup=a)

    def test_ambiguous_tied_timestamps(self):
        self.invalidate_bp()
        self.backup("files-1-bak-20260918T010203Z", topo={**topology(), "note": "a"})
        self.backup("files-2-bak-20260918T010203Z", topo={**topology(), "note": "b"})
        self.assertIn("Ambiguous", self.run_cli(role="bp", success=False).stderr)

    def test_undated_differing_from_dated_is_ambiguous(self):
        self.invalidate_bp()
        self.backup("files-1-bak", topo={**topology(), "note": "a"})
        self.backup("files-2-bak-20260918T010203Z", topo={**topology(), "note": "b"})
        self.assertIn("Ambiguous", self.run_cli(role="bp", success=False).stderr)

    def test_identical_undated_backups_coalesce_deterministically(self):
        self.invalidate_bp()
        selected = self.backup("files-1-bak")
        self.backup("files-2-bak")
        result = self.run_cli(role="bp")
        self.assertIn("Coalesced", result.stdout)
        self.assertEqual(self.metadata()["topology_source"], str(selected))

    def test_invalid_calendar_timestamp_excluded(self):
        self.invalidate_bp()
        self.backup("files-1-bak-20260230T010203Z")
        good = self.backup("files-2-bak-20260228T010203Z")
        result = self.run_cli(role="bp")
        self.assertIn("Invalid calendar timestamp", result.stdout)
        self.assertEqual(self.metadata()["topology_source"], str(good))

    def test_explicit_backup_must_be_adjacent_and_paired(self):
        foreign = self.root / "other-node" / "files-1-bak" / "topology.json"
        self.write(foreign, topology())
        self.assertIn("same-node adjacent", self.run_cli(backup=foreign, success=False).stderr)
        unpaired = self.files.parent / "files-unpaired-bak" / "topology.json"
        self.write(unpaired, topology())
        self.assertIn("config.json", self.run_cli(backup=unpaired, success=False).stderr)

    def test_active_snapshot_missing_malformed_wrong_network_rejected(self):
        topo = {**topology(), "useLedgerAfterSlot": 0, "peerSnapshotFile": "peer-snapshot.json"}
        self.write(self.files / "topology.json", topo)
        peer = self.files / "peer-snapshot.json"
        for data, message in ((None, "Cannot read"), (b"not-json", "Invalid JSON"),
                              ({**snapshot(), "NetworkMagic": 999}, "NetworkMagic")):
            with self.subTest(data=data):
                if data is not None:
                    self.write(peer, data)
                result = self.run_cli(success=False)
                self.assertIn(message, result.stdout)

    def test_backup_snapshot_resolves_at_final_live_directory(self):
        topo = {**topology(), "useLedgerAfterSlot": 0, "peerSnapshotFile": "snapshots/peers.json"}
        backup = self.backup(topo=topo)
        self.write(backup.parent / "snapshots" / "peers.json", snapshot())
        result = self.run_cli(backup=backup, success=False)
        self.assertIn(str(self.files / "snapshots" / "peers.json"), result.stderr)
        self.write(self.files / "snapshots" / "peers.json", snapshot())
        # A malformed backup snapshot must not matter once final live reference is valid.
        self.write(backup.parent / "snapshots" / "peers.json", b"bad backup snapshot")
        self.run_cli(backup=backup)
        self.assert_dependency(self.files / "snapshots" / "peers.json")
        self.assertNotIn(str(backup.parent / "snapshots" / "peers.json"), self.metadata()["dependencies"])

    def test_invalid_active_snapshot_can_trigger_topology_recovery(self):
        topo = {**topology(), "useLedgerAfterSlot": 0, "peerSnapshotFile": "bad.json"}
        self.write(self.files / "topology.json", topo)
        self.write(self.files / "bad.json", b"bad json")
        self.backup()
        self.run_cli()
        self.assertEqual(self.metadata()["decision"], "automatic-backup")
        self.assert_dependency(self.files / "bad.json")

    def test_snapshot_structural_type_errors(self):
        cases = [
            (("NetworkMagic",), True), (("NodeToClientVersion",), True),
            (("NodeToClientVersion",), 1), (("NodeToClientVersion",), "23"),
            (("NodeToClientVersion",), 32768), (("Point", "blockPointSlot"), -1),
            (("Point", "blockPointSlot"), True), (("Point", "blockPointHash"), "abc"),
            (("bigLedgerPools",), []), (("bigLedgerPools", 0, "accumulatedStake"), "0.6"),
            (("bigLedgerPools", 0, "relativeStake"), True),
            (("bigLedgerPools", 0, "relativeStake"), -0.2),
            (("bigLedgerPools", 0, "accumulatedStake"), 0.1),
            (("bigLedgerPools", 0, "relays"), []),
            (("bigLedgerPools", 0, "relays"), [{"address": "192.0.2.1"}]),
            (("bigLedgerPools", 0, "relays"), [{"address": "dns.example", "port": None}]),
        ]
        peer = self.files / "peers.json"
        for keys, value in cases:
            with self.subTest(keys=keys, value=value):
                data = snapshot()
                parent = data
                for key in keys[:-1]:
                    parent = parent[key]
                parent[keys[-1]] = value
                self.write(peer, data)
                with self.assertRaises(PLANNER.PlanError):
                    PLANNER.validate_snapshot(peer, PLANNER.Inputs(), MAGIC)

    def test_topology_type_errors_and_group_totals(self):
        cases = [
            (("localRoots",), None), (("publicRoots",), {}),
            (("useLedgerAfterSlot",), True), (("useLedgerAfterSlot",), -2),
            (("bootstrapPeers",), False), (("peerSnapshotFile",), 7),
            (("localRoots", 0, "advertise"), "false"),
            (("localRoots", 0, "trustable"), 1),
            (("localRoots", 0, "valency"), True), (("localRoots", 0, "valency"), -1),
            (("localRoots", 0, "valency"), 1.0), (("localRoots", 0, "warmValency"), 0),
            (("localRoots", 0, "hotValency"), 2),
            (("localRoots", 0, "accessPoints", 0, "port"), "3001"),
            (("localRoots", 0, "accessPoints", 0, "port"), True),
            (("localRoots", 0, "accessPoints", 0, "port"), 65536),
            (("localRoots", 0, "accessPoints", 0, "address"), "https://relay.example"),
            (("localRoots", 0, "accessPoints", 0, "address"), "256.1.1.1"),
        ]
        for keys, value in cases:
            with self.subTest(keys=keys, value=value):
                data = topology()
                parent = data
                for key in keys[:-1]:
                    parent = parent[key]
                parent[keys[-1]] = value
                with self.assertRaises(PLANNER.PlanError):
                    PLANNER.validate_topology(data, "relay", self.files, PLANNER.Inputs(), MAGIC)
        data = topology()
        data["localRoots"][0]["valency"] = PLANNER.MAX_INT
        data["localRoots"].append(copy.deepcopy(data["localRoots"][0]))
        with self.assertRaisesRegex(PLANNER.PlanError, "total hot valency"):
            PLANNER.validate_topology(data, "relay", self.files, PLANNER.Inputs(), MAGIC)

    def test_domain_group_valency_not_capped_by_dns_access_point_count(self):
        data = topology()
        data["localRoots"][0]["valency"] = 3
        self.write(self.files / "topology.json", data)
        self.run_cli()

    def test_json_duplicates_nonfinite_and_nonobjects_rejected(self):
        for data in (b'{"ConsensusMode":"PraosMode","ConsensusMode":"GenesisMode"}',
                     b'{"x":NaN}', b'{"x":Infinity}', b'{"x":1e999}', b"[]", b"null"):
            with self.subTest(data=data):
                self.write(self.stage, data)
                self.assertIn("Invalid JSON", self.run_cli(success=False).stderr)

    def test_idempotence_same_output_and_normalized_output_as_next_input(self):
        self.write(self.stage, {**self.config, "ConsensusMode": "GenesisMode"})
        self.run_cli()
        first = {path.name: path.read_bytes() for path in self.out.iterdir()}
        self.run_cli()
        self.assertEqual(first, {path.name: path.read_bytes() for path in self.out.iterdir()})
        second = self.root / "second-output"
        self.run_cli(config=self.out / "config.json", output=second)
        self.assertEqual(first["config.json"], (second / "config.json").read_bytes())
        self.assertEqual(first["topology.json"], (second / "topology.json").read_bytes())

    def test_symlink_inputs_rejected(self):
        for path in (self.stage, self.files / "config.json", self.files / "topology.json"):
            with self.subTest(path=path):
                original = path.read_bytes()
                actual = self.root / "actual.json"
                self.write(actual, original)
                path.unlink()
                path.symlink_to(actual)
                self.assertIn("Symlink", self.run_cli(success=False).stderr)
                path.unlink()
                self.write(path, original)

    def test_symlink_directory_and_active_snapshot_rejected(self):
        link = self.root / "linked-stage"
        link.symlink_to(self.stage.parent, target_is_directory=True)
        self.assertIn("Symlink", self.run_cli(config=link / "config.json", success=False).stderr)
        topo = {**topology(), "useLedgerAfterSlot": 0, "peerSnapshotFile": "peers.json"}
        self.write(self.files / "topology.json", topo)
        actual = self.root / "snapshot.json"
        self.write(actual, snapshot())
        (self.files / "peers.json").symlink_to(actual)
        self.assertIn("Symlink", self.run_cli(success=False).stderr)

    def test_output_symlinks_live_directory_and_input_overlap_refused(self):
        self.out.mkdir()
        (self.out / "config.json").symlink_to(self.files / "config.json")
        self.assertIn("Symlink", self.run_cli(success=False).stderr)
        (self.out / "config.json").unlink()
        # Explicitly inventory live output-overlap too: run_cli excludes output by design.
        before = self.inventory()
        self.assertIn("outside the live", self.run_cli(output=self.files, success=False).stderr)
        self.assertEqual(before, self.inventory())
        self.assertIn("overwrite an input", self.run_cli(output=self.stage.parent, success=False).stderr)
        self.assertEqual(before, self.inventory())

    def test_output_hardlink_to_input_rejected(self):
        self.out.mkdir()
        os.link(self.stage, self.out / "config.json")
        self.assertIn("hard-linked", self.run_cli(success=False).stderr)

    def test_disabled_snapshot_cannot_be_clobbered_by_outputs(self):
        self.out.mkdir()
        snapshot_path = self.out / "config.json"
        raw = self.write(snapshot_path, b"inactive snapshot must survive")
        topo = {**topology(), "peerSnapshotFile": str(snapshot_path)}
        self.write(self.files / "topology.json", topo)
        self.assertIn("overwrite an input/snapshot", self.run_cli(success=False).stderr)
        self.assertEqual(snapshot_path.read_bytes(), raw)

    def test_missing_inputs_no_artifacts_written(self):
        self.stage.unlink()
        self.assertIn("Cannot read", self.run_cli(success=False).stderr)
        self.assertFalse(self.out.exists())

    def test_recovery_cannot_overwrite_formerly_referenced_snapshot(self):
        self.out.mkdir()
        former = self.out / "config.json"
        raw = self.write(former, b"inactive current snapshot")
        self.write(self.files / "topology.json", {**topology(), "peerSnapshotFile": str(former)})
        backup = self.backup()
        result = self.run_cli(backup=backup, success=False)
        self.assertIn("overwrite an input/snapshot", result.stderr)
        self.assertEqual(former.read_bytes(), raw)

    def test_legacy_recovery_protects_producers(self):
        legacy = {"Producers": [{"addr": "relay.example", "port": 3001, "valency": 1}]}
        # Invalid mixed topology still has an identifiable protected Producers array.
        self.write(self.files / "topology.json", {**legacy, "bootstrapPeers": []})
        config = {**self.config, "EnableP2P": False}
        backup = self.backup(topo=legacy, config=config)
        self.run_cli(role="bp")
        self.assertEqual((self.out / "topology.json").read_bytes(), backup.read_bytes())
        changed = copy.deepcopy(legacy)
        changed["Producers"][0]["addr"] = "approved.example"
        self.write(backup, changed)
        result = self.run_cli(role="bp", success=False)
        self.assertIn("localRoots/Producers differ", result.stdout)
        self.run_cli(role="bp", backup=backup)

    def test_identical_tied_and_undated_backups_choose_dated(self):
        self.invalidate_bp()
        self.backup("files-0-bak")
        expected = self.backup("files-1-bak-20260918T010203Z")
        self.backup("files-2-bak-20260918T010203Z")
        result = self.run_cli(role="bp")
        self.assertIn("Coalesced 3", result.stdout)
        self.assertEqual(self.metadata()["topology_source"], str(expected))

    def test_backup_timestamp_suffix_without_separator_and_valid_leap_day(self):
        self.invalidate_bp()
        self.backup("files-1-bak-20240228T230000Z", topo={**topology(), "note": "older"})
        expected = self.backup("files-2-bak20240229T000000Z")
        self.run_cli(role="bp")
        self.assertEqual(self.metadata()["topology_source"], str(expected))

    def test_backup_symlink_provenance_rejected(self):
        self.invalidate_bp()
        backup = self.backup()
        config = backup.parent / "config.json"
        config.unlink()
        config.symlink_to(self.files / "config.json")
        self.assertIn("Symlink", self.run_cli(role="bp", success=False).stdout)
        self.assertIn("Symlink", self.run_cli(role="bp", backup=backup, success=False).stderr)

    def test_staged_correct_bp_config_is_byte_preserved(self):
        raw = b'{"ConsensusMode":"PraosMode","EnableP2P":true,"PeerSharing":false}\r\n'
        self.write(self.stage, raw)
        self.run_cli(role="bp")
        self.assertEqual((self.out / "config.json").read_bytes(), raw)

    def test_relay_missing_peer_sharing_is_not_added(self):
        config = dict(self.config)
        del config["PeerSharing"]
        self.write(self.stage, config)
        self.run_cli()
        self.assertNotIn("PeerSharing", json.loads((self.out / "config.json").read_bytes()))

    def test_snapshot_ipv6_srv_and_modern_versions_not_mapped_to_target(self):
        topo = {**topology(), "peerSnapshotFile": "peers.json", "useLedgerAfterSlot": 0}
        self.write(self.files / "topology.json", topo)
        for version in (16, 23, 24):
            with self.subTest(version=version):
                data = snapshot()
                data["NodeToClientVersion"] = version
                data["bigLedgerPools"][0]["relays"] = [
                    point("2001:db8::1"), {"address": "_cardano._tcp.srv.example."}]
                self.write(self.files / "peers.json", data)
                self.run_cli()
                self.assertEqual(self.metadata()["snapshot_status"], "validated-structural")

    def test_nonregular_input_and_output_paths_fail_cleanly(self):
        fifo = self.root / "staged-pipe"
        os.mkfifo(fifo)
        self.assertIn("regular file", self.run_cli(config=fifo, success=False).stderr)
        (self.out / "plan.json").mkdir(parents=True)
        self.assertIn("not a regular file", self.run_cli(success=False).stderr)
        self.assertFalse((self.out / "config.json").exists())

    def test_outputs_cannot_be_written_inside_backup_or_symlink_directory(self):
        backup = self.backup()
        before = self.inventory()
        self.assertIn("outside backup", self.run_cli(output=backup.parent, success=False).stderr)
        self.assertEqual(before, self.inventory())
        alias = self.root / "output-alias"
        alias.symlink_to(self.files, target_is_directory=True)
        self.assertIn("Symlink", self.run_cli(output=alias, success=False).stderr)
        self.assertEqual(before, self.inventory())

    def test_config_boolean_fields_are_not_truthy_strings(self):
        for key in ("EnableP2P", "PeerSharing"):
            with self.subTest(key=key):
                self.write(self.stage, {**self.config, key: "false"})
                self.assertIn("must be a boolean", self.run_cli(success=False).stderr)

    def test_invalid_cli_values_fail_cleanly(self):
        for extra in (("--target-version", "11.1"), ("--network-magic", "-1"),
                      ("--network-magic", "4294967296"), ("--role", "guess")):
            with self.subTest(extra=extra):
                self.run_cli(extra=extra, success=False)
                self.assertFalse(self.out.exists())


if __name__ == "__main__":
    unittest.main()