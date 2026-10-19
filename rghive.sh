#!/usr/bin/env bash
# Self-contained HiveOS installer. Upload this file only.
# Run: sudo bash rghive.sh --token YOUR_TOKEN --yes
command -v python3 >/dev/null || { echo "Нужен python3 (HiveOS 18.04+)." >&2; exit 3; }
export PYTHONIOENCODING=utf-8
exec python3 -c '#!/usr/bin/env python3
"""Local HiveOS flight sheet installer. Python >= 3.6, standard library only."""
import argparse
import contextlib
import fcntl
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.request
import urllib.error

VERSION = "0.3.0"
# Release pin: update URL and digest together when publishing the installer.
PACKAGE_URL = "https://github.com/Printscan/rgminer/releases/download/v1.1.3b/rgminer-1.1.3b-hiveos.tar.gz"
PACKAGE_SHA256 = "dd8809baed0155f9d9821f53f7c78f38fdcf83d4239b92f9e4fed5b9aaa8485d"
HIVE = Path("/hive")
CONFIG = Path("/hive-config")
STATE = Path("/hive-config/rgminer-setup")
PROC = Path('"'"'/proc'"'"')
SETUP_WALLET = '"'"'setup-pending'"'"'
SETUP_POOL = '"'"'stratum+tcp://127.0.0.1:9'"'"'
ALIASES = {
    "pearl": "pearl", "prl": "pearl", "pearlhash": "pearl",
    "pearl-hash": "pearl", "pearl_hash": "pearl",
    "quantus": "quantus", "qtc": "quantus", "poseidon2": "quantus",
    "poseidon-2": "quantus", "poseidon_2": "quantus",
    "exfer": "exfer-argon2id", "argon2id": "exfer-argon2id",
    "exfer-argon2id": "exfer-argon2id", "exfer_argon2id": "exfer-argon2id",
    "nock": "nock-zk", "nockchain": "nock-zk", "nock-zk": "nock-zk",
    "zkpow": "nock-zk", "nock_zk": "nock-zk", "nock-zk-v5": "nock-zk",
}


class Failure(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def say(message, quiet=False):
    if not quiet:
        print(message, file=sys.stderr, flush=True)


def assignments(text):
    """Read literal shell assignments without source/eval, keeping edit spans.

    Hive generates quoted assignments, including multiline values. Reject shell
    expansion/control syntax rather than misreading a wallet or executing it.
    """
    values, spans = {}, []
    i, n = 0, len(text)
    while i < n:
        if text[i].isspace():
            i += 1
            continue
        if text[i] == '"'"'#'"'"':
            end = text.find('"'"'\n'"'"', i)
            i = n if end < 0 else end + 1
            continue
        start = i
        match = re.match(r'"'"'(?:export[ \t]+)?([A-Za-z_][A-Za-z_0-9]*)='"'"', text[i:])
        if not match:
            raise Failure("Конфигурация содержит команды или неподдерживаемый синтаксис; изменения не внесены.", 3)
        key = match.group(1)
        i += match.end()
        value, quote = [], None
        while i < n:
            c = text[i]
            if quote == "'"'"'":
                if c == "'"'"'":
                    quote = None
                else:
                    value.append(c)
                i += 1
                continue
            if c in '"'"'$`'"'"':
                raise Failure("В {} используется shell-подстановка. Нужна конфигурация с буквальными значениями.".format(key), 3)
            if c == '"'"'\\'"'"':
                i += 1
                if i == n:
                    raise Failure("Незавершённое экранирование в {}.".format(key), 3)
                if text[i] != '"'"'\n'"'"':
                    if quote == '"'"'"'"'"' and text[i] not in '"'"'\\"$`'"'"':
                        value.append('"'"'\\'"'"')
                    value.append(text[i])
                i += 1
                continue
            if quote == '"'"'"'"'"':
                if c == '"'"'"'"'"':
                    quote = None
                else:
                    value.append(c)
                i += 1
                continue
            if c in "'"'"'\"":
                quote = c
                i += 1
                continue
            if c.isspace():
                break
            if c in '"'"';|&<>()'"'"':
                raise Failure("Неподдерживаемый shell-синтаксис в {}.".format(key), 3)
            value.append(c)
            i += 1
        if quote:
            raise Failure("Незакрытые кавычки в {}.".format(key), 3)
        values[key] = '"'"''"'"'.join(value)
        spans.append((start, i, key))
    return values, spans


def shellquote(value):
    return "'"'"'" + str(value).replace("'"'"'", "'"'"'\"'"'"'\"'"'"'") + "'"'"'"


def patch(text, changes):
    values, spans = assignments(text)
    # Replace the final effective assignment and remove preceding duplicates.
    last = {key: start for start, end, key in spans}
    for start, end, key in reversed(spans):
        if key in changes:
            replacement = key + '"'"'='"'"' + shellquote(changes[key]) if last[key] == start else '"'"''"'"'
            text = text[:start] + replacement + text[end:]
    for key, value in changes.items():
        if key not in values:
            text = text.rstrip('"'"'\n'"'"') + '"'"'\n'"'"' + key + '"'"'='"'"' + shellquote(value) + '"'"'\n'"'"'
    return text


def option_value(text, names):
    # RGminer h-config/h-run use whitespace splitting, not shell quote parsing.
    words = text.split()
    result = None
    for i, word in enumerate(words):
        if word in names:
            if i + 1 >= len(words) or words[i + 1].startswith('"'"'--'"'"'):
                raise Failure("В параметрах майнера отсутствует значение {}.".format(word), 3)
            result = words[i + 1]
        for name in names:
            if word.startswith(name + '"'"'='"'"'):
                result = word[len(name) + 1:]
    return result


def with_token(extra, token):
    # Preserve every other option verbatim, including multiline formatting.
    pattern = r'"'"'(?<!\S)--token(?:=[^\s]*|\s+(?!-)[^\s]+)(?!\S)'"'"'
    clean = re.sub(pattern, '"'"''"'"', extra).strip()
    if re.search(r'"'"'(?<!\S)--token(?:\s|$)'"'"', clean):
        raise Failure("Некорректный старый --token в параметрах майнера.", 3)
    return (clean + '"'"' --token '"'"' + token).strip()


def normalized(value):
    return ALIASES.get(value.strip().lower())


def local_miner(name):
    if not re.fullmatch(r'"'"'rgminer(?:-[A-Za-z0-9_.-]+)?'"'"', name or '"'"''"'"'):
        return False
    folder = HIVE / '"'"'miners/custom'"'"' / name
    return all((folder / item).is_file() for item in ('"'"'rgminer'"'"', '"'"'h-config.sh'"'"', '"'"'h-run.sh'"'"', '"'"'h-manifest.conf'"'"'))


def choose_miner(current, requested):
    if requested:
        if not local_miner(requested):
            raise Failure("Указанный --miner не является установленным RGminer.", 3)
        return requested
    if local_miner(current):
        return current
    candidates = [p.name for p in (HIVE / '"'"'miners/custom'"'"').glob('"'"'rgminer*'"'"') if local_miner(p.name)]
    # Prefer the highest installed version; never downgrade an active RGminer.
    def version_key(name):
        return tuple((0, int(v)) if v.isdigit() else (1, v) for v in re.split(r'"'"'(\d+)'"'"', name))
    return max(candidates, key=version_key) if candidates else None


def setup_plan(wallet_text, conf, args, token, reason):
    current = conf.get('"'"'CUSTOM_MINER'"'"') if conf.get('"'"'MINER'"'"') == '"'"'custom'"'"' else None
    miner = choose_miner(current, args.miner)
    if miner and (HIVE / '"'"'miners/custom'"'"' / miner / '"'"'rgminer_managed_config.env'"'"').exists() and current != miner:
        raise Failure("У выбранного RGminer есть сохранённая конфигурация дашборда. Выберите чистый пакет через --miner.", 3)
    changes = {
        '"'"'MINER'"'"': '"'"'custom'"'"',
        '"'"'CUSTOM_MINER'"'"': miner or '"'"'rgminer-'"'"' + Path(PACKAGE_URL).name.split('"'"'rgminer-'"'"')[1].split('"'"'-hiveos'"'"')[0],
        '"'"'CUSTOM_INSTALL_URL'"'"': '"'"''"'"', '"'"'CUSTOM_ALGO'"'"': '"'"'pearl'"'"',
        '"'"'CUSTOM_TEMPLATE'"'"': SETUP_WALLET, '"'"'CUSTOM_URL'"'"': SETUP_POOL,
        '"'"'CUSTOM_PASS'"'"': '"'"''"'"', '"'"'CUSTOM_STRATUM_PASS'"'"': '"'"''"'"',
        '"'"'CUSTOM_TLS'"'"': '"'"''"'"', '"'"'CUSTOM_STRATUM_TLS'"'"': '"'"'tcp'"'"',
        '"'"'CUSTOM_INSTALL_CMP_DRIVER'"'"': '"'"'0'"'"', '"'"'CUSTOM_WATCHDOG_POLICY'"'"': '"'"'notify'"'"',
        '"'"'CUSTOM_PROTO'"'"': '"'"''"'"', '"'"'CUSTOM_PEARL_PROTOCOL'"'"': '"'"''"'"',
        '"'"'META'"'"': json.dumps({'"'"'custom'"'"': {'"'"'coin'"'"': '"'"'pearl'"'"'}, '"'"'local'"'"': True, '"'"'rgminer_setup'"'"': True}, separators=('"'"','"'"', '"'"':'"'"')),
        '"'"'CUSTOM_USER_CONFIG'"'"': '"'"'--algo pearl --mem-control none --no-cmp-unlock --watchdog=off --token '"'"' + token,
    }
    # Do not reuse another custom miner'"'"'s tuning flags as RGminer clocks.
    for key in ('"'"'CUSTOM_CCLOCK'"'"', '"'"'CUSTOM_MCLOCK'"'"', '"'"'CUSTOM_LOCK_CCLOCK'"'"', '"'"'CUSTOM_LOCK_MCLOCK'"'"', '"'"'CUSTOM_PL'"'"'):
        if key in conf:
            changes[key] = '"'"''"'"'
    return patch(wallet_text, changes), {
        '"'"'miner'"'"': changes['"'"'CUSTOM_MINER'"'"'], '"'"'algorithm'"'"': '"'"'pearl'"'"', '"'"'mode'"'"': '"'"'setup'"'"',
        '"'"'reason'"'"': reason, '"'"'download'"'"': miner is None,
        '"'"'wallet_detected'"'"': False, '"'"'pool_detected'"'"': False,
    }


def make_plan(rig_text, wallet_text, args, token):
    rig, _ = assignments(rig_text)
    wallet, _ = assignments(wallet_text)
    conf = dict(rig, **wallet)
    for i in range(2, 33):
        if conf.get('"'"'MINER'"'"' + str(i)):
            raise Failure("В полётном листе несколько майнеров. Автоматическое переключение пока не поддерживается.", 3)
    current = conf.get('"'"'MINER'"'"', '"'"''"'"')
    is_rg = current == '"'"'custom'"'"' and re.fullmatch(r'"'"'rgminer(?:-[A-Za-z0-9_.-]+)?'"'"', conf.get('"'"'CUSTOM_MINER'"'"', '"'"''"'"') or '"'"''"'"')
    prefix = '"'"'CUSTOM'"'"' if current == '"'"'custom'"'"' else current.upper().replace('"'"'-'"'"', '"'"'_'"'"')
    explicit = bool(args.algo or args.wallet or args.pool)
    if args.setup_only:
        if explicit:
            raise Failure("--setup-only нельзя совмещать с --algo, --wallet или --pool.", 2)
        return setup_plan(wallet_text, conf, args, token, '"'"'requested'"'"')
    if not explicit and is_rg and conf.get('"'"'CUSTOM_TEMPLATE'"'"') == SETUP_WALLET and conf.get('"'"'CUSTOM_URL'"'"') == SETUP_POOL:
        if args.require_mining_config:
            raise Failure("Текущий лист содержит заглушки; укажите рабочие --algo, --wallet и --pool.", 3)
        return setup_plan(wallet_text, conf, args, token, '"'"'already-configured'"'"')
    if not prefix and not (args.algo and args.wallet and args.pool):
        if not explicit and not args.require_mining_config:
            return setup_plan(wallet_text, conf, args, token, '"'"'no-flight-sheet'"'"')
        raise Failure("Нет активного полётного листа. Укажите --algo, --wallet и --pool или используйте --setup-only.", 3)
    if any(conf.get(prefix + '"'"'_'"'"' + k) for k in ('"'"'ALGO2'"'"', '"'"'TEMPLATE2'"'"', '"'"'URL2'"'"')):
        raise Failure("Обнаружен dual mining. Для него нужен отдельный сценарий переноса.", 3)
    extra = conf.get('"'"'CUSTOM_USER_CONFIG'"'"', '"'"''"'"') if is_rg else '"'"''"'"'
    algo_raw = args.algo or (option_value(extra, ('"'"'--algo'"'"', '"'"'--algorithm'"'"')) if is_rg else None) or conf.get(prefix + '"'"'_ALGO'"'"', '"'"''"'"')
    algo = normalized(algo_raw)
    if not algo:
        # META coin is a useful fallback for an obsolete Hive display label.
        try:
            coin = json.loads(conf.get('"'"'META'"'"', '"'"'{}'"'"')).get(current, {}).get('"'"'coin'"'"', '"'"''"'"')
        except (ValueError, AttributeError):
            coin = '"'"''"'"'
        algo = normalized(coin) if not args.algo else None
    if not algo:
        if not explicit and not args.require_mining_config:
            return setup_plan(wallet_text, conf, args, token, '"'"'unsupported-algorithm'"'"')
        raise Failure("Текущий алгоритм не распознан или не поддерживается RGminer. Укажите совместимые --algo, --wallet и --pool.", 3)
    old_algo = normalized(option_value(extra, ('"'"'--algo'"'"', '"'"'--algorithm'"'"')) or conf.get(prefix + '"'"'_ALGO'"'"', '"'"''"'"'))
    if args.algo and normalized(args.algo) != old_algo:
        if not (args.wallet and args.pool):
            raise Failure("Для смены алгоритма задайте --wallet и --pool явно.", 3)
    address = args.wallet or conf.get(prefix + '"'"'_TEMPLATE'"'"', '"'"''"'"')
    pool = args.pool or conf.get(prefix + '"'"'_URL'"'"', '"'"''"'"')
    # Dedicated CLI overrides in an existing RGminer sheet have higher priority.
    if is_rg:
        address = args.wallet or option_value(extra, ('"'"'--wallet'"'"', '"'"'--address'"'"')) or address
        pool = args.pool or option_value(extra, ('"'"'--stratum'"'"',)) or pool
    if not address or '"'"'%WAL%'"'"' in address or not pool:
        if not explicit and not args.require_mining_config:
            return setup_plan(wallet_text, conf, args, token, '"'"'missing-wallet-or-pool'"'"')
        raise Failure("Не найдены кошелёк или пул. Укажите --wallet и --pool; чужой кошелёк не подставляется.", 3)
    if any(c in address + pool for c in '"'"'\x00\r'"'"'):
        raise Failure("В кошельке или пуле обнаружены недопустимые символы.", 3)
    if args.algo or args.wallet or args.pool:
        # Existing extra CLI flags could silently override the supplied values.
        for value, flags in ((args.algo, ('"'"'--algo'"'"', '"'"'--algorithm'"'"')), (args.wallet, ('"'"'--wallet'"'"', '"'"'--address'"'"')), (args.pool, ('"'"'--stratum'"'"',))):
            if value and option_value(extra, flags) is not None:
                raise Failure("Явный параметр конфликтует с CUSTOM_USER_CONFIG. Уберите соответствующий старый параметр из листа.", 3)
    miner = choose_miner(conf.get('"'"'CUSTOM_MINER'"'"') if is_rg else None, args.miner)
    if miner and not is_rg and (HIVE / '"'"'miners/custom'"'"' / miner / '"'"'rgminer_managed_config.env'"'"').exists():
        raise Failure("В установленном RGminer сохранена конфигурация дашборда: она может перекрыть переносимый кошелёк. Выберите чистый пакет через --miner.", 3)
    changes = {
        '"'"'MINER'"'"': '"'"'custom'"'"',
        '"'"'CUSTOM_MINER'"'"': miner or '"'"'rgminer-'"'"' + Path(PACKAGE_URL).name.split('"'"'rgminer-'"'"')[1].split('"'"'-hiveos'"'"')[0],
        # Local installation is verified before commit. Avoid custom-get, which
        # can delete a working miner and fetch its archive on every startup.
        '"'"'CUSTOM_INSTALL_URL'"'"': '"'"''"'"',
        '"'"'CUSTOM_USER_CONFIG'"'"': with_token(extra, token),
    }
    if not is_rg or args.algo:
        changes['"'"'CUSTOM_ALGO'"'"'] = algo
    if not is_rg or args.wallet:
        changes['"'"'CUSTOM_TEMPLATE'"'"'] = address
    if not is_rg or args.pool:
        changes['"'"'CUSTOM_URL'"'"'] = pool
    if not is_rg:
        # In RGminer CUSTOM_PASS is a legacy fallback POOL list, not a pool
        # password. Its wrapper reads CUSTOM_STRATUM_PASS/STRATUM_TLS instead.
        changes['"'"'CUSTOM_PASS'"'"'] = '"'"''"'"'
        changes['"'"'CUSTOM_STRATUM_PASS'"'"'] = conf.get(prefix + '"'"'_PASS'"'"', '"'"''"'"')
        tls = conf.get(prefix + '"'"'_TLS'"'"', '"'"''"'"').strip().lower()
        changes['"'"'CUSTOM_STRATUM_TLS'"'"'] = '"'"'tls'"'"' if tls in ('"'"'1'"'"', '"'"'true'"'"', '"'"'yes'"'"', '"'"'on'"'"', '"'"'tls'"'"', '"'"'ssl'"'"') else '"'"'auto'"'"'
        changes['"'"'CUSTOM_INSTALL_CMP_DRIVER'"'"'] = '"'"'0'"'"'
        changes['"'"'META'"'"'] = json.dumps({'"'"'custom'"'"': {'"'"'coin'"'"': algo}, '"'"'local'"'"': True}, separators=('"'"','"'"', '"'"':'"'"'))
        # Always select the algorithm explicitly, independent of Hive labels.
        changes['"'"'CUSTOM_USER_CONFIG'"'"'] = '"'"'--algo {} --token {}'"'"'.format(algo, token)
    return patch(wallet_text, changes), {'"'"'miner'"'"': changes['"'"'CUSTOM_MINER'"'"'], '"'"'algorithm'"'"': algo, '"'"'mode'"'"': '"'"'existing'"'"' if is_rg else '"'"'migration'"'"', '"'"'download'"'"': miner is None, '"'"'wallet_detected'"'"': not bool(args.wallet), '"'"'pool_detected'"'"': not bool(args.pool)}


def atomic_write(path, data, mode=0o600, owner=None):
    path = Path(path)
    fd, name = tempfile.mkstemp(prefix='"'"'.'"'"' + path.name + '"'"'.'"'"', dir=str(path.parent))
    try:
        with os.fdopen(fd, '"'"'wb'"'"') as output:
            os.fchmod(output.fileno(), mode)
            if owner:
                os.fchown(output.fileno(), *owner)
            output.write(data)
            output.flush()
            os.fsync(output.fileno())
        os.replace(name, str(path))
        dfd = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(dfd)
        finally:
            os.close(dfd)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def install_package(args, name):
    url, digest = args.package_url or PACKAGE_URL, args.sha256 or PACKAGE_SHA256
    if args.package_url and not args.sha256:
        raise Failure("Для --package-url требуется --sha256.", 2)
    if not url.startswith('"'"'https://'"'"') or not re.fullmatch('"'"'[a-fA-F0-9]{64}'"'"', digest):
        raise Failure("Пакет должен иметь HTTPS URL и SHA-256 из 64 hex-символов.", 2)
    say("Скачиваю RGminer и проверяю SHA-256…", args.quiet)
    parent = HIVE / '"'"'miners/custom'"'"'
    with tempfile.TemporaryDirectory(prefix='"'"'.rgminer-install-'"'"', dir=str(parent)) as temp:
        archive = Path(temp) / '"'"'package.tar.gz'"'"'
        hasher, total = hashlib.sha256(), 0
        with urllib.request.urlopen(url, timeout=args.timeout) as response, archive.open('"'"'wb'"'"') as out:
            if not response.geturl().startswith('"'"'https://'"'"'):
                raise Failure("Сервер перенаправил загрузку на HTTP.", 4)
            deadline = time.monotonic() + args.timeout
            while True:
                block = response.read(1024 * 1024)
                if not block:
                    break
                total += len(block)
                if total > 256 * 1024 * 1024 or time.monotonic() > deadline:
                    raise Failure("Превышен лимит размера или времени загрузки пакета.", 4)
                hasher.update(block)
                out.write(block)
        if hasher.hexdigest() != digest.lower():
            raise Failure("SHA-256 пакета не совпадает. Полётный лист не изменён.", 4)
        unpack = Path(temp) / '"'"'unpack'"'"'
        unpack.mkdir()
        with tarfile.open(str(archive), '"'"'r:gz'"'"') as tar:
            members = tar.getmembers()
            size = 0
            for member in members:
                parts = Path(member.name).parts
                size += member.size
                if (not parts or parts[0] != name or '"'"'..'"'"' in parts or Path(member.name).is_absolute()
                        or not (member.isdir() or member.isfile()) or size > 512 * 1024 * 1024):
                    raise Failure("Недопустимое содержимое архива RGminer.", 4)
            for member in members:
                # No symlinks, devices, ownership or special permission bits.
                target = unpack / member.name
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with tar.extractfile(member) as source, target.open('"'"'wb'"'"') as dest:
                        shutil.copyfileobj(source, dest)
                    target.chmod(member.mode & 0o755)
        folder = unpack / name
        if not all((folder / item).is_file() for item in ('"'"'rgminer'"'"', '"'"'h-config.sh'"'"', '"'"'h-run.sh'"'"', '"'"'h-manifest.conf'"'"')):
            raise Failure("Пакет не содержит HiveOS-интеграцию RGminer.", 4)
        if (parent / name).exists():
            raise Failure("Каталог RGminer появился во время установки; повторите команду.", 3)
        os.rename(str(folder), str(parent / name))


def run_control(action, timeout, quiet=False):
    env = dict(os.environ)
    environment = HIVE / '"'"'etc/environment'"'"'
    if environment.is_file():
        env.update(assignments(environment.read_text())[0])
    env.update(RIG_CONF=str(CONFIG / '"'"'rig.conf'"'"'), WALLET_CONF=str(CONFIG / '"'"'wallet.conf'"'"'))
    # Hive scripts resolve helpers via PATH and rely on /etc/environment.
    env['"'"'PATH'"'"'] = '"'"'/hive/bin:/hive/sbin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'"'"'
    process = subprocess.Popen([str(HIVE / '"'"'bin/miner'"'"'), action], env=env,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                               start_new_session=True)
    try:
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            try:
                process.wait(timeout=max(0.01, min(10, remaining)))
                break
            except subprocess.TimeoutExpired:
                if time.monotonic() >= deadline:
                    raise
                say("HiveOS ещё выполняет miner {}; ожидаю завершения…".format(action), quiet)
    except BaseException as exc:
        # Stop the entire command tree before rollback, including timed-out
        # helpers; a late command must not restart the wrong flight sheet.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        if isinstance(exc, subprocess.TimeoutExpired):
            raise Failure("Команда miner {} превысила таймаут.".format(action), 5)
        raise
    # Hive output may contain full commands/tokens: never echo it.
    if process.returncode and action != '"'"'stop'"'"':
        raise Failure("Команда miner {} завершилась с ошибкой. Проверьте локальный журнал майнера.".format(action), 5)


def process_record(pid):
    try:
        folder = PROC / str(pid)
        fields = (folder / '"'"'stat'"'"').read_text().rsplit('"'"')'"'"', 1)[1].split()
        if fields[0] == '"'"'Z'"'"':
            return None
        return {'"'"'pid'"'"': int(pid), '"'"'ppid'"'"': int(fields[1]), '"'"'start'"'"': fields[19],
                '"'"'exe'"'"': os.readlink(str(folder / '"'"'exe'"'"')).replace('"'"' (deleted)'"'"', '"'"''"'"'),
                '"'"'words'"'"': (folder / '"'"'cmdline'"'"').read_bytes().decode('"'"'utf-8'"'"', '"'"'replace'"'"').split('"'"'\0'"'"')}
    except (OSError, ValueError, IndexError):
        return None


def mining_processes():
    """Identify Hive miners, known standalone miners and their descendants.

    No command lines are printed: they may contain account tokens. Unknown GPU
    programs are checked separately and are never killed as if they were miners.
    """
    known = {'"'"'rgminer'"'"', '"'"'lolminer'"'"', '"'"'rigel'"'"', '"'"'gminer'"'"', '"'"'t-rex'"'"', '"'"'trex'"'"',
             '"'"'nbminer'"'"', '"'"'teamredminer'"'"', '"'"'srbminer'"'"', '"'"'srbminer-multi'"'"', '"'"'xmrig'"'"',
             '"'"'wildrig'"'"', '"'"'wildrig-multi'"'"', '"'"'onezerominer'"'"', '"'"'bzminer'"'"', '"'"'nanominer'"'"',
             '"'"'phoenixminer'"'"', '"'"'miniz'"'"', '"'"'z-enemy'"'"'}
    rows = {}
    selected = set()
    prefix = str(HIVE / '"'"'miners'"'"') + '"'"'/'"'"'
    runner = str(HIVE / '"'"'bin/miner-run'"'"')
    for folder in PROC.glob('"'"'[0-9]*'"'"'):
        record = process_record(folder.name)
        if record is None or record['"'"'pid'"'"'] == os.getpid():
            continue
        pid, exe, words = record['"'"'pid'"'"'], record['"'"'exe'"'"'], record['"'"'words'"'"']
        rows[pid] = record
        name = Path(exe).name.lower()
        script = words[1] if len(words) > 1 else '"'"''"'"'
        if (exe.startswith(prefix) or exe.startswith('"'"'/memfd:rgm-backend-'"'"')
                or name in known or re.fullmatch(r'"'"'rgminer-[0-9][A-Za-z0-9_.-]*'"'"', name)
                or script == runner or (script.startswith(prefix) and script.endswith('"'"'.sh'"'"'))):
            selected.add(pid)
    while True:
        children = {pid for pid, row in rows.items() if row['"'"'ppid'"'"'] in selected}
        if children <= selected:
            break
        selected.update(children)
    return {pid: rows[pid] for pid in selected}


def foreign_miners(launchers):
    rows = mining_processes()
    owned = set(launchers)
    wrappers = set(launchers)
    for root in launchers:
        launcher = process_record(root)
        expected_wrapper = str(Path(launcher['"'"'exe'"'"']).parent / '"'"'h-run.sh'"'"') if launcher else '"'"''"'"'
        pid = root
        for _ in range(20):
            row = process_record(pid)
            if not row or row['"'"'ppid'"'"'] <= 1:
                break
            if len(row['"'"'words'"'"']) > 1 and row['"'"'words'"'"'][1] == expected_wrapper:
                # h-run starts API/watchdog watchers next to the launcher.
                # Include that wrapper'"'"'s children, not every screen window.
                wrappers.add(pid)
            pid = row['"'"'ppid'"'"']
            owned.add(pid)
    descendants = set(wrappers)
    while True:
        children = {pid for pid, row in rows.items() if row['"'"'ppid'"'"'] in descendants}
        if children <= descendants:
            break
        descendants.update(children)
    owned.update(descendants)
    return {pid: row for pid, row in rows.items() if pid not in owned}


def gpu_compute_pids():
    binary = shutil.which('"'"'nvidia-smi'"'"')
    if not binary:
        return set()
    try:
        result = subprocess.run([binary, '"'"'--query-compute-apps=pid'"'"', '"'"'--format=csv,noheader,nounits'"'"'],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    except (OSError, subprocess.TimeoutExpired):
        raise Failure("Не удалось проверить занятость GPU. Второй майнер не запущен; повторите команду или обратитесь в поддержку.", 5)
    if result.returncode:
        raise Failure("NVIDIA не позволила проверить процессы GPU. RGminer не запущен; проверьте драйвер или обратитесь в поддержку.", 5)
    return {int(line.strip()) for line in result.stdout.decode().splitlines() if line.strip().isdigit()}


def signal_miners(rows, signum):
    for pid, previous in rows.items():
        current = process_record(pid)
        # Do not signal a new, unrelated process that reused a miner'"'"'s PID.
        if not current or current['"'"'start'"'"'] != previous['"'"'start'"'"']:
            continue
        try:
            os.kill(pid, signum)
        except ProcessLookupError:
            pass
        except PermissionError:
            raise Failure("Недостаточно прав для остановки старого майнера. Выполните установочную команду через sudo.", 5)


def wait_for_miners(timeout, tracked=None):
    tracked = dict(tracked or {})
    deadline = time.monotonic() + timeout
    while True:
        remaining = mining_processes()
        for pid, previous in tracked.items():
            current = process_record(pid)
            if current and current['"'"'start'"'"'] == previous['"'"'start'"'"']:
                remaining[pid] = current
        tracked.update(remaining)
        if not remaining or time.monotonic() >= deadline:
            return remaining
        time.sleep(0.25)


def stop_miners(timeout, quiet=False):
    tracked = mining_processes()
    say("Останавливаю текущий майнинг: miner stop…", quiet)
    run_control('"'"'stop'"'"', timeout, quiet=quiet)
    remaining = wait_for_miners(3, tracked)
    if remaining:
        say("После miner stop остались процессы майнеров. Завершаю их…", quiet)
        signal_miners(remaining, signal.SIGTERM)
        remaining = wait_for_miners(8, remaining)
    if remaining:
        say("Майнер не завершился по запросу. Принудительно останавливаю только распознанные процессы майнеров…", quiet)
        signal_miners(remaining, signal.SIGKILL)
        remaining = wait_for_miners(3, remaining)
    if remaining:
        raise Failure("Прежний майнер не остановлен. RGminer не запущен. Передайте это сообщение поддержке.", 5)
    busy = gpu_compute_pids()
    if busy:
        raise Failure("На GPU остались сторонние процессы (PID: {}). RGminer не запущен, чтобы не работать одновременно с ними. Обратитесь в поддержку.".format('"'"', '"'"'.join(map(str, sorted(busy)))), 5)
    say("Текущий майнер остановлен. Проверка процессов пройдена.", quiet)


def matching_processes(name, token):
    wanted = str(HIVE / '"'"'miners/custom'"'"' / name / '"'"'rgminer'"'"')
    found = []
    for entry in Path('"'"'/proc'"'"').glob('"'"'[0-9]*/exe'"'"'):
        try:
            if os.readlink(str(entry)) != wanted:
                continue
            words = (entry.parent / '"'"'cmdline'"'"').read_bytes().decode('"'"'utf-8'"'"', '"'"'replace'"'"').split('"'"'\0'"'"')
            if option_value('"'"'\n'"'"'.join(words), ('"'"'--token'"'"',)) == token:
                found.append(int(entry.parent.name))
        except (OSError, Failure):
            continue
    return sorted(found)


def backend_ready(launcher_pid):
    """Require metrics from a live backend descended from this launcher.

    A different listener on the port, or a wrapper restarting invalid CLI
    arguments forever, must not be reported as a successful installation.
    This does not prove account registration or pool acceptance.
    """
    try:
        words = (Path('"'"'/proc'"'"') / str(launcher_pid) / '"'"'cmdline'"'"').read_bytes().decode().split('"'"'\0'"'"')
        text = '"'"'\n'"'"'.join(words)
        port = option_value(text, ('"'"'--api-port'"'"',)) or '"'"'9200'"'"'
        host = option_value(text, ('"'"'--api-host'"'"',)) or '"'"'127.0.0.1'"'"'
        host = {'"'"'0.0.0.0'"'"': '"'"'127.0.0.1'"'"', '"'"'::'"'"': '"'"'[::1]'"'"', '"'"'::1'"'"': '"'"'[::1]'"'"'}.get(host, host)
        if not port.isdigit() or not 1 <= int(port) <= 65535:
            return False
        # Only IP literals/localhost: never parse URL credentials or paths.
        if not re.fullmatch(r'"'"'[A-Za-z0-9.\[\]:-]+'"'"', host):
            return False
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open('"'"'http://{}:{}/metrics'"'"'.format(host, port), timeout=1) as response:
            data = json.loads(response.read(1024 * 1024))
        for gpu in data.get('"'"'miners'"'"', []):
            pid = gpu.get('"'"'pid'"'"')
            if not isinstance(pid, int) or gpu.get('"'"'lastStatus'"'"', '"'"''"'"').upper() in ('"'"'ERROR'"'"', '"'"'FAILED'"'"'):
                continue
            for _ in range(12):
                if pid == launcher_pid:
                    return True
                status = (Path('"'"'/proc'"'"') / str(pid) / '"'"'status'"'"').read_text()
                pid = int(next(line.split()[1] for line in status.splitlines() if line.startswith('"'"'PPid:'"'"')))
                if pid <= 1:
                    break
    except (OSError, ValueError, Failure, StopIteration, AttributeError, TypeError):
        pass
    return False


def verify_start(name, token, timeout, quiet=False):
    # Require a stable launcher with the requested token. HTTP /health may be
    # served by an old/other miner; it does not establish panel registration.
    deadline, previous, since = time.monotonic() + timeout, None, None
    next_notice = time.monotonic() + 10
    while time.monotonic() < deadline:
        pids = matching_processes(name, token)
        now = time.monotonic()
        if pids and pids == previous:
            if now - since >= 5 and any(backend_ready(pid) for pid in pids):
                return pids
        else:
            previous, since = pids, now
        if now >= next_notice:
            say("Ожидаю данные видеокарт от RGminer; первый запуск может занять до {} секунд…".format(timeout), quiet)
            next_notice = now + 10
        time.sleep(0.5)
    raise Failure("RGminer не предоставил данные работающего backend с указанным токеном. Проверьте локальный журнал майнера.", 5)


def snapshot(wallet, rig):
    folder = STATE / time.strftime('"'"'%Y%m%dT%H%M%SZ'"'"', time.gmtime())
    folder = Path(tempfile.mkdtemp(prefix=folder.name + '"'"'-'"'"', dir=str(STATE)))
    folder.chmod(0o700)
    exists = (CONFIG / '"'"'wallet.conf'"'"').exists()
    info = (CONFIG / '"'"'wallet.conf'"'"').stat() if exists else None
    atomic_write(folder / '"'"'wallet.conf'"'"', wallet)
    atomic_write(folder / '"'"'rig.conf'"'"', rig)
    atomic_write(folder / '"'"'metadata.json'"'"', json.dumps({
        '"'"'existed'"'"': exists, '"'"'mode'"'"': stat.S_IMODE(info.st_mode) if info else 0o600,
        '"'"'uid'"'"': info.st_uid if info else os.geteuid(), '"'"'gid'"'"': info.st_gid if info else os.getegid(),
    }).encode())
    atomic_write(STATE / '"'"'last-backup'"'"', str(folder).encode())
    return folder


def validate_backup(folder):
    folder = Path(folder).resolve()
    if folder.parent != STATE.resolve():
        raise Failure("Резервная копия должна находиться в {}.".format(STATE), 3)
    meta = json.loads((folder / '"'"'metadata.json'"'"').read_text())
    original = (folder / '"'"'wallet.conf'"'"').read_bytes()
    if any(not isinstance(meta.get(key), int) for key in ('"'"'mode'"'"', '"'"'uid'"'"', '"'"'gid'"'"')):
        raise Failure("Повреждены метаданные резервной копии.", 3)
    return meta, original


def restore_wallet(folder):
    meta, original = validate_backup(folder)
    if meta.get('"'"'existed'"'"', True):
        atomic_write(CONFIG / '"'"'wallet.conf'"'"', original, meta['"'"'mode'"'"'], (meta['"'"'uid'"'"'], meta['"'"'gid'"'"']))
    elif (CONFIG / '"'"'wallet.conf'"'"').exists():
        (CONFIG / '"'"'wallet.conf'"'"').unlink()


def read_wallet(path):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise Failure("wallet.conf должен быть обычным файлом; символические ссылки не поддерживаются.", 3)
    return path.read_bytes() if path.exists() else b'"'"''"'"'


def output(args, data):
    if args.json:
        print(json.dumps(data, ensure_ascii=False, sort_keys=True))
    elif data['"'"'status'"'"'] == '"'"'dry-run'"'"':
        print("Проверка: {} → {}; алгоритм {}. Изменения не внесены.".format(data['"'"'mode'"'"'], data['"'"'miner'"'"'], data['"'"'algorithm'"'"']))
    elif data['"'"'status'"'"'] == '"'"'restored'"'"':
        print("Исходный локальный полётный лист восстановлен.")
    elif data['"'"'status'"'"'] == '"'"'configured'"'"':
        print("Полётный лист записан. Запуск пропущен (--no-start).")
    elif data.get('"'"'mode'"'"') == '"'"'setup'"'"':
        print("Готово: RGminer запущен через HiveOS, API видеокарт отвечает.")
        print("Откройте https://rgminer.net, выберите риг, задайте монету, кошелёк и пул и примените настройки.")
        print("До настройки возможны нулевой хешрейт и статус TUNING. Сохранённые настройки дашборда могут примениться сразу.")
    else:
        print("Готово: RGminer запущен через HiveOS, API видеокарт отвечает.")
        print("Откройте https://rgminer.net и проверьте риг в своём аккаунте. Если риг не появился, проверьте токен на сайте.")
    if not args.json and data.get('"'"'backup'"'"') and data['"'"'status'"'"'] != '"'"'dry-run'"'"':
        print("Резервная копия: {}".format(data['"'"'backup'"'"']))
        if data['"'"'status'"'"'] != '"'"'restored'"'"':
            print("Для возврата исходного полётника запустите этот скрипт с --restore --yes.")


def parser():
    p = argparse.ArgumentParser(prog='"'"'rg-hive'"'"', allow_abbrev=False, description='"'"'Подключить риг HiveOS к RGminer через локальный полётный лист.'"'"', epilog='"'"'Пример: sudo bash rghive.sh --token TOKEN --yes\nВозврат: sudo bash rghive.sh --restore --yes\nПоддержка: https://github.com/Printscan/rgminer/issues'"'"', formatter_class=argparse.RawDescriptionHelpFormatter)
    tokens = p.add_mutually_exclusive_group()
    tokens.add_argument('"'"'-t'"'"', '"'"'--token'"'"', help='"'"'токен дашборда (попадёт в историю shell и argv)'"'"')
    tokens.add_argument('"'"'--token-file'"'"', help='"'"'прочитать токен из файла; - означает stdin'"'"')
    p.add_argument('"'"'-y'"'"', '"'"'--yes'"'"', action='"'"'store_true'"'"', help='"'"'применить без интерактивного подтверждения'"'"')
    p.add_argument('"'"'--dry-run'"'"', action='"'"'store_true'"'"', help='"'"'проверить и показать план без записи/загрузки/перезапуска'"'"')
    p.add_argument('"'"'--no-start'"'"', action='"'"'store_true'"'"', help='"'"'записать лист без запуска; для подготовки'"'"')
    p.add_argument('"'"'--restart'"'"', action='"'"'store_true'"'"', help='"'"'выполнить miner stop и miner start даже при неизменных настройках'"'"')
    modes = p.add_mutually_exclusive_group()
    modes.add_argument('"'"'--setup-only'"'"', action='"'"'store_true'"'"', help='"'"'записать заглушки и продолжить настройку в дашборде'"'"')
    modes.add_argument('"'"'--require-mining-config'"'"', action='"'"'store_true'"'"', help='"'"'остановиться, если рабочую конфигурацию нельзя перенести; без заглушек'"'"')
    p.add_argument('"'"'--restore'"'"', nargs='"'"'?'"'"', const='"'"'last'"'"', metavar='"'"'BACKUP'"'"', help='"'"'восстановить последний или указанный backup'"'"')
    p.add_argument('"'"'--miner'"'"', help='"'"'имя установленного пакета, например rgminer-1.1.4'"'"')
    p.add_argument('"'"'--algo'"'"', help='"'"'pearl, quantus, exfer-argon2id или nock-zk'"'"')
    p.add_argument('"'"'--wallet'"'"', help='"'"'кошелёк; по умолчанию берётся из активного листа'"'"')
    p.add_argument('"'"'--pool'"'"', help='"'"'пул; по умолчанию берётся из активного листа'"'"')
    p.add_argument('"'"'--package-url'"'"', help='"'"'альтернативный HTTPS-архив RGminer (требует --sha256)'"'"')
    p.add_argument('"'"'--sha256'"'"', help='"'"'ожидаемый SHA-256 архива'"'"')
    p.add_argument('"'"'--timeout'"'"', type=int, default=120, help='"'"'таймаут загрузки/запуска в секундах (по умолчанию 120)'"'"')
    p.add_argument('"'"'--json'"'"', action='"'"'store_true'"'"', help='"'"'результат в JSON, сообщения остаются в stderr'"'"')
    p.add_argument('"'"'-q'"'"', '"'"'--quiet'"'"', action='"'"'store_true'"'"', help='"'"'скрыть сообщения о ходе выполнения'"'"')
    p.add_argument('"'"'--no-input'"'"', action='"'"'store_true'"'"', help='"'"'не задавать вопросов; для автоматизации нужен --yes'"'"')
    p.add_argument('"'"'--version'"'"', action='"'"'version'"'"', version=VERSION)
    return p


def confirm(args, message):
    say(message, args.quiet)
    if args.yes:
        return
    if args.no_input or not sys.stdin.isatty():
        raise Failure("Для применения без вопросов добавьте --yes. Для проверки используйте --dry-run.", 2)
    if input('"'"'Применить? [y/N] '"'"').strip().lower() not in ('"'"'y'"'"', '"'"'yes'"'"', '"'"'д'"'"', '"'"'да'"'"'):
        raise Failure("Отменено; изменения не внесены.", 2)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    p = parser()
    if '"'"'-h'"'"' in argv or '"'"'--help'"'"' in argv:
        p.print_help()
        return 0
    if not argv:
        p.print_help()
        return 0
    args = p.parse_args(argv)
    say("Проверяю HiveOS и локальный полётный лист…", args.quiet)
    if args.restart and args.no_start:
        raise Failure("--restart и --no-start нельзя совмещать.", 2)
    if not 10 <= args.timeout <= 1800:
        raise Failure("--timeout должен быть от 10 до 1800 секунд.", 2)
    if not (CONFIG / '"'"'rig.conf'"'"').is_file() or not (HIVE / '"'"'bin/miner'"'"').is_file():
        raise Failure("HiveOS не обнаружена: нужны /hive/bin/miner и /hive-config/rig.conf.", 3)
    wallet_path = CONFIG / '"'"'wallet.conf'"'"'
    read_wallet(wallet_path)
    if os.geteuid() != 0 and not args.dry_run:
        raise Failure("Запустите скрипт через sudo или от root.", 3)
    if args.restore:
        if args.dry_run:
            raise Failure("--restore и --dry-run нельзя совмещать.", 2)
        backup = (STATE / '"'"'last-backup'"'"').read_text() if args.restore == '"'"'last'"'"' else args.restore
        validate_backup(backup)
        confirm(args, "Будет восстановлен локальный лист и перезапущен прежний майнер." if not args.no_start else "Будет восстановлен локальный лист без запуска.")
        with lock():
            if not args.no_start:
                stop_miners(args.timeout, args.quiet)
            restore_wallet(backup)
            if not args.no_start:
                say("Запускаю прежний майнер: miner start…", args.quiet)
                run_control('"'"'start'"'"', args.timeout, quiet=args.quiet)
        output(args, {'"'"'status'"'"': '"'"'restored'"'"', '"'"'backup'"'"': backup})
        return 0
    token = args.token
    if args.token_file:
        if args.token_file == '"'"'-'"'"':
            token = sys.stdin.read(4098)
        else:
            with Path(args.token_file).open() as source:
                token = source.read(4098)
        token = token.strip()
    if token is None:
        if args.no_input or not sys.stdin.isatty():
            raise Failure("Укажите --token или --token-file.", 2)
        token = getpass.getpass('"'"'Токен RGminer: '"'"')
    if not re.fullmatch(r'"'"'[A-Za-z0-9_.~-]{8,4096}'"'"', token):
        raise Failure("Токен должен содержать 8–4096 букв, цифр или символов _ . ~ - без пробелов.", 2)
    wallet_existed = wallet_path.exists()
    wallet_bytes, rig_bytes = read_wallet(wallet_path), (CONFIG / '"'"'rig.conf'"'"').read_bytes()
    new_text, plan = make_plan(rig_bytes.decode(), wallet_bytes.decode(), args, token)
    if args.package_url and plan['"'"'download'"'"']:
        # Alternative packages can name a different top-level directory.
        match = re.search(r'"'"'/((rgminer(?:-[A-Za-z0-9_.-]+)?)-hiveos\.tar\.gz)$'"'"', args.package_url)
        if not match or not args.sha256:
            raise Failure("Для альтернативного пакета нужны имя rgminer-VERSION-hiveos.tar.gz и --sha256.", 2)
        new_text = patch(new_text, {'"'"'CUSTOM_MINER'"'"': match.group(2)})
        plan['"'"'miner'"'"'] = match.group(2)
    if args.dry_run:
        output(args, dict(plan, status='"'"'dry-run'"'"'))
        return 0
    if plan['"'"'mode'"'"'] == '"'"'setup'"'"':
        reasons = {
            '"'"'unsupported-algorithm'"'"': '"'"'Текущая монета не поддерживается RGminer.'"'"',
            '"'"'missing-wallet-or-pool'"'"': '"'"'Не найдены рабочие кошелёк или пул.'"'"',
            '"'"'no-flight-sheet'"'"': '"'"'На риге ещё нет рабочего полётного листа.'"'"',
            '"'"'already-configured'"'"': '"'"'На риге уже прописаны заглушки для настройки через дашборд.'"'"',
            '"'"'requested'"'"': '"'"'Выбран режим настройки через дашборд.'"'"',
        }
        say(reasons[plan['"'"'reason'"'"']], args.quiet)
        message = "Будет сохранён исходный лист и прописаны заглушки. Перед запуском RGminer текущий майнер будет остановлен и проверен. Кошелёк и пул задайте затем в дашборде."
    else:
        message = "Будет {} RGminer; кошелёк и пул {}. Исходный лист будет сохранён. Перед запуском RGminer текущий майнер будет остановлен и проверен.".format('"'"'настроен установленный'"'"' if not plan['"'"'download'"'"'] else '"'"'установлен'"'"', '"'"'из текущего листа'"'"' if plan['"'"'wallet_detected'"'"'] and plan['"'"'pool_detected'"'"'] else '"'"'из заданных параметров'"'"')
    if args.no_start:
        message = "Будет сохранён и записан локальный полётный лист без остановки и запуска майнеров (--no-start)."
    confirm(args, message)
    with lock():
        if wallet_path.exists() != wallet_existed or read_wallet(wallet_path) != wallet_bytes or (CONFIG / '"'"'rig.conf'"'"').read_bytes() != rig_bytes:
            raise Failure("HiveOS изменил конфигурацию во время проверки. Повторите команду.", 3)
        if plan['"'"'download'"'"']:
            install_package(args, plan['"'"'miner'"'"'])
        if not local_miner(plan['"'"'miner'"'"']):
            raise Failure("Установка RGminer не прошла проверку.", 4)
        # Check again after a potentially slow package download.
        if wallet_path.exists() != wallet_existed or read_wallet(wallet_path) != wallet_bytes or (CONFIG / '"'"'rig.conf'"'"').read_bytes() != rig_bytes:
            raise Failure("Конфигурация изменилась во время загрузки. Повторите команду.", 3)
        new_bytes = new_text.encode()
        changed = new_bytes != wallet_bytes
        # A repeated successful command must not replace the original backup
        # with a backup of our already configured flight sheet.
        backup = snapshot(wallet_bytes, rig_bytes) if changed else None
        current = matching_processes(plan['"'"'miner'"'"'], token) if not args.no_start else []
        needs_start = not args.no_start and (args.restart or changed or not current or bool(foreign_miners(current)))
        stopped, wrote = False, False
        try:
            if needs_start:
                stop_miners(args.timeout, args.quiet)
                stopped = True
                if read_wallet(wallet_path) != wallet_bytes or (CONFIG / '"'"'rig.conf'"'"').read_bytes() != rig_bytes:
                    raise Failure("HiveOS изменил конфигурацию во время остановки майнера. Повторите установочную команду.", 3)
            if changed:
                say("Записываю локальный полётный лист RGminer…", args.quiet)
                atomic_write(wallet_path, new_bytes)
                wrote = True
            if not args.no_start:
                if needs_start:
                    # Hive'"'"'s agent or an external watchdog may have restarted a
                    # miner during the transition. Never start on top of it.
                    if mining_processes() or gpu_compute_pids():
                        stop_miners(args.timeout, args.quiet)
                    say("Запускаю RGminer через HiveOS: miner start…", args.quiet)
                    run_control('"'"'start'"'"', args.timeout, quiet=args.quiet)
                else:
                    say("RGminer уже работает с этим токеном; других майнеров не обнаружено. Перезапуск не нужен.", args.quiet)
                say("Проверяю запуск RGminer…", args.quiet)
                verify_start(plan['"'"'miner'"'"'], token, args.timeout, args.quiet)
                if read_wallet(wallet_path) != new_bytes:
                    raise Failure("HiveOS изменил полётный лист во время запуска.", 3)
        except BaseException:
            say("Установка не завершена.")
            # Do not overwrite a fresh flight sheet pushed by Hive meanwhile.
            if read_wallet(wallet_path) in (wallet_bytes, new_bytes):
                if wrote:
                    restore_wallet(backup)
                    say("Исходный полётный лист восстановлен.")
                if not args.no_start and stopped:
                    try:
                        stop_miners(args.timeout, args.quiet)
                        run_control('"'"'start'"'"', args.timeout, quiet=args.quiet)
                    except Failure:
                        say("Прежний майнер не запущен автоматически. Полётный лист сохранён; передайте сообщение об ошибке поддержке.")
                elif not wrote:
                    say("Полётный лист не изменён; новый RGminer не запущен.")
            else:
                say("HiveOS уже изменил лист. Его новая версия оставлена; backup: {}".format(backup))
            raise
    output(args, dict(plan, status='"'"'configured'"'"' if args.no_start else '"'"'started'"'"', backup=str(backup) if backup else None, changed=changed, restarted=bool(needs_start), panel_registration='"'"'not_verified'"'"'))
    return 0


@contextlib.contextmanager
def lock():
    STATE.mkdir(mode=0o700, parents=True, exist_ok=True)
    STATE.chmod(0o700)
    with (STATE / '"'"'lock'"'"').open('"'"'a'"'"') as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Failure("Другой экземпляр установщика уже работает.", 3)
        yield


def entry():
    def interrupted(signum, frame):
        say("Прервано; завершаю операцию с восстановлением конфигурации.")
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM, interrupted)
    try:
        return main()
    except Failure as exc:
        say(str(exc))
        return exc.code
    except KeyboardInterrupt:
        return 130
    except (OSError, ValueError, tarfile.TarError, urllib.error.URLError) as exc:
        # Do not echo exceptions that can contain config fragments or secrets.
        say("Операция не выполнена ({}). Проверьте файлы, права и соединение; повторите команду.".format(type(exc).__name__))
        return 1


if __name__ == '"'"'__main__'"'"':
    sys.exit(entry())
' "$@"
