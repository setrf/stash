from __future__ import annotations

from .api import create_app
from .config import load_settings
from .service_container import build_services

settings = load_settings()
services = build_services(settings)
app = create_app(services)
