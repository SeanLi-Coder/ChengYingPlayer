"""Validate the origins and media identity used to recover default playback."""

import sys
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest
from yt_dlp.utils import DownloadCancelled

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "vendor/rednote"))

from app import downloader
from app.downloader import DownloaderConfig, MediaDownloader

URI = "v0200syntheticdefaulturi"
OTHER = "v0200otherdefaultfixture"
ITEM = "1111111111111111111"
AUTHOR = "fixture-author"
PROFILE = f"https://www.douyin.com/user/{AUTHOR}"
DIRECT = "https://v26-web.douyinvod.com/fixture.mp4"
ENDPOINT = "https://www.douyin.com/aweme/v1/play/"
QUERY = f"video_id={URI}&ratio=default"
FIFTH = ENDPOINT + "?" + QUERY + "&line=3"


@pytest.fixture
def engine():
    return MediaDownloader(DownloaderConfig(cookie_browser=None))


def rendition(urls, uri=URI):
    return {"video_uri": uri, "width": 720, "height": 1280, "urls": urls}


def blocked():
    return downloader._DouyinRedirectRejected(
        "Synthetic redirect to an unverified port",
        redirect_reason="nonstandard-port",
        redirect_port=4430,
    )


def fallback(engine, urls):
    return engine._probe_douyin_default_with_fallback(
        object(), URI, direct_candidates=[rendition(urls)],
        expected_duration=3.0, callback=None, should_cancel=lambda: False,
    )


def test_profile_cache_recovers_four_rejected_routes_via_a_real_default_probe(engine, monkeypatch):
    cached = {
        "media_kind": "video", "media_id": ITEM, "owner_id": AUTHOR, "video_uri": URI,
        "duration_ms": 3000, "direct_candidates": [rendition([FIFTH, DIRECT])],
    }
    info = engine._douyin_raw_info_from_profile_metadata(
        {"douyin_profile_media": cached, "profile_owner_verified": True, "profile_url": PROFILE},
        expected_id=ITEM, expected_profile_id=AUTHOR, verification_url=PROFILE, fallback_title="Fixture",
    )
    calls = []

    def probe(ydl, url, *, expected_duration, should_cancel):
        assert expected_duration == 3.0 and not should_cancel()
        ratio = engine._douyin_probe_context.ratio
        calls.append((ratio, url))
        if ratio == "default" and url != FIFTH:
            raise blocked()
        is_default = ratio == "default"
        return {
            "source_url": url, "url": DIRECT, "width": 1080 if is_default else 720,
            "height": 1920 if is_default else 1280, "duration": 3.0, "filesize": 4096,
            "vcodec": "h264", "acodec": "aac", "probe_prefix_size": 32,
            "probe_prefix_sha256": "b" * 64 if is_default else "a" * 64,
        }

    monkeypatch.setattr(engine, "_probe_douyin_candidate", probe)
    assert engine._add_douyin_probe_formats(
        object(), info, expected_id=ITEM, verification_url=PROFILE,
        expected_profile_id=AUTHOR, should_cancel=lambda: False,
    )
    defaults = [url for ratio, url in calls if ratio == "default"]
    assert defaults == [*engine._douyin_default_probe_urls(URI), FIFTH]
    assert ("author-feed-1", FIFTH) in calls
    chosen = next(f for f in info["formats"] if f["_douyin_requested_ratio"] == "default")
    assert (chosen["width"], chosen["height"]) == (1080, 1920)
    assert chosen["_douyin_probe_source_url"] == FIFTH
    assert chosen["_douyin_probe_prefix_sha256"] == "b" * 64


@pytest.mark.parametrize("candidate", [
    FIFTH.replace("www.douyin.com", "www.douyin.com.example"),
    FIFTH.replace("www.douyin.com", "v26-web.douyinvod.com"),
    FIFTH.replace("www.douyin.com", "www.douyin.com:4430"),
    FIFTH.replace("www.douyin.com", "name@www.douyin.com"),
    FIFTH.replace("https:", "http:"),
    FIFTH.replace("/play/", "/playwm/"),
    FIFTH.replace(URI, OTHER), FIFTH + f"&video_id={URI}",
    FIFTH + "&ratio=default", FIFTH.replace("ratio=default", "ratio=720p"),
    FIFTH.replace("&ratio=default", ""), FIFTH + "&codec_type=h264",
    FIFTH + "&line=2", FIFTH.replace("line=3", "line=-3"),
    FIFTH + "&source=other", FIFTH + "&is_play_url=0", FIFTH + "#fragment",
])
def test_unsafe_or_quality_specific_declarations_cannot_extend_default_routes(engine, candidate):
    assert engine._douyin_default_probe_urls(URI, [rendition([candidate])]) == engine._douyin_default_probe_urls(URI)


def test_routes_are_bounded_unique_and_scoped_to_this_item_and_cache(engine):
    baseline = engine._douyin_default_probe_urls(URI)
    assert len(baseline) == 4
    advertised = [FIFTH, FIFTH.replace("douyin.com", "douyin.com:443")]
    for line in range(4, 10):
        advertised.append(ENDPOINT + "?" + QUERY + f"&line={line}")
    candidates = [rendition([baseline[0], *advertised])]
    result = engine._douyin_default_probe_urls(URI, candidates)
    assert result[:4] == baseline and len(result) == 8
    assert [parse_qs(urlsplit(url).query)["line"][0] for url in result[4:]] == ["3", "4", "5", "6"]
    assert engine._douyin_default_probe_urls(URI, [rendition([FIFTH], uri=OTHER)]) == baseline
    assert engine._douyin_default_probe_urls(URI) == baseline
    assert engine._douyin_default_probe_urls(OTHER, candidates) == engine._douyin_default_probe_urls(OTHER)


def test_absent_or_exhausted_advertised_default_does_not_substitute_direct_media(engine, monkeypatch):
    attempted = []

    def reject(ydl, url, **kwargs):
        attempted.append(url)
        assert kwargs["ratio"] == "default"
        raise blocked()

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", reject)
    baseline = engine._douyin_default_probe_urls(URI)
    for urls, expected in [([DIRECT], baseline), ([DIRECT, FIFTH], [*baseline, FIFTH])]:
        attempted.clear()
        with pytest.raises(downloader._DouyinRedirectRejected) as error:
            fallback(engine, urls)
        assert error.value.redirect_port == 4430
        assert attempted == expected


def test_successful_builtin_does_not_add_unprobed_advertised_transfer_source(engine, monkeypatch):
    attempted = []

    def succeed(ydl, url, **kwargs):
        attempted.append(url)
        return {"url": DIRECT, "width": 1080, "height": 1920}

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", succeed)
    result = fallback(engine, [FIFTH])
    baseline = engine._douyin_default_probe_urls(URI)
    assert attempted == baseline[:1]
    assert result["source_candidates"] == baseline


@pytest.mark.parametrize("failure", [
    DownloadCancelled("Cancelled"),
    downloader._DouyinNoProgressTimeout("Budget exhausted"),
    downloader.MediaDownloadError("Failed media validation"),
])
def test_terminal_errors_do_not_fall_through_to_an_advertised_source(engine, monkeypatch, failure):
    calls = []

    def stop(ydl, url, **kwargs):
        calls.append(url)
        raise failure

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", stop)
    with pytest.raises(type(failure)) as caught:
        fallback(engine, [FIFTH])
    assert caught.value is failure
    assert calls == engine._douyin_default_probe_urls(URI)[:1]


def test_optional_parameters_distinguish_declared_urls_but_order_and_default_port_do_not(engine):
    baseline = engine._douyin_default_probe_urls(URI)
    original = urlsplit(baseline[0])
    origin = f"https://{original.hostname}{original.path}"
    short = origin + f"?{QUERY}&line=0"
    reordered = origin.replace(original.hostname, original.hostname + ":443") + f"?line=0&ratio=default&video_id={URI}"
    assert engine._douyin_default_probe_urls(URI, [rendition([baseline[0], reordered, short])]) == [
        *baseline, short,
    ]


def test_advertised_success_only_offers_that_verified_extra_for_transfer(engine, monkeypatch):
    later = FIFTH.replace("line=3", "line=4")
    attempted = []

    def probe(ydl, url, **kwargs):
        attempted.append(url)
        if url != FIFTH:
            raise blocked()
        return {"url": DIRECT, "width": 1080, "height": 1920}

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", probe)
    result = fallback(engine, [FIFTH, later])
    baseline = engine._douyin_default_probe_urls(URI)
    assert attempted == [*baseline, FIFTH]
    assert result["source_candidates"] == [FIFTH, *baseline]


def test_live_photo_runs_independent_default_probe_with_the_declared_route(engine, monkeypatch):
    from app.xiaohongshu import RemoteAsset

    asset = RemoteAsset(
        index=1, candidates=[DIRECT], width=720, height=1280,
        duration=3.0, video_uri=URI, quality_candidates=[rendition([DIRECT, FIFTH])],
    )
    calls = []

    def probe(ydl, url, *, ratio, expected_duration, **kwargs):
        calls.append((ratio, url))
        assert expected_duration == 3.0
        if ratio == "default" and url != FIFTH:
            raise blocked()
        return {
            "url": DIRECT, "source_url": url, "width": 1080 if ratio == "default" else 720,
            "height": 1920 if ratio == "default" else 1280, "duration": 3.0, "filesize": 4096,
            "vcodec": "h264", "acodec": "aac", "probe_prefix_sha256": "a" * 64,
            "probe_prefix_size": 32,
        }

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", probe)
    selected = engine._select_highest_douyin_live_photo_asset(
        object(), asset, callback=None, should_cancel=lambda: False,
    )
    assert [url for ratio, url in calls if ratio == "default"] == [*engine._douyin_default_probe_urls(URI), FIFTH]
    assert selected.redirect_source_url == FIFTH
    assert (selected.width, selected.height, selected.probe_prefix_size) == (1080, 1920, 32)


def test_verified_work_can_let_the_original_play_host_choose_the_line(engine, monkeypatch):
    attempted = []
    baseline = engine._douyin_default_probe_urls(URI)

    def probe(ydl, url, **kwargs):
        assert kwargs["ratio"] == "default"
        attempted.append(url)
        if url in baseline:
            raise blocked()
        source = urlsplit(url)
        assert (source.scheme, source.netloc, source.path) == (
            "https", "api-play-hl.amemv.com", "/aweme/v1/play/",
        )
        assert parse_qs(source.query) == {
            "video_id": [URI], "ratio": ["default"], "is_play_url": ["1"],
            "source": ["PackSourceEnum_AWEME_DETAIL"],
        }
        return {"url": DIRECT, "source_url": url, "width": 1440, "height": 2560}

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", probe)
    result = engine._probe_douyin_default_with_fallback(
        object(), URI, direct_candidates=[rendition([DIRECT])],
        author_rendition_verified=True, expected_duration=3.0,
        callback=None, should_cancel=lambda: False,
    )
    assert attempted[:-1] == baseline
    assert result["source_candidates"] == [attempted[-1], *baseline]


@pytest.mark.parametrize("reason", ["malformed-url", "embedded-credentials", "ip-literal"])
def test_line_negotiation_requires_a_route_error(engine, monkeypatch, reason):
    attempted = []
    failure = downloader._DouyinRedirectRejected("Synthetic rejection", redirect_reason=reason)

    def reject(ydl, url, **kwargs):
        attempted.append(url)
        raise failure

    monkeypatch.setattr(engine, "_probe_douyin_ratio_with_retry", reject)
    with pytest.raises(downloader._DouyinRedirectRejected) as caught:
        engine._probe_douyin_default_with_fallback(
            object(), URI, direct_candidates=[rendition([DIRECT])],
            author_rendition_verified=True, expected_duration=3.0,
            callback=None, should_cancel=lambda: False,
        )
    assert caught.value is failure
    assert attempted == engine._douyin_default_probe_urls(URI)
