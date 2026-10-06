"""Async tests run on a fresh event loop each, without needing
pytest-asyncio, so the dev extra stays small."""

from __future__ import annotations

import asyncio
import inspect

import pytest

TEST_TIMEOUT = 20


@pytest.hookimpl(tryfirst=True)
def pytest_pyfunc_call(pyfuncitem: pytest.Function) -> bool | None:
    if inspect.iscoroutinefunction(pyfuncitem.obj):
        args = {name: pyfuncitem.funcargs[name] for name in pyfuncitem._fixtureinfo.argnames}
        asyncio.run(asyncio.wait_for(pyfuncitem.obj(**args), TEST_TIMEOUT))
        return True
    return None
