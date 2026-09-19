"""Synthetic integration tests for the *current* upgrader's Bash code.

Named functions/sections are extracted from the current source. Full-script
dry-runs execute ONLY a temporary copy with exact, count-checked substitutions
of installation/proc paths and the root identity guard, never the live script.
All data, binaries, backups and command logs live in TemporaryDirectory. PATH is
closed: command wrappers reject unknown invocations (even failures the shell
ignores), emulate service/sudo, and permit only sandbox-scoped file operations.
The real Python planner and real local coreutils exercise hashes/atomic copies.

These are not end-to-end service, /proc, network, Mithril or Cardano decoder tests.
The CLI's Byron hash is synthetic, not Cardano's canonical genesis algorithm.
Full-script coverage uses --keep-config and same-version binary reuse; release
downloads, package installation and official refresh are deliberately denied.
Extraction/substitution fails loudly if the production structure changes.
"""

import hashlib
import json
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


CARDANO = Path(__file__).resolve().parents[1]
SHELL = CARDANO / "upgrade-cardano-node.sh"
HELPER = CARDANO / "upgrade-cardano-config.py"
BASH = shutil.which("bash")

# These wrappers never resolve commands via the host PATH. In particular there
# is no route to real sudo, systemctl, package managers, network tools or chown.
COMMAND_WRAPPER = r'''#!PYTHON
import hashlib, json, os, pathlib, sys, tempfile

root = pathlib.Path(os.environ['SANDBOX']).resolve()
tools = json.loads(os.environ['LOCAL_TOOLS'])
faults = json.loads(os.environ.get('MOCK_FAULTS', '{}'))
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / 'commands.jsonl').open('a') as log:
    log.write(json.dumps([name, *args]) + '\n')

def deny(message):
    with (root / 'forbidden').open('a') as log:
        log.write(message + '\n')
    sys.exit(97)

def path(value):
    p = pathlib.Path(value).resolve()
    if p == root or root not in p.parents:
        deny('outside sandbox: ' + value)
    return p

via_sudo = name == 'sudo'
if via_sudo:
    if not args or args[0] not in ('systemctl', 'cp', 'rm'):
        deny('unexpected sudo: ' + repr(args))
    name, args = args[0], args[1:]

if name == 'systemctl':
    state = root / 'service-state'
    if len(args) == 5 and args[:2] == ['show', '-p'] and args[3:] == [
            '--value', 'synthetic.service']:
        properties = {'ActiveState': faults.get('active_state', state.read_text()),
                      'User': 'sandbox-service-user', 'MainPID': faults.get('pid', '424242'),
                      'InvocationID': faults.get('invocation', 'a' * 32)}
        if args[2] not in properties:
            deny('unexpected systemctl property: ' + repr(args))
        if args[2] == 'ActiveState' and faults.get('show_failure'):
            sys.exit(1)
        print(properties[args[2]])
        sys.exit(0)
    if args not in ([action, 'synthetic.service'] for action in
                    ('stop', 'start', 'reset-failed', 'is-active')) and args != [
                        'is-active', '--quiet', 'synthetic.service']:
        deny('unexpected systemctl: ' + repr(args))
    action = args[0]
    if action == 'stop' and faults.get('stop_failure'):
        sys.exit(1)
    if action in ('stop', 'start'):
        state.write_text('active' if action == 'start' else 'inactive')
    elif action == 'is-active':
        active = state.read_text() == 'active'
        if '--quiet' not in args:
            print('active' if active else 'inactive')
        sys.exit(0 if active else 3)
    sys.exit(0)
elif name == 'python3':
    if not args or args[0] not in ('-', str(root / 'planner.py'),
                                 str(root / 'upgrade-cardano-config.py')):
        deny('unexpected Python program: ' + repr(args))
    os.execv(sys.executable, [sys.executable, *args])
elif name in ('cardano-node', 'cardano-cli'):
    path(sys.argv[0])
    if args == ['--version']:
        print(name + ' 11.1.2 synthetic')
    elif name == 'cardano-cli' and len(args) == 5 and args[:4] == [
            'byron', 'genesis', 'print-genesis-hash', '--genesis-json']:
        print(hashlib.blake2b(path(args[4]).read_bytes(), digest_size=32).hexdigest())
    else:
        deny('unexpected binary invocation: ' + repr(args))
    sys.exit(0)
elif name in ('cp', 'mv', 'rm', 'cmp', 'mkdir', 'sha256sum', 'basename', 'dirname', 'readlink'):
    allowed = {'cp': {'-a', '--'}, 'mv': {'-f', '--'},
               'rm': {'-f', '-rf', '--'}, 'cmp': {'-s'},
               'mkdir': {'-p'}, 'sha256sum': set(), 'basename': {'--'},
               'dirname': {'--'}, 'readlink': {'-f', '--'}}[name]
    for value in args:
        if value.startswith('-'):
            if value not in allowed:
                deny('unexpected option: ' + name + ' ' + value)
        else:
            path(value)
    if name == 'cp' and via_sudo and faults.get('restore_failure'):
        if args == ['-a', str(root / 'node/files-11.1.2-bak-20260918T010203Z/config.json'),
                    str(root / 'node/files/config.json')]:
            sys.exit(74)
    # Fail AFTER a short write of the second installation's temporary file.
    # The first file was already installed, and both must be tracked/restored.
    if (name == 'cp' and os.environ.get('FAIL_TOPOLOGY_COPY') == '1'
            and len(args) == 3
            and args[:2] == ['--', str(root / 'work/final-plan/topology.json')]):
        path(args[-1]).write_bytes(b'partial copy')
        sys.exit(73)
elif name == 'install':
    if len(args) != 4 or args[:2] != ['-m', '0755']:
        deny('unexpected install: ' + repr(args))
    path(args[2]); path(args[3])
elif name in ('chmod', 'chown'):
    if len(args) != 2:
        deny('unexpected mode/owner operation: ' + repr(args))
    if args[0].startswith('--reference='):
        path(args[0].split('=', 1)[1])
    elif name != 'chmod' or args[0] != '0644':
        deny('unexpected mode/owner option: ' + repr(args))
    path(args[1])
    if name == 'chown':
        sys.exit(0)  # No ownership changes, even inside the sandbox.
elif name == 'mktemp':
    if args == ['-d']:
        print(tempfile.mkdtemp(prefix='full-script-', dir=path(os.environ['TMPDIR'])))
        sys.exit(0)
    if len(args) != 1 or 'XXXXXX' not in args[0]:
        deny('unexpected mktemp: ' + repr(args))
    path(args[0])
elif name == 'find':
    if args[1:] not in (['-maxdepth', '1', '-type', 'f', '-print0'],
                       ['-maxdepth', '1', '-type', 'f', '!', '-name', 'config.json', '-print0']):
        deny('unexpected find: ' + repr(args))
    path(args[0])
elif name == 'awk':
    if args not in (["{print $1}"], ["{print $2}"], ["{print $(NF-1)}"], ["{print $NF}"],
                   ['/cardano_node_metrics_cardano_build_info/ && match($0, /version="[^"]+"/) { print substr($0, RSTART + 9, RLENGTH - 10); exit }'],
                   ['$1 == "cardano_node_metrics_peerSelection_ActivePeers_int" { print int($2); exit }'],
                   ['$1 == "cardano_node_metrics_slotNum_int" { print int($2); exit }'],
                   ['match($0, /Progress: [0-9.]+%/) { print substr($0, RSTART, RLENGTH) }']):
        deny('unexpected awk: ' + repr(args))
elif name in ('head', 'tail'):
    if args != ['-1']:
        deny('unexpected head/tail: ' + repr(args))
elif name == 'grep':
    if args not in (
        ['-Ei', r'(\((Error|Critical|Alert|Emergency),|(^|[^[:alpha:]])(fatal|panic)([^[:alpha:]]|$)|uncaught exception)'],
        ['-Ev', r'Net\.PeerSelection\.Actions\.(ConnectionError|StatusChangeFailure)'],
        ['-E', r'LedgerReplay|ChainDB\.ImmDbEvent\.ChunkValidation']):
        deny('unexpected grep: ' + repr(args))
elif name == 'journalctl':
    base = ['-q', '-u', 'synthetic.service', '_SYSTEMD_INVOCATION_ID=' + 'a' * 32,
            '--since', '2026-09-18T01:02:03+00:00']
    priority = args == base + ['-p', 'emerg..err', '--no-hostname', '--no-pager']
    if not priority and args != base + ['--no-hostname', '--no-pager']:
        deny('unexpected journalctl: ' + repr(args))
    if faults.get('journal_failure') == ('priority' if priority else 'general'):
        sys.exit(1)
    # Simulate an old invocation having errors: it must never be requested.
    print(faults.get('priority_text', '') if priority else
          faults.get('journal_text', 'ChainDB startup: new invocation'))
    sys.exit(0)
elif name == 'curl':
    if args != ['-sf', '--max-time', '5', 'http://localhost:12345/metrics']:
        deny('network access forbidden: ' + repr(args))
    print('cardano_node_metrics_cardano_build_info{version="11.1.2"} 1\n'
          'cardano_node_metrics_peerSelection_ActivePeers_int 2\n'
          'cardano_node_metrics_slotNum_int 123')
    sys.exit(0)
elif name == 'jq':
    if len(args) != 3 or args[0] not in ('-r', '-e'):
        deny('unexpected jq arguments: ' + repr(args))
    data = json.loads(path(args[2]).read_text())
    query = args[1]
    fields = {'.' + key: key for key in ('topology_p2p', 'topology_after_sha256',
              'config_before_sha256', 'topology_before_sha256',
              'decision', 'snapshot_status', 'ByronGenesisFile', 'ByronGenesisHash')}
    if query in fields and args[0] == '-r':
        value = data[fields[query]]
    elif query == '.LedgerDB.Backend // empty' and args[0] == '-r':
        value = data.get('LedgerDB', {}).get('Backend', '')
    elif query == '.TraceOptions."".backends[]? | select(startswith("PrometheusSimple"))' and args[0] == '-r':
        value = '\n'.join(b for b in data.get('TraceOptions', {}).get('', {}).get('backends', [])
                          if b.startswith('PrometheusSimple'))
    elif query == '.TraceOptions."".backends | type == "array"' and args[0] == '-e':
        value = isinstance(data.get('TraceOptions', {}).get('', {}).get('backends'), list)
    elif query == '.LedgerDB.Backend == "V2InMemory" or .LedgerDB.Backend == "V2LSM"' and args[0] == '-e':
        value = data.get('LedgerDB', {}).get('Backend') in ('V2InMemory', 'V2LSM')
    elif query == '.LedgerDB.Backend == "V2InMemory"' and args[0] == '-e':
        value = data.get('LedgerDB', {}).get('Backend') == 'V2InMemory'
    elif query.strip() == """
    . as $config
    |
    ["TurnOnLogging", "TurnOnLogMetrics", "UseTraceDispatcher"]
    | map(select(. as $key | $config | has($key)))
    | join(", ")
    """.strip() and args[0] == '-r':
        value = ', '.join(k for k in ('TurnOnLogging', 'TurnOnLogMetrics', 'UseTraceDispatcher') if k in data)
    else:
        deny('unexpected jq query: ' + repr(args))
    print(json.dumps(value) if isinstance(value, bool) else value)
    sys.exit(1 if args[0] == '-e' and value is False else 0)
elif name == 'sed':
    allowed = [r"""s|^%s=["']\{0,1\}\([^"' #]*\).*$|\1|p""" % key
               for key in ('PROM_HOST', 'PROM_PORT')]
    if len(args) != 3 or args[0] != '-n' or args[1] not in allowed:
        deny('unexpected sed: ' + repr(args))
    path(args[2])
elif name == 'id':
    if args not in (['-un'], ['-u']):
        deny('unexpected identity probe: ' + repr(args))
    print('sandbox-service-user' if args == ['-un'] else '1000')
    sys.exit(0)
elif name == 'uname':
    if args != ['-m']:
        deny('unexpected uname: ' + repr(args))
    print('x86_64')
    sys.exit(0)
elif name == 'flock':
    if len(args) != 2 or args[0] != '-n' or not args[1].isdigit():
        deny('unexpected flock: ' + repr(args))
    sys.exit(0)  # Lock semantics/concurrency are outside this sandbox's scope.
elif name == 'sort':
    if args != ['-V', '-C']:
        deny('unexpected sort: ' + repr(args))
elif name == 'date':
    if args != ['-u', '+%Y%m%dT%H%M%SZ']:
        deny('unexpected date: ' + repr(args))
    print('20260918T010203Z')
    sys.exit(0)
else:
    deny('forbidden external command: ' + name + ' ' + repr(args))

os.execv(tools[name], [tools[name], *args])
'''


def section(text, start, end):
    """Use semantic markers, not line numbers; never silently run extra code."""
    if text.count(start) != 1 or text.count(end) != 1:
        raise AssertionError(f"Shell section markers changed: {start!r}, {end!r}")
    result = text.split(start, 1)[1].split(end, 1)[0]
    if end not in text.split(start, 1)[1]:
        raise AssertionError("Shell section markers out of order")
    return result


def function(text, name):
    # Selected functions end at a column-zero brace. Their Python heredocs do
    # not contain such a brace; bash -n below also checks extracted definitions.
    matches = list(re.finditer(rf"^{re.escape(name)}\(\)\s*\{{.*?^\}}\s*$",
                               text, re.MULTILINE | re.DOTALL))
    if len(matches) != 1:
        raise AssertionError(f"Shell function structure changed: {name}")
    return matches[0].group(0)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ShellIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if BASH is None:
            raise unittest.SkipTest("Bash is required")
        # Read once per run: another editor may be updating the production file.
        cls.shell = SHELL.read_text()
        cls.tools = {}
        for name in ('cp', 'mv', 'rm', 'cmp', 'mkdir', 'sha256sum', 'basename',
                 'dirname', 'readlink', 'sed', 'grep', 'tail',
                 'install', 'chmod', 'mktemp', 'find', 'awk', 'head', 'sort'):
            executable = shutil.which(name)
            if executable is None:
                raise unittest.SkipTest(f"Local coreutils prerequisite missing: {name}")
            cls.tools[name] = executable
        names = ('cleanup_workspace', 'rollback_on_exit', 'verify_plan_inputs',
                 'install_config_file', 'prepare_activation', 'set_env_value',
                 'remove_legacy_tracer_keys',
                 'version_at_least', 'read_env_path', 'infer_custom_binary_dir',
                 'validate_custom_binary_target', 'classify_custom_binary_target',
                 'snapshot_custom_binary_target', 'install_custom_binaries',
                 'verify_service_process')
        logging = []
        for name in ('info', 'warn', 'error'):
            match = re.search(rf'^{name}\(\).*$', cls.shell, re.MULTILINE)
            if match is None:
                raise AssertionError(f"Missing shell logger {name}")
            logging.append(match.group(0))
        cls.definitions = '\n'.join(logging + [function(cls.shell, n) for n in names])
        checked = subprocess.run([BASH, '--noprofile', '--norc', '-n'],
                                 input=cls.definitions, text=True, capture_output=True,
                                 env={'PATH': '', 'LC_ALL': 'C'}, timeout=10)
        if checked.returncode:
            raise AssertionError(checked.stderr)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='cardano-shell-test-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.files = self.root / 'node/files'
        self.env_file = self.root / 'node/scripts/env'
        self.db = self.root / 'node/db'
        self.work = self.root / 'work'
        self.plan = self.work / 'final-plan'
        self.stage = self.work / 'config-stage'
        self.active = self.root / 'home/bin'
        self.staged_bin = self.work / 'binaries'
        self.bin = self.root / 'commands'
        for directory in (self.files, self.env_file.parent, self.db, self.stage,
                          self.active, self.staged_bin, self.bin):
            directory.mkdir(parents=True, exist_ok=True)
        self.write(self.env_file, b'PROM_PORT="12345"\n# synthetic Guild env\n')
        self.write(self.db / 'immutable/chunk', b'synthetic database; never replace implicitly')
        self.write(self.root / 'service-state', b'active')
        genesis = self.write(self.files / 'shelley-genesis.json', {'networkMagic': 42})
        self.config = {'ConsensusMode': 'GenesisMode', 'EnableP2P': True,
                       'LedgerDB': {'Backend': 'V2InMemory'},
                       'ShelleyGenesisFile': 'shelley-genesis.json',
                       'ShelleyGenesisHash': hashlib.blake2b(genesis, digest_size=32).hexdigest()}
        self.write(self.files / 'config.json', self.config)
        self.write(self.stage / 'config.json', self.config)
        self.topology = {
            'localRoots': [{'accessPoints': [{'address': 'original.example', 'port': 3001}],
                            'valency': 1, 'advertise': False}],
            'publicRoots': [], 'bootstrapPeers': None, 'useLedgerAfterSlot': 0,
            'peerSnapshotFile': 'snapshot.json'}
        self.write(self.files / 'topology.json', self.topology)
        self.write(self.files / 'snapshot.json', {
            'NetworkMagic': 42, 'NodeToClientVersion': 23,
            'Point': {'blockPointSlot': 1, 'blockPointHash': 'ab' * 32},
            'bigLedgerPools': [{'accumulatedStake': 1, 'relativeStake': 1,
                               'relays': [{'address': 'snapshot.example', 'port': 3001}]}]})
        self.backup = self.files.parent / 'files-10.0.0-bak-20260917T010203Z'
        self.write(self.backup / 'config.json', {**self.config, 'ConsensusMode': 'PraosMode'})
        self.write(self.backup / 'shelley-genesis.json', genesis)
        recovered = json.loads(json.dumps(self.topology))
        recovered['localRoots'][0]['accessPoints'][0]['address'] = 'reviewed.example'
        self.write(self.backup / 'topology.json', recovered)
        self.write(self.root / 'planner.py', HELPER.read_bytes())
        self.write(self.root / 'definitions.sh', self.definitions.encode())
        wrapper = COMMAND_WRAPPER.replace('#!PYTHON', '#!' + sys.executable, 1)
        for name in (*self.tools, 'python3', 'sudo', 'systemctl', 'chown', 'date',
                     'curl', 'wget', 'apt-get', 'dpkg', 'journalctl', 'sleep',
                     'jq', 'flock', 'timeout', 'id', 'uname'):
            path = self.bin / name
            self.write(path, wrapper.encode())
            path.chmod(0o755)
        for name in ('cardano-node', 'cardano-cli'):
            binary = self.active / name
            self.write(binary, wrapper.encode())
            binary.chmod(0o755)
        self.globals = {
            'RED': '', 'GREEN': '', 'YELLOW': '', 'CYAN': '', 'NC': '',
            'WORK_DIR': str(self.work), 'PLAN_DIR': str(self.plan),
            'FILES_DIR': str(self.files), 'CONFIG_STAGE_DIR': str(self.stage),
            'TOPOLOGY_FILE': str(self.files / 'topology.json'),
            'ENV_FILE': str(self.env_file), 'DB_DIR': str(self.db),
            'ACTIVE_BIN_DIR': str(self.active), 'STAGED_BIN_DIR': str(self.staged_bin),
            'BACKUP_BIN_DIR': str(self.root / 'home/backup-bin'),
            'CONFIG_PLANNER': str(self.root / 'planner.py'),
            'SERVICE_NAME': 'synthetic.service', 'NETWORK': 'mainnet',
              'BACKUP_SCOPE': 'mainnet', 'BINARY_DESTINATION_SOURCE': 'standard',
              'TARGET_BINARY_DISPOSITION': 'standard', 'TARGET_BINARY_STATE_BEFORE': 'standard',
            'EXPECTED_NETWORK_MAGIC': '42', 'PROM_PORT': '12345',
            'TARGET_VERSION': '11.1.2', 'CURRENT_VERSION': '11.1.2',
            'CURRENT_NODE_BIN': str(self.active / 'cardano-node'),
            'CURRENT_CLI_BIN': str(self.active / 'cardano-cli'),
              'CURRENT_NODE_HASH_BEFORE': digest(self.active / 'cardano-node'),
              'CURRENT_CLI_HASH_BEFORE': digest(self.active / 'cardano-cli'),
            'CONFIG_HASH_BEFORE': digest(self.files / 'config.json'),
            'TOPOLOGY_HASH_BEFORE': digest(self.files / 'topology.json'),
            'ENV_HASH_BEFORE': digest(self.env_file), 'INITIAL_PID': '424242',
            'CURRENT_BACKEND': 'V2InMemory', 'LEDGER_BACKEND': 'V2InMemory',
            'LEDGER_BACKEND_EXPLICIT': 'false', 'KEEP_CONFIG': 'true',
            'NODE_ROLE': 'relay', 'DRY_RUN': 'false', 'FRESH_DB': 'false',
              'CUSTOM_INSTANCE': 'false',
            'ASSUME_YES': 'true', 'CUSTOM_URL': '', 'REUSE_INSTALLED_BINARIES': 'true',
            'ROLLBACK_ARMED': 'false', 'NODE_WAS_ACTIVE': 'false',
            'BINARY_BACKUP_DIR': '', 'DB_BACKUP': '', 'ENV_CHANGED': 'false',
            'BINARY_CHANGED': 'false', 'BACKUP_SUFFIX': 'synthetic-bak',
        }

    def write(self, path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        data = value if isinstance(value, bytes) else (json.dumps(value) + '\n').encode()
        path.write_bytes(data)
        return data

    def inventory(self, *directories):
        """Include modes, inode and mtime: identical rewrites are mutations too."""
        result = {}
        for directory in directories:
            for path in (directory, *sorted(directory.rglob('*'))):
                stat = path.stat()
                result[str(path)] = (path.read_bytes() if path.is_file() else None,
                                     stat.st_ino, stat.st_mode, stat.st_mtime_ns)
        return result

    def commands(self):
        log = self.root / 'commands.jsonl'
        return [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []

    def sandbox_env(self, fail_copy=False, faults=None):
        return {'PATH': str(self.bin), 'HOME': str(self.root / 'home'),
                'TMPDIR': str(self.work), 'SANDBOX': str(self.root),
                  'PROC_ROOT': str(self.root / 'proc'),
                'SANDBOX_IDENTITY': 'service-user',
                'LOCAL_TOOLS': json.dumps(self.tools), 'LC_ALL': 'C',
                'PYTHONDONTWRITEBYTECODE': '1', 'FAIL_TOPOLOGY_COPY': str(int(fail_copy)),
                'MOCK_FAULTS': json.dumps(faults or {})}

    def check_result(self, result, expected):
        forbidden = self.root / 'forbidden'
        self.assertFalse(forbidden.exists(), forbidden.read_text() if forbidden.exists() else '')
        output = result.stdout + result.stderr
        if expected is None:
            self.assertNotEqual(result.returncode, 0, output)
        else:
            self.assertEqual(result.returncode, expected, output)
        return output

    def run_shell(self, body, args=(), expected=0, overrides=None, fail_copy=False, faults=None):
        values = {**self.globals, **(overrides or {})}
        prelude = 'set -euo pipefail\n'
        prelude += '\n'.join(f'{key}={shlex.quote(value)}' for key, value in values.items())
        prelude += '\ndeclare -a CONFIG_INSTALLED_FILES=()\n'
        prelude += 'command_not_found_handle() { printf "%s\\n" "$*" >> "$SANDBOX/forbidden"; return 97; }\n'
        prelude += f'source {shlex.quote(str(self.root / "definitions.sh"))}\n'
        result = subprocess.run([BASH, '--noprofile', '--norc', '-c', prelude + body,
                                 'synthetic-upgrade', *args], cwd=self.root,
                                env=self.sandbox_env(fail_copy, faults),
                                text=True, capture_output=True, timeout=30)
        return self.check_result(result, expected)

    def make_plans(self):
        # Produce both manifests through the real CLI, not hand-written hashes.
        self.run_shell('''
for phase in initial-plan final-plan; do
  input="${FILES_DIR}/config.json"
  [[ "$phase" != final-plan ]] || input="${CONFIG_STAGE_DIR}/config.json"
  python3 "$CONFIG_PLANNER" --files-dir "$FILES_DIR" --config "$input" \
    --role relay --network-magic 42 --target-version "$TARGET_VERSION" \
    --topology-backup "$FILES_DIR/../files-10.0.0-bak-20260917T010203Z/topology.json" \
    --output-dir "$WORK_DIR/$phase"
done
''')
        self.write(self.work / 'network-dependencies.json', {
            str(self.files / 'shelley-genesis.json'): digest(self.files / 'shelley-genesis.json')})

    def argument_section(self):
        return section(self.shell, '# --- Parse arguments', '[[ "${EUID}" -ne 0 ]]').split('\n', 1)[1]

    def backend_section(self):
        return section(self.shell, '# --- Choose LedgerDB backend',
                       '# --- Step 0: Download staged binaries').split('\n', 1)[1]

    def install_pair(self):
        start = 'while IFS= read -r -d \'\' config_file; do'
        return start + section(self.shell, start, 'TOPOLOGY_HASH_AFTER=')

    def dry_run_gate(self):
        start = 'verify_plan_inputs || error "Inputs changed; refusing to overwrite concurrent changes"'
        return start + section(self.shell, start, '# --- Step 5: Stop the node')

    def backup_setup(self):
        return 'prepare_activation\nverify_plan_inputs\n'

    def test_role_is_required_even_with_yes_or_dry_run(self):
        before = self.inventory(self.root / 'node', self.root / 'home')
        for args in ((), ('--yes',), ('--dry-run', '--version', '11.1.2')):
            with self.subTest(args=args):
                output = self.run_shell(self.argument_section(), args, expected=None)
                self.assertIn('Specify --relay or --bp', output)
        self.assertEqual(before, self.inventory(self.root / 'node', self.root / 'home'))
        self.assertEqual(self.commands(), [])

    def test_conflicting_or_repeated_roles_are_refused(self):
        for args in (('--bp', '--relay'), ('--relay', '--bp'),
                     ('--bp', '--bp'), ('--relay', '--relay')):
            with self.subTest(args=args):
                self.assertIn('exactly one', self.run_shell(self.argument_section(), args, expected=None))
        self.assertEqual(self.commands(), [])

    def test_each_explicit_role_is_accepted(self):
        for role in ('bp', 'relay'):
            with self.subTest(role=role):
                self.run_shell(self.argument_section() + f'\n[[ "$NODE_ROLE" == {role} ]]', ['--' + role])

    def test_custom_only_flags_require_node_home(self):
        for args in (('--service', 'lgc.service'), ('--binary-dir', '/home/test/cardano/bin')):
            with self.subTest(args=args):
                output = self.run_shell(self.argument_section(), ('--bp', *args), expected=None)
                self.assertIn('only valid with --node-home', output)

    def test_custom_instance_arguments_are_parsed(self):
        self.run_shell(self.argument_section() + '''
[[ "$NODE_HOME_OVERRIDE" == /opt/cardano/lgc ]]
[[ "$SERVICE_OVERRIDE" == lgc.service ]]
[[ "$BINARY_DIR_OVERRIDE" == /home/test/cardano-11.1.2/bin ]]
''', ('--bp', '--node-home', '/opt/cardano/lgc', '--service', 'lgc.service',
      '--binary-dir', '/home/test/cardano-11.1.2/bin'))

    def test_custom_binary_path_is_read_and_versioned_sibling_is_inferred(self):
        current = self.root / 'home/tmp/cardano-11.0.1/bin/cardano-node'
        self.write(self.env_file, f'CNODEBIN="{current}"  # active Guild binary\n'.encode())
        output = self.run_shell('''
current=$(read_env_path CNODEBIN)
[[ "$current" == "$EXPECTED_CURRENT" ]]
infer_custom_binary_dir "$current" 11.0.1 11.1.2 ""
''', overrides={'CNODE_HOME': str(self.root / 'node'),
                 'EXPECTED_CURRENT': str(current)})
        self.assertEqual(output.strip(), str(self.root / 'home/tmp/cardano-11.1.2/bin'))

    def test_env_path_ignores_nested_runtime_fallbacks_but_rejects_duplicate_overrides(self):
        current = self.root / 'home/tmp/cardano-11.0.1/bin/cardano-node'
        self.write(self.env_file, f'''CNODEBIN="{current}"  # operator override
if [[ -z "${{CNODEBIN}}" ]]; then
  CNODEBIN=$(command -v cardano-node)
fi
'''.encode())
        output = self.run_shell('read_env_path CNODEBIN')
        self.assertEqual(output.strip(), str(current))

        self.write(self.env_file, f'CNODEBIN="{current}"\nCNODEBIN="{current}"\n'.encode())
        output = self.run_shell('read_env_path CNODEBIN', expected=None)
        self.assertIn('Duplicate active CNODEBIN assignments', output)

    def test_atomic_env_update_preserves_inline_comment(self):
        self.write(self.env_file, b'''if [[ -z "${CNODEBIN}" ]]; then
      CNODEBIN=$(command -v cardano-node)
fi
CNODEBIN="/old/cardano-node"  # operator note
OTHER=value
''')
        self.run_shell('set_env_value "$ENV_FILE" CNODEBIN /new/cardano-node')
        self.assertEqual(self.env_file.read_text(), '''if [[ -z "${CNODEBIN}" ]]; then
      CNODEBIN=$(command -v cardano-node)
fi
CNODEBIN="/new/cardano-node"  # operator note
OTHER=value
''')

        self.write(self.env_file, b'CNODEBIN="/one/cardano-node"\nCNODEBIN="/two/cardano-node"\n')
        before = self.env_file.read_bytes()
        output = self.run_shell('set_env_value "$ENV_FILE" CNODEBIN /new/cardano-node', expected=None)
        self.assertIn('Duplicate active CNODEBIN assignments', output)
        self.assertEqual(self.env_file.read_bytes(), before)

    def test_legacy_tracer_cleanup_changes_only_configs_containing_legacy_keys(self):
        before = self.inventory(self.files)
        self.run_shell('remove_legacy_tracer_keys "$FILES_DIR/config.json"')
        self.assertEqual(before, self.inventory(self.files))

        config = json.loads((self.files / 'config.json').read_text())
        config.update({'TurnOnLogging': True, 'TurnOnLogMetrics': True,
                   'UseTraceDispatcher': True, 'CustomSetting': 'preserved'})
        self.write(self.files / 'config.json', config)
        self.run_shell('remove_legacy_tracer_keys "$FILES_DIR/config.json"')
        cleaned = json.loads((self.files / 'config.json').read_text())
        self.assertEqual(cleaned['CustomSetting'], 'preserved')
        for key in ('TurnOnLogging', 'TurnOnLogMetrics', 'UseTraceDispatcher'):
            self.assertNotIn(key, cleaned)

    def test_custom_binary_path_rejects_shared_local_bin(self):
        output = self.run_shell(
            'infer_custom_binary_dir "$CURRENT_NODE_BIN" 11.0.1 11.1.2 "$HOME/.local/bin"',
            expected=None, overrides={'CNODE_HOME': str(self.root / 'node')})
        self.assertIn('may not target shared binary directory', output)

    def test_custom_target_rejects_unrelated_live_process(self):
        target = self.root / 'home/tmp/cardano-11.1.2/bin'
        target.mkdir(parents=True)
        process = self.root / 'proc/99'
        process.mkdir(parents=True)
        (process / 'exe').symlink_to(target / 'cardano-node')
        self.write(target / 'cardano-node', b'binary')
        output = self.run_shell(
            'validate_custom_binary_target "$TARGET" 424242 "$PROC_ROOT"', expected=None,
            overrides={'TARGET': str(target), 'PROC_ROOT': str(self.root / 'proc')})
        self.assertIn('Unrelated live process 99', output)

    def test_custom_target_reuses_only_exact_staged_package(self):
        target = self.root / 'home/tmp/cardano-11.1.2/bin'
        target.mkdir(parents=True)
        for name in ('cardano-node', 'cardano-cli'):
            data = (name + '-11.1.2').encode()
            self.write(self.staged_bin / name, data)
            self.write(target / name, data)
        output = self.run_shell('classify_custom_binary_target "$TARGET" "$STAGED_BIN_DIR"',
                                overrides={'TARGET': str(target)})
        self.assertEqual(output.strip(), 'reuse')
        self.write(target / 'unexpected', b'conflict')
        output = self.run_shell('classify_custom_binary_target "$TARGET" "$STAGED_BIN_DIR"',
                                expected=None, overrides={'TARGET': str(target)})
        self.assertIn('does not exactly match', output)

    def test_custom_install_refuses_symlink_target_without_touching_destination(self):
        target = self.root / 'home/tmp/cardano-11.1.2/bin'
        destination = self.root / 'home/.local/bin'
        destination.mkdir(parents=True)
        target.parent.mkdir(parents=True)
        target.symlink_to(destination, target_is_directory=True)
        self.write(destination / 'cardano-node', b'apex sentinel')
        self.write(self.staged_bin / 'cardano-node', b'new node')
        output = self.run_shell('install_custom_binaries "$TARGET" "$STAGED_BIN_DIR"',
                                expected=None, overrides={'TARGET': str(target)})
        self.assertTrue(output.strip())
        self.assertEqual((destination / 'cardano-node').read_bytes(), b'apex sentinel')

    def test_yes_does_not_authorize_backend_database_replacement(self):
        before = self.inventory(self.db)
        output = self.run_shell(self.argument_section() + self.backend_section(),
                                ['--relay', '--refresh-config', '--ledger-backend', 'V2LSM', '--yes'],
                                expected=None)
        self.assertIn('explicit --fresh-db', output)
        self.assertEqual(before, self.inventory(self.db))
        self.assertEqual(self.commands(), [])

    def test_explicit_fresh_db_authorizes_backend_change(self):
        self.run_shell(self.argument_section() + self.backend_section() +
                       '\n[[ "$FRESH_DB" == true && "$LEDGER_BACKEND" == V2LSM ]]',
                       ['--relay', '--refresh-config', '--ledger-backend', 'V2LSM', '--fresh-db', '--yes'])

    def test_keep_config_refuses_backend_change_even_with_fresh_db(self):
        output = self.run_shell(self.backend_section(), expected=None, overrides={
            'FRESH_DB': 'true', 'LEDGER_BACKEND': 'V2LSM', 'LEDGER_BACKEND_EXPLICIT': 'true'})
        self.assertIn('requires --refresh-config', output)

    def test_bp_refuses_lsm_even_with_explicit_database_permission(self):
        output = self.run_shell(self.backend_section(), expected=None, overrides={
            'NODE_ROLE': 'bp', 'KEEP_CONFIG': 'false', 'FRESH_DB': 'true',
            'LEDGER_BACKEND': 'V2LSM', 'LEDGER_BACKEND_EXPLICIT': 'true'})
        self.assertIn('Block producers require', output)

    def test_default_database_branch_preserves_all_bytes(self):
        body = section(self.shell, '# --- Step 7: Handle database',
                       '# --- Step 8: Start the node').split('\n', 1)[1]
        before = self.inventory(self.db)
        for current in ('10.0.0', '11.1.2'):
            with self.subTest(current=current):
                self.run_shell(self.argument_section() + self.backend_section() + body,
                               ['--relay', '--version', '11.1.2', '--yes'],
                               overrides={'CURRENT_VERSION': current})
        self.assertEqual(before, self.inventory(self.db))
        self.assertEqual(self.commands(), [])

    def test_unmodified_real_plans_validate(self):
        self.make_plans()
        self.run_shell('verify_plan_inputs')

    def test_changed_planner_dependencies_are_refused(self):
        self.make_plans()
        metadata = json.loads((self.plan / 'plan.json').read_text())
        self.assertIn(str(self.files / 'snapshot.json'), metadata['dependencies'])
        for filename in metadata['dependencies']:
            with self.subTest(filename=Path(filename).name, directory=Path(filename).parent.name):
                path = Path(filename)
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b'\n')
                    self.assertIn('Input changed since planning',
                                  self.run_shell('verify_plan_inputs', expected=None))
                finally:
                    path.write_bytes(original)

    def test_changed_staged_artifacts_are_refused(self):
        self.make_plans()
        for phase in ('initial-plan', 'final-plan'):
            for name in ('config.json', 'topology.json'):
                with self.subTest(phase=phase, name=name):
                    path = self.work / phase / name
                    original = path.read_bytes()
                    try:
                        path.write_bytes(original + b'\n')
                        self.assertIn('Staged artifact changed',
                                      self.run_shell('verify_plan_inputs', expected=None))
                    finally:
                        path.write_bytes(original)

    def test_changed_network_dependency_is_refused(self):
        self.make_plans()
        network_only = self.files / 'alonzo-genesis.json'
        self.write(network_only, {'synthetic': True})
        self.write(self.work / 'network-dependencies.json', {str(network_only): digest(network_only)})
        network_only.write_bytes(b'changed')
        self.assertIn('Network dependency changed', self.run_shell('verify_plan_inputs', expected=None))

    def test_changed_environment_is_refused(self):
        self.make_plans()
        self.env_file.write_bytes(b'PROM_PORT="9999"\n')
        self.assertIn('Guild env changed', self.run_shell('verify_plan_inputs', expected=None))

    def test_missing_input_is_refused(self):
        self.make_plans()
        (self.files / 'snapshot.json').unlink()
        self.assertIn('FileNotFoundError', self.run_shell('verify_plan_inputs', expected=None))

    def test_dry_run_exits_before_backup_or_service_mutation(self):
        before = self.inventory(self.root / 'node', self.root / 'home')
        self.make_plans()
        # The actual dry-run exit plus the following activation calls are kept
        # together: losing/moving the exit must fail, not turn into a vacuous test.
        gate = self.dry_run_gate()
        # jq is intentionally not generally available: this gate only reads
        # informational manifest fields, so use a strict, read-only shell mock.
        jq = '''reject_jq() { printf '%s\\n' 'unexpected jq invocation' >> "$SANDBOX/forbidden"; return 97; }
jq() {
  [[ "$#" == 3 && "$1" == -r && "$3" == "$PLAN_DIR/plan.json" ]] || { reject_jq; return 97; }
  case "$2" in
    .topology_after_sha256) printf '%s\\n' "$TOPOLOGY_HASH_EXPECTED" ;;
    .decision) printf '%s\\n' explicit-backup ;;
    .snapshot_status) printf '%s\\n' validated-structural ;;
    *) reject_jq ;;
  esac
}
'''
        expected_hash = digest(self.plan / 'topology.json')
        output = self.run_shell(jq + gate + '\nexit 99', overrides={
            'DRY_RUN': 'true', 'TOPOLOGY_HASH_EXPECTED': expected_hash})
        self.assertIn('Dry run passed', output)
        self.assertEqual(before, self.inventory(self.root / 'node', self.root / 'home'))
        self.assertFalse(any(c[0] in ('sudo', 'systemctl', 'install', 'cp', 'mkdir', 'curl')
                             for c in self.commands()))

    def test_dry_run_rejects_changed_inputs_before_activation(self):
        self.make_plans()
        self.env_file.write_bytes(b'concurrent env edit')
        before = self.inventory(self.root / 'node', self.root / 'home')
        gate = self.dry_run_gate()
        output = self.run_shell(gate, expected=None, overrides={'DRY_RUN': 'true'})
        self.assertIn('Inputs changed', output)
        self.assertEqual(before, self.inventory(self.root / 'node', self.root / 'home'))

    def test_changed_current_binary_is_refused_before_activation(self):
        self.make_plans()
        (self.active / 'cardano-node').write_bytes(b'concurrent binary replacement')
        output = self.run_shell('verify_plan_inputs', expected=None)
        self.assertIn('Current cardano-node changed since planning', output)

    def test_changed_config_and_topology_are_both_installed(self):
        self.make_plans()
        originals = [(self.files / n).read_bytes() for n in ('config.json', 'topology.json')]
        self.run_shell(self.backup_setup() + self.install_pair())
        for name, original in zip(('config.json', 'topology.json'), originals):
            self.assertNotEqual(original, (self.files / name).read_bytes())
            self.assertEqual((self.plan / name).read_bytes(), (self.files / name).read_bytes())
        backup = self.files.parent / 'files-11.1.2-bak-20260918T010203Z'
        self.assertEqual((backup / 'upgrade-installed-files.txt').read_text().splitlines(),
                         ['config.json', 'topology.json'])
        for name, original in zip(('config.json', 'topology.json'), originals):
            self.assertEqual((backup / name).read_bytes(), original)

    def rollback_body(self):
        return self.backup_setup() + '''
ROLLBACK_ARMED=true
trap rollback_on_exit EXIT
''' + self.install_pair() + '\nexit 42\n'

    def assert_original_pair(self, original):
        for name, (data, mode) in original.items():
            path = self.files / name
            self.assertEqual(path.read_bytes(), data)
            self.assertEqual(path.stat().st_mode, mode)

    def original_pair(self):
        (self.files / 'config.json').chmod(0o640)
        (self.files / 'topology.json').chmod(0o600)
        return {name: ((self.files / name).read_bytes(), (self.files / name).stat().st_mode)
                for name in ('config.json', 'topology.json')}

    def test_activation_failure_restores_original_pair_and_active_service(self):
        self.make_plans()
        original = self.original_pair()
        db_before = self.inventory(self.db)
        output = self.run_shell(self.rollback_body(), expected=42,
                                overrides={'NODE_WAS_ACTIVE': 'true'})
        self.assertIn('Rollback completed', output)
        self.assertNotIn('ROLLBACK INCOMPLETE', output)
        self.assert_original_pair(original)
        self.assertEqual(db_before, self.inventory(self.db))
        self.assertEqual((self.root / 'service-state').read_text(), 'active')
        self.assertEqual([c for c in self.commands() if c[0] == 'sudo' and c[1] == 'systemctl'],
                         [['sudo', 'systemctl', action, 'synthetic.service']
                          for action in ('stop', 'reset-failed', 'start')])
        self.assertFalse(self.work.exists(), 'Rollback must explicitly clean scratch')

    def test_partial_second_install_failure_tracks_and_restores_both_files(self):
        self.make_plans()
        original = self.original_pair()
        output = self.run_shell(self.rollback_body(), expected=73, fail_copy=True,
                                overrides={'NODE_WAS_ACTIVE': 'true'})
        self.assertIn('Rollback completed', output)
        self.assert_original_pair(original)
        backup = self.files.parent / 'files-11.1.2-bak-20260918T010203Z'
        self.assertEqual((backup / 'upgrade-installed-files.txt').read_text().splitlines(),
                         ['config.json', 'topology.json'])
        restored = [c[-1] for c in self.commands() if c[:3] == ['sudo', 'cp', '-a']]
        self.assertEqual(restored, [str(self.files / n) for n in ('config.json', 'topology.json')])

    def test_rollback_does_not_start_previously_inactive_service(self):
        self.make_plans()
        original = self.original_pair()
        self.write(self.root / 'service-state', b'inactive')
        self.run_shell(self.rollback_body(), expected=42)
        self.assert_original_pair(original)
        self.assertEqual((self.root / 'service-state').read_text(), 'inactive')
        self.assertNotIn(['sudo', 'systemctl', 'start', 'synthetic.service'], self.commands())

    def assert_no_restart(self):
        self.assertFalse(any(c[:3] in (['sudo', 'systemctl', 'start'],
                                      ['sudo', 'systemctl', 'reset-failed'])
                             for c in self.commands()))

    def test_rollback_stop_failure_leaves_all_files_untouched_and_never_restarts(self):
        self.make_plans()
        planned = {name: (self.plan / name).read_bytes()
                   for name in ('config.json', 'topology.json')}
        before = self.inventory(self.db, self.active, self.env_file.parent)
        output = self.run_shell(self.rollback_body(), expected=42,
                                overrides={'NODE_WAS_ACTIVE': 'true'},
                                faults={'stop_failure': True})
        self.assertIn('ROLLBACK BLOCKED: could not stop service', output)
        for name, data in planned.items():
            self.assertEqual((self.files / name).read_bytes(), data)
        # prepare_activation creates an env backup, but cannot alter the env.
        for path, value in before.items():
            if path != str(self.env_file.parent):
                self.assertEqual(self.inventory(self.db, self.active, self.env_file.parent)[path], value)
        self.assertFalse(any(c[:2] in (['sudo', 'rm'], ['sudo', 'cp']) for c in self.commands()))
        self.assert_no_restart()
        self.assertEqual((self.root / 'service-state').read_text(), 'active')
        self.assertFalse(self.work.exists())

    def test_rollback_unconfirmed_stop_never_restores_or_restarts(self):
        self.make_plans()
        planned = {name: (self.plan / name).read_bytes()
                   for name in ('config.json', 'topology.json')}
        output = self.run_shell(self.rollback_body(), expected=42,
                                overrides={'NODE_WAS_ACTIVE': 'true'},
                                faults={'active_state': 'deactivating'})
        self.assertIn('service is not confirmed stopped', output)
        for name, data in planned.items():
            self.assertEqual((self.files / name).read_bytes(), data)
        self.assertFalse(any(c[:2] in (['sudo', 'rm'], ['sudo', 'cp']) for c in self.commands()))
        self.assert_no_restart()
        self.assertFalse(self.work.exists())

    def test_rollback_active_state_probe_failure_never_restores_or_restarts(self):
        self.make_plans()
        output = self.run_shell(self.rollback_body(), expected=42,
                                overrides={'NODE_WAS_ACTIVE': 'true'},
                                faults={'show_failure': True})
        self.assertIn('service is not confirmed stopped', output)
        self.assertFalse(any(c[:2] in (['sudo', 'rm'], ['sudo', 'cp']) for c in self.commands()))
        self.assert_no_restart()

    def test_failed_restore_never_restarts_inconsistent_installation(self):
        self.make_plans()
        original = self.original_pair()
        output = self.run_shell(self.rollback_body(), expected=42,
                                overrides={'NODE_WAS_ACTIVE': 'true'},
                                faults={'restore_failure': True})
        self.assertIn('ROLLBACK INCOMPLETE', output)
        self.assertNotIn('Rollback completed', output)
        self.assertFalse((self.files / 'config.json').exists())
        self.assertEqual((self.files / 'topology.json').read_bytes(), original['topology.json'][0])
        backup = self.files.parent / 'files-11.1.2-bak-20260918T010203Z'
        self.assertEqual((backup / 'config.json').read_bytes(), original['config.json'][0])
        self.assertEqual((self.root / 'service-state').read_text(), 'inactive')
        self.assert_no_restart()
        self.assertFalse(self.work.exists())

    def test_rollback_hash_mismatch_never_restarts_even_when_copies_succeed(self):
        self.make_plans()
        body = self.backup_setup() + '''
ROLLBACK_ARMED=true
trap rollback_on_exit EXIT
''' + self.install_pair() + '''
printf '%s' 'damaged backup' > "${FILES_DIR}-${BACKUP_SUFFIX}/config.json"
exit 42
'''
        output = self.run_shell(body, expected=42, overrides={'NODE_WAS_ACTIVE': 'true'})
        self.assertIn('ROLLBACK INCOMPLETE', output)
        self.assertEqual((self.files / 'config.json').read_bytes(), b'damaged backup')
        self.assert_no_restart()

    def test_rollback_current_binary_mismatch_never_restarts(self):
        self.make_plans()
        body = self.backup_setup() + '''
ROLLBACK_ARMED=true
NODE_WAS_ACTIVE=true
trap rollback_on_exit EXIT
printf '%s' 'concurrent binary replacement' > "$CURRENT_NODE_BIN"
exit 42
'''
        output = self.run_shell(body, expected=42)
        self.assertIn('ROLLBACK INCOMPLETE', output)
        self.assert_no_restart()
        self.assertEqual((self.root / 'service-state').read_text(), 'inactive')

    def test_unarmed_failure_and_success_clean_workspace_without_rollback(self):
        before = self.inventory(self.root / 'node', self.root / 'home')
        for status, armed in ((42, 'false'), (0, 'true')):
            with self.subTest(status=status, armed=armed):
                self.work.mkdir(exist_ok=True)
                self.run_shell(f'trap rollback_on_exit EXIT\nexit {status}', expected=status,
                               overrides={'ROLLBACK_ARMED': armed})
                self.assertFalse(self.work.exists())
        self.assertEqual(before, self.inventory(self.root / 'node', self.root / 'home'))
        self.assertTrue(all(c[:3] == ['rm', '-rf', '--'] for c in self.commands()))

    def test_unchanged_files_are_not_reinstalled(self):
        self.make_plans()
        for name in ('config.json', 'topology.json'):
            (self.plan / name).write_bytes((self.files / name).read_bytes())
        before = self.inventory(self.files)
        self.run_shell(self.install_pair() + '\n[[ ${#CONFIG_INSTALLED_FILES[@]} == 0 ]]')
        self.assertEqual(before, self.inventory(self.files))
        self.assertFalse(any(c[0] in ('cp', 'mv', 'mktemp') for c in self.commands()))

    def reuse_section(self):
        return 'REUSE_INSTALLED_BINARIES=false' + section(
            self.shell, 'REUSE_INSTALLED_BINARIES=false', '# --- Choose LedgerDB backend')

    def test_same_version_skips_download_packages_and_binary_replacement(self):
        self.make_plans()
        before = self.inventory(self.active)
        staging = section(self.shell, '# --- Step 0: Download staged binaries',
                          '# --- Pre-flight checks').split('\n', 1)[1]
        activation = section(self.shell, '# --- Step 6: Copy new binaries',
                             '# --- Step 7: Handle database').split('\n', 1)[1]
        self.run_shell(self.reuse_section() + staging + self.backup_setup() + activation +
                       '\n[[ "$BINARY_CHANGED" == false ]]')
        self.assertEqual(before, self.inventory(self.active))
        for name in ('cardano-node', 'cardano-cli'):
            self.assertEqual((self.staged_bin / name).read_bytes(), (self.active / name).read_bytes())
        calls = self.commands()
        self.assertFalse(any(c[0] in ('curl', 'wget', 'apt-get', 'dpkg', 'sudo') for c in calls))
        installs = [c for c in calls if c[0] == 'install']
        self.assertEqual(len(installs), 2)
        self.assertTrue(all(Path(c[-1]).parent == self.staged_bin for c in installs))

    def test_custom_url_or_version_difference_disables_binary_reuse(self):
        for overrides in ({'CUSTOM_URL': 'https://invalid.example/not-contacted'},
                          {'CURRENT_VERSION': '10.0.0'}):
            with self.subTest(overrides=overrides):
                self.run_shell(self.reuse_section() + '\n[[ "$REUSE_INSTALLED_BINARIES" == false ]]',
                               overrides=overrides)
        self.assertEqual(self.commands(), [])

    def test_missing_cli_disables_binary_reuse(self):
        (self.active / 'cardano-cli').unlink()
        self.run_shell(self.reuse_section() + '\n[[ "$REUSE_INSTALLED_BINARIES" == false ]]')

    def test_same_version_in_different_directory_disables_binary_reuse(self):
        other = self.root / 'old-version/bin'
        other.mkdir(parents=True)
        for name in ('cardano-node', 'cardano-cli'):
            shutil.copy2(self.active / name, other / name)
        self.run_shell(self.reuse_section() + '\n[[ "$REUSE_INSTALLED_BINARIES" == false ]]',
                       overrides={'CURRENT_NODE_BIN': str(other / 'cardano-node'),
                                  'CURRENT_CLI_BIN': str(other / 'cardano-cli')})
        self.assertEqual(self.commands(), [['dirname', str(other / 'cardano-node')]])

    def network_section(self):
        return section(self.shell, '# Validate preserved network files', 'verify_plan_inputs() {').split('\n', 1)[1]

    def network_fixture(self, magic=42):
        """Real JSON/hashes; Byron's CLI digest is explicitly a synthetic stand-in."""
        config = {**self.config, 'MinNodeVersion': '11.1.2',
                  'TraceOptions': {'': {'backends': ['PrometheusSimple suffix 0.0.0.0 12345']}}}
        for prefix, filename in (
                ('ByronGenesis', 'byron-genesis.json'), ('ShelleyGenesis', 'shelley-genesis.json'),
                ('AlonzoGenesis', 'alonzo-genesis.json'), ('ConwayGenesis', 'conway-genesis.json'),
                ('Checkpoints', 'checkpoints.json')):
            data = self.write(self.files / filename, {'networkMagic': magic} if prefix == 'ShelleyGenesis'
                              else {'synthetic': prefix})
            config[prefix + 'File'] = filename
            hash_key = 'CheckpointsFileHash' if prefix == 'Checkpoints' else prefix + 'Hash'
            config[hash_key] = hashlib.blake2b(data, digest_size=32).hexdigest()
        self.write(self.files / 'config.json', config)
        self.write(self.plan / 'config.json', {**config, 'ConsensusMode': 'PraosMode'})
        shutil.copy2(self.active / 'cardano-cli', self.staged_bin / 'cardano-cli')
        return config

    def test_network_validation_hashes_all_preserved_dependencies(self):
        config = self.network_fixture()
        before = self.inventory(self.root / 'node')
        self.run_shell(self.network_section())
        dependencies = json.loads((self.work / 'network-dependencies.json').read_text())
        expected = {str(self.files / v): digest(self.files / v)
                    for k, v in config.items() if k.endswith('File')}
        self.assertEqual(dependencies, expected)
        self.assertEqual(before, self.inventory(self.root / 'node'))
        self.assertIn(['cardano-cli', 'byron', 'genesis', 'print-genesis-hash',
                       '--genesis-json', str(self.files / 'byron-genesis.json')], self.commands())

    def test_network_validation_prefers_staged_files_and_handles_absolute_references(self):
        config = self.network_fixture()
        expected = {}
        for key in list(config):
            if key.endswith('File'):
                live = self.files / config[key]
                staged = self.stage / live.name
                self.write(staged, live.read_bytes())
                config[key] = str(live)
                live.write_bytes(b'invalid live data must not override staging')
                expected[str(staged)] = digest(staged)
        self.write(self.plan / 'config.json', {**config, 'ConsensusMode': 'PraosMode'})
        self.run_shell(self.network_section())
        self.assertEqual(json.loads((self.work / 'network-dependencies.json').read_text()), expected)
        self.assertIn(['cardano-cli', 'byron', 'genesis', 'print-genesis-hash',
                       '--genesis-json', str(self.stage / 'byron-genesis.json')], self.commands())

    def test_network_validation_rejects_each_genesis_and_checkpoint_hash_mismatch(self):
        self.network_fixture()
        for name, message in (('byron', 'Byron genesis hash mismatch'),
                              ('shelley', 'ShelleyGenesis hash mismatch'),
                              ('alonzo', 'AlonzoGenesis hash mismatch'),
                              ('conway', 'ConwayGenesis hash mismatch'),
                              ('checkpoints', 'Checkpoints hash mismatch')):
            with self.subTest(dependency=name):
                path = self.files / (name + '-genesis.json' if name != 'checkpoints' else 'checkpoints.json')
                original = path.read_bytes()
                try:
                    path.write_bytes(original + b'\n')
                    output = self.run_shell(self.network_section(), expected=None)
                    self.assertIn(message, output)
                finally:
                    path.write_bytes(original)

    def test_network_validation_requires_checkpoints_file_hash_not_checkpoints_hash(self):
        config = self.network_fixture()
        config['CheckpointsHash'] = config.pop('CheckpointsFileHash')
        self.write(self.plan / 'config.json', {**config, 'ConsensusMode': 'PraosMode'})
        self.assertIn('CheckpointsFileHash', self.run_shell(self.network_section(), expected=None))

    def test_network_validation_allows_omitted_optional_checkpoints(self):
        config = self.network_fixture()
        del config['CheckpointsFile']
        del config['CheckpointsFileHash']
        self.write(self.plan / 'config.json', {**config, 'ConsensusMode': 'PraosMode'})
        self.run_shell(self.network_section())
        dependencies = json.loads((self.work / 'network-dependencies.json').read_text())
        self.assertEqual(len(dependencies), 4)
        self.assertNotIn(str(self.files / 'checkpoints.json'), dependencies)

    def test_network_validation_rejects_wrong_magic_newer_minimum_and_missing_genesis(self):
        config = self.network_fixture()
        self.assertIn('Wrong network magic', self.run_shell(self.network_section(), expected=None,
                                                          overrides={'EXPECTED_NETWORK_MAGIC': '1'}))
        self.write(self.plan / 'config.json', {**config, 'ConsensusMode': 'PraosMode', 'MinNodeVersion': '12.0.0'})
        self.assertIn('requires a newer node', self.run_shell(self.network_section(), expected=None))
        self.write(self.plan / 'config.json', {**config, 'ConsensusMode': 'PraosMode'})
        (self.files / 'conway-genesis.json').unlink()
        self.assertIn('FileNotFoundError', self.run_shell(self.network_section(), expected=None))

    def replace_exact(self, text, old, new, count=1):
        self.assertEqual(text.count(old), count, f'Shell substitution changed: {old!r}')
        return text.replace(old, new)

    def proc_fixture(self, executable=None, block_producer=False):
        proc = self.root / 'proc/424242'
        proc.mkdir(parents=True, exist_ok=True)
        arguments = ('cardano-node\0run\0--config\0' + str(self.files / 'config.json') +
                     '\0--topology\0' + str(self.files / 'topology.json') +
                     '\0--database-path\0' + str(self.db))
        if block_producer:
            arguments += '\0--shelley-kes-key\0synthetic-kes.skey'
        self.write(proc / 'cmdline', (arguments + '\0').encode())
        (proc / 'exe').symlink_to(executable or self.active / 'cardano-node')
        (proc / 'cwd').symlink_to(self.root)

    def startup_section(self):
        body = section(self.shell, '# --- Step 9: Validate', 'if [[ "${ACTIVE_PEERS}" =~').split('\n', 1)[1]
        return self.replace_exact(body, '"/proc/${MAIN_PID}/exe"',
                                  '"${SANDBOX}/proc/${MAIN_PID}/exe"')

    def run_startup(self, faults=None, expected=0):
        self.proc_fixture()
        return self.run_shell(self.startup_section(), faults=faults, expected=expected, overrides={
            'VALIDATION_PID': '424242', 'VALIDATION_INVOCATION': 'a' * 32,
            'VALIDATION_STARTED_AT': '2026-09-18T01:02:03+00:00',
            'STARTUP_VALIDATION_TIMEOUT_SECONDS': '2'})

    def test_service_identity_rejects_wrong_database_and_role(self):
        self.proc_fixture()
        wrong_database = self.root / 'other-db'
        cmdline_path = self.root / 'proc/424242/cmdline'
        cmdline = cmdline_path.read_bytes()
        cmdline_path.write_bytes(
            cmdline.replace(str(self.db).encode(), str(wrong_database).encode()))
        output = self.run_shell(
            'export PYTHONOPTIMIZE=1; verify_service_process 424242 "$ACTIVE_BIN_DIR/cardano-node"',
            expected=None)
        self.assertIn('Unexpected active --database-path', output)

        cmdline_path.write_bytes(cmdline)
        output = self.run_shell(
            'export PYTHONOPTIMIZE=1; verify_service_process 424242 "$ACTIVE_BIN_DIR/cardano-node"',
            expected=None,
            overrides={'NODE_ROLE': 'bp'})
        self.assertIn('Declared role contradicts active forging arguments', output)

    def test_startup_journal_access_failure_is_not_reported_as_clean(self):
        output = self.run_startup({'journal_failure': 'general'}, expected=1)
        self.assertIn('Journal probe failed', output)
        self.assertNotIn('journal errors: PASS', output)
        self.assertNotIn('Startup validation passed', output)
        self.assertFalse(any(c[0] == 'curl' for c in self.commands()))

    def test_startup_priority_journal_access_failure_is_not_reported_as_clean(self):
        output = self.run_startup({'journal_failure': 'priority'}, expected=1)
        self.assertIn('Journal priority probe failed', output)
        self.assertNotIn('journal errors: PASS', output)
        self.assertNotIn('Startup validation passed', output)

    def test_startup_allows_empty_general_journal_when_runtime_evidence_passes(self):
        output = self.run_startup({'journal_text': ''})
        self.assertIn('journal errors: PASS (queries succeeded; none detected)', output)
        self.assertIn('Startup validation passed', output)

    def test_startup_rejects_changed_invocation_before_journal_probe(self):
        output = self.run_startup({'invocation': 'b' * 32}, expected=1)
        self.assertIn('Service restarted during startup validation', output)
        self.assertFalse(any(c[0] in ('journalctl', 'curl') for c in self.commands()))

    def test_startup_uses_new_invocation_for_both_journal_probes(self):
        output = self.run_startup()
        self.assertIn('Startup validation passed', output)
        self.assertIn('running (sync not established)', output)
        probes = [c for c in self.commands() if c[0] == 'journalctl']
        self.assertEqual(len(probes), 2)
        self.assertTrue(all('_SYSTEMD_INVOCATION_ID=' + 'a' * 32 in c for c in probes))
        self.assertNotIn('-p', probes[0])
        self.assertIn('emerg..err', probes[1])

    def test_startup_rejects_priority_errors_even_without_fatal_text(self):
        output = self.run_startup({'priority_text': 'Invalid configuration supplied'}, expected=1)
        self.assertIn('Fatal/error journal entries', output)
        self.assertNotIn('Startup validation passed', output)

    def transformed_script(self):
        """Retain ALL executable sections/ordering; replace only fixture boundaries."""
        text = self.shell
        text = self.replace_exact(text, '[[ "${EUID}" -ne 0 ]]',
                                  '[[ "${SANDBOX_IDENTITY}" == "service-user" ]]')
        text = self.replace_exact(text, 'BIN_DIR="${HOME}/.local/bin"', 'BIN_DIR="${HOME}/bin"')
        for profile, service in (('cnode', 'cnode'), ('preprod', 'preprod'), ('preview', 'preview')):
            text = self.replace_exact(text, f'CNODE_HOME="/opt/cardano/{profile}"',
                                      f'CNODE_HOME="{self.root}/node"')
            text = self.replace_exact(text, f'SERVICE_NAME="{service}.service"',
                                      'SERVICE_NAME="synthetic.service"')
        text = self.replace_exact(text, "pathlib.Path('/proc')", f'pathlib.Path({str(self.root / "proc")!r})')
        for pid in ('INITIAL_PID', 'MAIN_PID'):
            text = self.replace_exact(text, f'"/proc/${{{pid}}}/exe"',
                                      f'"${{SANDBOX}}/proc/${{{pid}}}/exe"',
                                      count=2 if pid == 'INITIAL_PID' else 1)
        self.assertNotIn('CNODE_HOME="/opt/cardano/', text)
        self.assertNotIn('"/proc/', text)
        self.assertNotIn("Path('/proc')", text)
        text = self.replace_exact(text, 'set -euo pipefail\n', 'set -euo pipefail\n'
                                  'command_not_found_handle() { printf "%s\\n" "$*" >> "$SANDBOX/forbidden"; return 97; }\n')
        # A syntax error in a transformed copy must not be confused with a
        # successful negative test. No source/eval of the original script.
        checked = subprocess.run([BASH, '--noprofile', '--norc', '-n'], input=text,
                                 text=True, capture_output=True, env=self.sandbox_env(), timeout=10)
        self.assertEqual(checked.returncode, 0, checked.stderr)
        path = self.root / 'upgrade-cardano-node.sh'
        self.write(path, text.encode())
        self.write(self.root / 'upgrade-cardano-config.py', HELPER.read_bytes())
        return path

    def full_script_dry_run(self, corrupt=None):
        self.network_fixture(magic=764824073)
        config = json.loads((self.files / 'config.json').read_text())
        config.update({'TurnOnLogging': True, 'TurnOnLogMetrics': True,
                       'UseTraceDispatcher': True})
        self.write(self.files / 'config.json', config)
        snapshot = json.loads((self.files / 'snapshot.json').read_text())
        snapshot['NetworkMagic'] = 764824073
        self.write(self.files / 'snapshot.json', snapshot)
        self.proc_fixture()
        if corrupt:
            path = self.files / corrupt
            path.write_bytes(path.read_bytes() + b'\n')
        script = self.transformed_script()
        before = self.inventory(self.root / 'node', self.root / 'home')
        result = subprocess.run([BASH, '--noprofile', '--norc', str(script), '--relay',
                                 '--version', '11.1.2', '--keep-config', '--dry-run', '--yes'],
                                cwd=self.root, env=self.sandbox_env(), text=True,
                                capture_output=True, timeout=30)
        output = self.check_result(result, 1 if corrupt else 0)
        self.assertEqual(before, self.inventory(self.root / 'node', self.root / 'home'))
        self.assertEqual((self.root / 'service-state').read_text(), 'active')
        calls = self.commands()
        self.assertFalse(any(c[0] in ('sudo', 'curl', 'wget', 'apt-get', 'dpkg') for c in calls))
        self.assertTrue(all(c[1] in ('show', 'is-active') for c in calls if c[0] == 'systemctl'))
        # Find the dynamic mktemp workspace via its binary installs (not the
        # unrelated scratch fixtures used by extracted-section tests).
        installs = [c for c in calls if c[0] == 'install']
        self.assertEqual(len(installs), 2)
        scratch = Path(installs[0][-1]).parent.parent
        self.assertEqual(scratch.parent, self.work)
        self.assertTrue(all(Path(c[-1]).parent == scratch / 'binaries' for c in installs))
        self.assertFalse(scratch.exists(), 'EXIT cleanup must remove the full-script workspace')
        self.assertIn(['cp', '-a', str(self.files / 'config.json'),
                       str(scratch / 'config-stage/config.json')], calls)
        network_probe = [c for c in calls if c[:3] == ['python3', '-', str(scratch / 'final-plan/config.json')]]
        self.assertEqual(len(network_probe), 1, 'Shared network validation must execute before dry-run exits')
        if not corrupt:
            self.assertIn(['cardano-cli', 'byron', 'genesis', 'print-genesis-hash',
                           '--genesis-json', str(self.files / 'byron-genesis.json')], calls)
            self.assertIn('Unsupported legacy tracer keys will be removed', output)
            for key in ('TurnOnLogging', 'TurnOnLogMetrics', 'UseTraceDispatcher'):
                self.assertIn(key, output)
                self.assertIn(f'-  "{key}": true', output)
            self.assertIn('Dry run passed', output)
        else:
            self.assertNotIn('Dry run passed', output)
        return output

    def test_full_script_sandbox_dry_run_stages_and_validates_without_live_mutation(self):
        self.full_script_dry_run()

    def test_full_script_custom_instance_dry_run_preserves_apex_binary_and_live_files(self):
        self.network_fixture(magic=764824073)
        topology = json.loads((self.files / 'topology.json').read_text())
        topology['useLedgerAfterSlot'] = -1
        self.write(self.files / 'topology.json', topology)
        snapshot = json.loads((self.files / 'snapshot.json').read_text())
        snapshot['NetworkMagic'] = 764824073
        self.write(self.files / 'snapshot.json', snapshot)
        current = self.root / 'home/tmp/cardano-11.1.2/bin'
        current.mkdir(parents=True)
        for name in ('cardano-node', 'cardano-cli'):
            self.write(current / name, (self.active / name).read_bytes())
            (current / name).chmod(0o755)
        self.write(self.env_file,
                   f'CNODEBIN="{current / "cardano-node"}"\nCCLI="{current / "cardano-cli"}"\n'.encode())
        self.proc_fixture(current / 'cardano-node', block_producer=True)
        apex = self.root / 'home/.local/bin/cardano-node'
        self.write(apex, b'apex shared binary sentinel')
        apex.chmod(0o755)
        script = self.transformed_script()
        before = self.inventory(self.root / 'node', self.root / 'home')
        result = subprocess.run([
            BASH, '--noprofile', '--norc', str(script), '--network', 'mainnet',
            '--node-home', str(self.root / 'node'), '--service', 'synthetic.service',
            '--bp', '--version', '11.1.2', '--keep-config', '--dry-run', '--yes'],
            cwd=self.root, env=self.sandbox_env(), text=True, capture_output=True, timeout=30)
        output = self.check_result(result, 0)
        self.assertIn(f'Install path:   {current} (inferred)', output)
        self.assertIn('Binary target:  reuse', output)
        self.assertIn('Dry run passed', output)
        self.assertEqual(before, self.inventory(self.root / 'node', self.root / 'home'))
        self.assertEqual(apex.read_bytes(), b'apex shared binary sentinel')
        self.assertEqual((self.root / 'service-state').read_text(), 'active')
        calls = self.commands()
        self.assertFalse(any(call[0] in ('sudo', 'curl', 'wget', 'apt-get', 'dpkg') for call in calls))

    def test_full_script_dry_run_rejects_corrupt_checkpoints_before_success(self):
        self.assertIn('Checkpoints hash mismatch', self.full_script_dry_run('checkpoints.json'))

    def test_full_script_dry_run_rejects_corrupt_genesis_before_success(self):
        self.assertIn('AlonzoGenesis hash mismatch', self.full_script_dry_run('alonzo-genesis.json'))

    def test_full_script_dry_run_rejects_byron_cli_mismatch_before_success(self):
        self.assertIn('Byron genesis hash mismatch', self.full_script_dry_run('byron-genesis.json'))


if __name__ == '__main__':
    unittest.main()