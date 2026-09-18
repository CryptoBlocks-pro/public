# Cardano upgrades: Praos-first policy and roadmap

## Status and scope

This iteration configures **Praos on mainnet, preprod and preview**, including
nodes already running the requested binary version with a Genesis configuration.
There is deliberately no Genesis-selection flag yet. P2P and consensus mode are
independent: both legacy `Producers` and P2P topology can run Praos.

Implementation has synthetic tests, not a production rollout. The topology policy
is based on the Cardano 11.1.2 parser. Do not treat historical binary upgrades with
this script as validation of the new planner on every older/newer release.

Use [upgrade-cardano-node.sh](upgrade-cardano-node.sh) together with its stdlib-only
companion [upgrade-cardano-config.py](upgrade-cardano-config.py). Clone/update the
repository; downloading only the shell script is no longer sufficient. The helper
is resolved beside the script, independently of the working directory.

## Operator contract

- Run as the non-root systemd service user. `--relay` or `--bp` is mandatory;
  repeated/conflicting roles are rejected, never guessed from DNS or IP addresses.
- The service must already be active. The script checks its user, process owner,
  executable, configuration and topology paths, and forging arguments. Custom
  wrappers, stopped nodes, or ambiguous process paths fail rather than modifying
  files that might not be in use. Forging keys are **not read**.
- A node-home directory lock serializes cooperating upgrade runs. It does not
  prevent a separate editor, topology updater, or other administrator making changes.
- `--keep-config` is the default. It preserves custom settings **except**
  `ConsensusMode=PraosMode`, `EnableP2P` matched to the selected topology, and
  `PeerSharing=false` for a BP. A semantically unchanged config retains its bytes.
- `--refresh-config` explicitly replaces the configuration with the current
  Operations Book configuration, normalizes Praos/P2P, retains the selected backend,
  metrics endpoint and relay `PeerSharing` choice, and applies relay traces.
  Other custom config settings are not generally retained under refresh: inspect
  the printed semantic diff. Existing configured genesis hashes must not change.
- Compatible topology is retained **byte-for-byte**. There is no automatic conversion
  from legacy to P2P, no official topology download, no new external peers, and no
  blanket `trustable=true` changes.
- Praos conversion does not replace, rename, delete or rebuild the database.
  Backend changes require both `--refresh-config` and explicit `--fresh-db`.
  `--yes` does not authorize an implicit fresh database. The separate existing
  Mithril workflow is not a peer-snapshot workflow.
- Unknown/missing `LedgerDB.Backend` currently fails, even with refresh. No implicit
  mapping of an old config to a new database format is claimed. Review such nodes
  separately rather than selecting a backend by assumption.

### Intended use

For a mainnet relay targeting 11.1.2, pass `--network mainnet --version 11.1.2
--relay --keep-config --dry-run` to the shell script. For a BP use `--bp` instead.
Review all diffs, topology source, discovery warnings and dependency validation.
Only after approval, rerun without `--dry-run`; `--yes` suppresses ordinary prompts.

Dry-run uses actual scratch staging and validation, and may download release
binaries and, with refresh, official configuration. It creates no live backups,
installs no packages, and does not stop/start the service or change live node/DB
files. Scratch is removed on normal exit and handled failures. A kill/power loss
can leave scratch behind. Dry-run is not a promise the service can parse every
field or start successfully; startup checks remain part of activation.

Same-version runs reuse installed binaries and skip package changes when the
installation directory also matches. They still restart: on-disk equality cannot
prove that the running process loaded those bytes. Configuration-only planning is
idempotent; a runtime-proven no-restart path remains future work.

## Discovery and privacy

For a P2P BP the planner requires usable operator-defined local roots with positive
valency, no advertised local roots, no public-root access points, disabled bootstrap
peers (`null` or absent), and disabled ledger discovery (`-1` or absent). It sets
config peer sharing to false. Addresses do not establish peer ownership: operators
must still verify that their BP roots are the intended private relays.

Relays retain their local/public/bootstrap/ledger discovery choices. Important:

- Genesis ignores bootstrap peers. Switching to Praos can activate previously
  ignored bootstrap sources even when topology bytes do not change. This is printed
  as a warning, not hidden behind an “unchanged topology” claim.
- `bootstrapPeers: []` enables bootstrap behavior and needs a usable trustable local
  group; it does **not** mean the same thing as `null`. A local root is not inherently
  a trustable bootstrap root.
- Praos may use a peer snapshot. Existing snapshots are never deleted or refreshed
  by this policy. A snapshot reference with disabled ledger discovery is retained
  and reported as ignored; its file need not be opened or exist.
- Active referenced snapshots must exist and pass structural/network validation.
  Relative paths are resolved against the final live topology directory, including
  when evaluating a topology recovered from a backup.
- Snapshot validation covers network magic, protocol-number sanity bounds, point,
  stake and relay shapes. It is **not the full Haskell decoder**, a target-release
  protocol compatibility table, freshness proof, or a reachability/ownership check.
  The helper records the requested version but does not claim release-specific
  snapshot decoding. Review active-snapshot canaries before fleet use.

## Preserve-first backup recovery

Recovery happens only if current topology fails the proposed role/Praos policy or
an active dependency fails validation, or if `--topology-backup PATH` is provided.
Being configured for Genesis alone does not trigger restoration.

An eligible topology comes from an adjacent same-node `files-*-bak*` directory
containing the actual paired config and Shelley genesis. Its paired config must
explicitly say `PraosMode`; network magic and available configured genesis hashes
must agree. Conway fields, version labels, sample files and mtimes are not proof
of historical consensus mode. A paired backup is evidence of a Praos configuration,
not proof it was previously deployed.

Automatic selection preserves the **entire** current `localRoots`/`Producers`
arrays, including order, flags, valencies and custom metadata. It ranks eligible
UTC-timestamped backups and rejects differing tied or undated contenders rather
than guessing. Byte-identical contenders may be coalesced. Exclusions are printed.

If current JSON cannot establish the original roots, or peer changes are required,
automatic recovery stops. After reviewing a paired backup, supply its absolute
topology path using `--topology-backup`. That explicit selection authorizes peer-list
changes but does not waive role, network or dependency checks. Missing/unreadable
current topology, unsafe symlinks and unreadable config fail rather than being
silently overwritten. Restore only the selected topology, not its old config or
genesis directory. Current compatible topology otherwise wins over every backup.

## Activation, failure and manual recovery

1. Inventory the service; plan topology; stage binaries/config; validate genesis and
   checkpoint hashes, network magic and advertised minimum node version. The official
   config URL is moving, not version-pinned; minimum-version checking is not complete
   schema compatibility checking.
2. Recheck planning inputs and artifacts. On a real run, install required system
   packages for changed binaries, then back up current files, env and affected binaries.
   Timestamp collisions are refused, not overwritten. Package changes are not rolled back.
3. Persist `upgrade-plan.json` and `upgrade-transaction.json` in the new files backup.
   They record hashes, dependency paths, topology source, role, versions and recovery
   locations. Scratch paths in the plan are historical evidence after cleanup.
4. Recheck inputs, stop the service, confirm it is inactive, recheck again, and
   replace only changed config artifacts. Register each name in
   `upgrade-installed-files.txt` **before** per-file atomic replacement. Retain
   existing destination owner/group/mode. Config and recovered topology both join
   rollback, even under keep-config.
5. Install changed binaries, apply any required testnet env paths, and perform only
   explicitly requested database work. Start and validate the new invocation.

Handled activation failure restores the original config/topology pair (including
original Genesis settings), changed binaries, env and any renamed database. It checks
original config/topology/env hashes before restarting the previous service. Failure
to stop blocks restoration; failed restoration leaves the service stopped and reports
manual recovery required. Backups and original peer snapshots are retained.

This is **not a power-loss-atomic multi-file transaction**. SIGKILL, power loss,
uncooperative concurrent writers and hostile directory replacement cannot be made
safe by an EXIT trap. The persistent records help manual recovery:

- First stop and confirm the correct service is inactive. Do not copy over an
  active node or start a partially restored installation.
- Read the transaction record, plan and installed-file list together. A record
  proves preparation, not successful activation. Back up any later operator edits.
- Restore each listed artifact from that run's backup, or remove it only if the
  record shows it was newly introduced. Restore the original config/topology pair
  if either changed. Do not indiscriminately copy transaction metadata into live files.
- Restore the matching previous binaries and env using the recorded paths. On
  versioned testnet installations the old env can refer to an untouched old directory.
  Remove a newly introduced executable only after confirming it had no backup.
- If `--fresh-db` was explicitly requested, inspect both database directories before
  choosing recovery. Never delete a database merely because consensus changed.
- Check original hashes, permissions, binary version, service paths and network,
  then start once and inspect its invocation. Keep backups until operational checks
  pass. Leftover `.upgrade-*` temporary files are not authoritative configuration.

## Startup is not synchronization

Validation accepts the correct active executable, target-version metrics and
starting/replay/validation/slot activity. It does not wait hours for full sync or
require peers during immutable DB replay. Logs are scoped to the new systemd
invocation; unreadable/absent journal evidence is not reported as a clean journal.
Probe timestamps use real elapsed time, although individual commands and the final
tip probe may add time beyond the configured loop budget.

A positive slot is labelled running, **not synchronized**. Peers and tip are separate
PASS/PENDING observations. Config/topology hashes and service identity are checked
again before disarming rollback. Praos is verified in the installed config at the
checked startup path, not independently proven by a runtime consensus metric.

## Tests and rollout gate

- [tests/test_upgrade_cardano_config.py](tests/test_upgrade_cardano_config.py):
  63 stdlib fixture tests for topology policy, snapshots, recovery provenance,
  ambiguity, preservation, idempotence, dependency hashes and path safety.
- [tests/test_upgrade_cardano_shell.py](tests/test_upgrade_cardano_shell.py):
  mocked Bash function/section tests and full-script sandbox keep-config dry-runs.
  Covers role refusal, explicit DB permission, changed inputs, config/topology
  installation, partial failures, blocked/incomplete rollback, same-version reuse,
  genesis/checkpoint checks and invocation-scoped journal probes.
- Run unittest discovery for `test_upgrade_cardano*.py` in `Cardano/tests`, with
  `PYTHONDONTWRITEBYTECODE=1`; also run Bash syntax and Git whitespace checks.

Tests never access the real service, keys, network or database. Full-script sandbox
tests replace profile/proc boundaries and command execution; they do not certify
real systemd, release downloads, refresh compatibility, Mithril or Cardano decoding.
Before fleet deployment: review dry-runs on an already-upgraded Genesis relay, an
older supported relay and a private BP; then obtain explicit canary activation
approval. Monitor sync/peers after fast startup validation before moving onward.

## Future work: explicit Genesis option (not implemented)

- Introduce an explicit consensus choice, never an unnoticed change inherited from
  a moving official config. Define supported node/network/schema combinations.
- For **each Genesis rollout**, fetch an updated peer snapshot from a reviewed
  official source into scratch. Never silently reuse a failed or stale download.
- Validate source/provenance, network, exact release-compatible schema/protocol,
  ledger point, hash, readability and a defined freshness policy **before stopping**.
  File mtime is not snapshot freshness. Add a real decoder validation mechanism.
- Stage the snapshot at the path resolved from the proposed topology, preserve
  operator local roots, and maintain BP isolation. Define whether Genesis is
  appropriate for a BP before exposing that option.
- Back up any replaced snapshot and include it in the same install/rollback records.
  A peer snapshot is not a ledger database or a Mithril database snapshot.
- No automatic Genesis-to-Praos fallback on failure. Report the error and restore
  the previous consistent installation.
- Add runtime-proven no-op detection, version-pinned configuration provenance,
  more old-schema fixtures, full refresh/download sandbox tests and power-loss
  recovery automation before claiming broader fleet support.

## Reference sources

- [Cardano 11.1.2 P2P topology parser](https://github.com/IntersectMBO/cardano-node/blob/11.1.2/cardano-node/src/Cardano/Node/Configuration/TopologyP2P.hs)
- [Operations Book mainnet environment](https://book.world.dev.cardano.org/env-mainnet.html)
- [Current mainnet config](https://book.world.dev.cardano.org/environments/mainnet/config.json)

Defaults in older tutorials, sample filenames and moving master branches can differ
from the target release. Consult the release parser, not naming conventions.