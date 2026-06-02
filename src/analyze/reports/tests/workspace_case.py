from __future__ import annotations

import shutil
import unittest
from pathlib import Path


class WorkspaceBackedTestCase(unittest.TestCase):
    WORKSPACE_ROOT: Path | None = None

    def setUp(self):
        workspace_root = self.WORKSPACE_ROOT
        if workspace_root is None:
            raise RuntimeError(f"{type(self).__name__} must define WORKSPACE_ROOT")

        self.workspace = workspace_root / self._testMethodName
        self.addCleanup(self._cleanup_workspace)
        self._cleanup_workspace()
        self.workspace.mkdir(parents=True)

    def _cleanup_workspace(self):
        if self.workspace.exists():
            shutil.rmtree(self.workspace)
