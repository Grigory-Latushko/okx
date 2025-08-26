import os, time, math, logging, pathlib
import yaml

def load_config(path='config.yaml'):
    with open(path, 'r') as f:
        raw = f.read()
    # Env substitution like ${VAR:default}
    def replace_env(match):
        key, default = match.group(1).split(':') if ':' in match.group(1) else (match.group(1), '')
        return os.getenv(key, default)
    import re
    patched = re.sub(r'\$\{([^}]+)\}', replace_env, raw)
    return yaml.safe_load(patched)

def setup_logging(level='INFO'):
    logging.basicConfig(
        level=getattr(logging, level.upper(), logging.INFO),
        format="%(asctime)s %(levelname)s %(message)s"
    )

def ensure_dir(p):
    pathlib.Path(p).mkdir(parents=True, exist_ok=True)
