"""生产环境不得暴露接口形状。

线上实测过一次漏网：/docs 关了、/redoc 关了，但 /openapi.json 还是 200 ——
而那份 JSON 才是最完整的那个（所有端点、所有字段、所有参数）。
关掉两个、漏掉第三个，从外面看还以为已经关严了。
"""

from app.main import doc_urls


def test_prod_exposes_nothing() -> None:
    urls = doc_urls(is_dev=False)
    assert set(urls) == {"docs_url", "redoc_url", "openapi_url"}, (
        "FastAPI 的文档入口有三个，少列一个就是一个漏网口"
    )
    for name, value in urls.items():
        assert value is None, f"生产环境下 {name} 必须是 None，实得 {value!r}"


def test_dev_exposes_docs() -> None:
    """开发环境要能用 /docs，否则调试很痛苦。"""
    urls = doc_urls(is_dev=True)
    assert urls["docs_url"] == "/docs"
    assert urls["openapi_url"] == "/openapi.json"
