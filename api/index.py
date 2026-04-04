import sys
import os
from pathlib import Path

# 添加项目根目录和 backend 目录到 Python 路径
project_root = Path(__file__).parent.parent
sys.path.insert(0, str(project_root))
sys.path.insert(0, str(project_root / 'vibe-blog' / 'backend'))

try:
    from backend.app import create_app
    app = create_app()
except ImportError as e:
    # 如果导入失败，尝试直接导入
    from app import create_app
    app = create_app()
