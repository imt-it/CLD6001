from __future__ import annotations

import importlib.util
import sys
from pathlib import Path


TESTS_DIR = Path(__file__).resolve().parent
REPO_ROOT = TESTS_DIR.parents[3]
REPORTS_RELATIVE_ROOT = Path("src/analyze/reports")
REPORTS_SOURCE_ROOT = (REPO_ROOT / REPORTS_RELATIVE_ROOT).resolve()


def _is_relative_to(path: Path, base_dir: Path) -> bool:
    try:
        path.relative_to(base_dir)
    except ValueError:
        return False
    return True


def _is_report_source_path(path: Path) -> bool:
    return _is_relative_to(path, REPORTS_SOURCE_ROOT) and not _is_relative_to(path, TESTS_DIR)


def _purge_cached_report_modules():
    # Report tools import sibling helpers by bare module name, so clear cached
    # report-source modules before reloading to avoid cross-test state reuse.
    for module_name, module in list(sys.modules.items()):
        module_file = getattr(module, "__file__", None)
        if module_file is None:
            continue

        if _is_report_source_path(Path(module_file).resolve()):
            sys.modules.pop(module_name, None)


def _load_repo_module(
    module_name: str,
    relative_path: str | Path,
    *,
    clear_existing: bool,
):
    normalized_relative_path = str(relative_path).replace("\\", "/")
    module_path = (REPO_ROOT / normalized_relative_path).resolve()
    module_dir = str(module_path.parent)

    if _is_report_source_path(module_path):
        _purge_cached_report_modules()

    if clear_existing:
        sys.modules.pop(module_name, None)

    if module_dir not in sys.path:
        sys.path.insert(0, module_dir)

    spec = importlib.util.spec_from_file_location(module_name, module_path)
    if spec is None:
        raise ValueError(
            f"Could not load module: {module_name} from {normalized_relative_path}"
        )

    module = importlib.util.module_from_spec(spec)
    if spec.loader is None:
        raise ValueError(f"Module spec has no loader: {module_name}")

    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception:
        sys.modules.pop(module_name, None)
        raise
    return module


def load_repo_module(module_name: str, relative_path: str | Path):
    return _load_repo_module(module_name, relative_path, clear_existing=False)


def load_fresh_repo_module(module_name: str, relative_path: str | Path):
    return _load_repo_module(module_name, relative_path, clear_existing=True)


def load_reports_module(module_name: str, filename: str | Path):
    return load_repo_module(module_name, REPORTS_RELATIVE_ROOT / filename)
