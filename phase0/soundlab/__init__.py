"""Shared code for the Phase 0 test scripts.

Every function here treats your sound and music folders as read-only. Results
go to a separate output folder (default: ~/SoundLab).
"""

import os

# Let PyTorch run any operation the Apple GPU (MPS) lacks on the CPU instead of failing.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

__version__ = "0.1.0"
