"""Unicode filename regressions with synthetic names and isolated local state."""

from __future__ import annotations

import errno
import socket
import sys
import threading
import unicodedata
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "vendor/rednote"))

from app import downloader as engine
from app.errors import MediaDownloadError, SiteIssueCode, classify_site_issue
from app.models import JobStatus, OutputLayout, Platform
from app.task_manager import DownloadManager
from filename_smoke import verify_filename_runtime


@pytest.fixture(autouse=True)
def isolated_runtime(monkeypatch, tmp_path):
    def forbidden(*args, **kwargs):
        raise AssertionError("This test must not connect to a network or resolve DNS")

    for method in ("connect", "connect_ex", "sendto", "sendmsg"):
        if hasattr(socket.socket, method):
            monkeypatch.setattr(socket.socket, method, forbidden)
    for method in ("create_connection", "getaddrinfo", "gethostbyname", "gethostbyname_ex", "gethostbyaddr"):
        monkeypatch.setattr(socket, method, forbidden)
    monkeypatch.setattr(
        "app.browser.chrome_user_data_directory",
        lambda *args, **kwargs: tmp_path / "synthetic-chrome",
    )


def maximum_decomposed_mark_run(value):
    """Count nonzero canonical-combining classes after decomposition."""
    maximum = consecutive = 0
    for character in unicodedata.normalize("NFD", value):
        if unicodedata.combining(character):
            consecutive += 1
            maximum = max(maximum, consecutive)
        else:
            consecutive = 0
    return maximum


def test_bundled_filename_runtime_verifies_unicode_with_private_temporary_files():
    assert verify_filename_runtime() == "unicode-author-and-media-names-verified-offline"


@pytest.mark.parametrize(
    "codepoint", [0x0378, *range(0xFFF0, 0xFFF9), 0xFFFE, 0xFFFF],
    ids=lambda codepoint: f"U+{codepoint:04X}",
)
def test_unassigned_and_noncharacter_codepoints_are_replaced(codepoint, tmp_path):
    character = chr(codepoint)
    assert unicodedata.category(character) == "Cn"
    component = engine.safe_component(f"Author{character}Name")
    assert component == "Author_Name"
    destination = tmp_path / component
    destination.mkdir()
    assert destination.is_dir()


@pytest.mark.parametrize(
    "codepoints",
    [(0xD800,), (0xDBFF,), (0xDC00,), (0xDFFF,), (0xD800, 0xDC00)],
    ids=["high-start", "high-end", "low-start", "low-end", "surrogate-pair"],
)
def test_surrogates_are_replaced_before_utf8_encoding(codepoints, tmp_path):
    value = "".join(chr(codepoint) for codepoint in codepoints)
    component = engine.safe_component(f"Author{value}Name")
    assert component == "Author" + "_" * len(value) + "Name"
    assert component.encode("utf-8").decode("utf-8") == component
    destination = tmp_path / component
    destination.mkdir()
    assert destination.is_dir()


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("中文作者", "中文作者"),
        ("日本語の作者", "日本語の作者"),
        ("Café", "Café"),
        ("Cafe\u0301", "Café"),
        ("A\u030aland", "Åland"),
        ("ＡＢＣ１２３", "ABC123"),
        ("Author\ue000Name", "Author\ue000Name"),
        ("Author\U000f0000Name", "Author\U000f0000Name"),
        ("Developer 👩\u200d💻", "Developer 👩\u200d💻"),
        ("Heart ❤️", "Heart ❤️"),
    ],
    ids=["chinese", "japanese", "accented", "decomposed-accent", "decomposed-ring",
         "compatibility", "private-bmp", "private-astral", "emoji-zwj", "emoji-variation"],
)
def test_supported_unicode_names_keep_their_existing_meaning(value, expected, tmp_path):
    component = engine.safe_component(value)
    assert component == expected
    assert engine.safe_component(component) == component
    destination = tmp_path / component
    destination.mkdir()
    assert destination.is_dir()


@pytest.mark.parametrize(
    ("value", "expected"),
    [
        ("  Author\t Name  ", "Author_ Name"),
        ("A/B\\C:D*E?F\"G<H>I|J", "A_B_C_D_E_F_G_H_I_J"),
        ("../../Author", "Author"),
        ("...Author...", "Author"),
        ("CON", "_CON"),
        ("NUL.txt", "_NUL.txt"),
        ("COM1.log", "_COM1.log"),
    ],
)
def test_unicode_safety_keeps_path_and_reserved_name_rules(value, expected):
    assert engine.safe_component(value) == expected


@pytest.mark.parametrize("value", [None, "", "\ufff4", "\ud800\udfff"])
def test_names_with_no_supported_characters_use_the_requested_fallback(value):
    assert engine.safe_component(value, fallback="Fallback Author") == "Fallback Author"


@pytest.mark.parametrize(
    ("value", "limit", "expected"),
    [
        ("a" * 200, 120, "a" * 120),
        ("汉" * 100, 120, "汉" * 40),
        ("😀" * 100, 120, "😀" * 30),
        ("a" * 119 + "汉", 120, "a" * 119),
        ("a" * 200, 24, "a" * 24),
        ("汉字abc", 8, "汉字ab"),
    ],
)
def test_utf8_length_limits_still_end_at_a_complete_codepoint(value, limit, expected):
    assert engine.safe_component(value, limit=limit) == expected
    if limit == 120:
        assert engine.safe_component(value) == expected
    assert len(expected.encode("utf-8")) <= limit


@pytest.mark.parametrize("mark", ["\u0301", "\u0327", "\u0338"], ids=["acute", "cedilla", "overlay"])
@pytest.mark.parametrize("count", [1, 30, 31])
def test_mark_runs_within_the_filesystem_boundary_remain_unchanged(mark, count):
    value = "a" + mark * count
    expected = unicodedata.normalize("NFKC", value)
    assert maximum_decomposed_mark_run(expected) == count
    assert engine.safe_component(value) == expected


@pytest.mark.parametrize("mark", ["\u0301", "\u0327", "\u0338"], ids=["acute", "cedilla", "overlay"])
@pytest.mark.parametrize("count", [32, 64, 256])
def test_long_mark_runs_are_bounded_after_canonical_decomposition(mark, count, tmp_path):
    component = engine.safe_component("a" + mark * count)
    assert component.startswith(unicodedata.normalize("NFC", "a" + mark))
    assert maximum_decomposed_mark_run(component) <= 31
    assert unicodedata.normalize("NFC", component) == component
    assert len(component.encode("utf-8")) <= 120
    assert engine.safe_component(component) == component
    destination = tmp_path / component
    destination.mkdir()
    assert destination.is_dir()


def test_precomposed_base_counts_its_decomposed_accent_towards_the_boundary(tmp_path):
    value = "á" + "\u0301" * 31
    assert maximum_decomposed_mark_run(value) == 32
    component = engine.safe_component(value)
    assert maximum_decomposed_mark_run(component) <= 31
    destination = tmp_path / component
    destination.mkdir()
    assert destination.is_dir()


def test_mark_limit_resets_after_each_base_character():
    value = "a" + "\u0301" * 31 + "b" + "\u0301" * 31
    assert engine.safe_component(value, limit=240) == unicodedata.normalize("NFKC", value)


@pytest.mark.parametrize("separator", ["\u034f", "\u093e", "\u20dd", "\ufe0f"],
                         ids=["grapheme-joiner", "spacing-vowel", "enclosing-mark", "variation-selector"])
def test_zero_combining_class_marks_are_preserved_and_reset_the_run(separator, tmp_path):
    assert unicodedata.category(separator).startswith("M")
    assert unicodedata.combining(separator) == 0
    value = "a" + separator * 64
    component = engine.safe_component(value, limit=240)
    assert component == unicodedata.normalize("NFKC", value)
    destination = tmp_path / component
    destination.mkdir()
    assert destination.is_dir()
    separated = "a" + "\u0301" * 31 + separator + "\u0301" * 31
    assert engine.safe_component(separated, limit=240) == unicodedata.normalize("NFKC", separated)


@pytest.mark.skipif(sys.platform != "darwin", reason="The original filesystem failure is macOS-specific")
@pytest.mark.parametrize("value", ["Fixture\ufff4Author", "a" + "\u0301" * 32],
                         ids=["unassigned-FFF4", "32-decomposed-marks"])
def test_macos_rejects_the_original_fixture_and_accepts_the_sanitized_name(tmp_path, value):
    with pytest.raises(OSError) as caught:
        (tmp_path / value).mkdir()
    assert caught.value.errno == 92
    destination = tmp_path / engine.safe_component(value)
    destination.mkdir()
    assert destination.is_dir()


@pytest.fixture(params=[OutputLayout.AUTHOR, OutputLayout.PLATFORM_AUTHOR], ids=["native", "legacy"])
def manager(tmp_path, request):
    value = DownloadManager(
        state_dir=tmp_path / "state", default_output_root=tmp_path / "selected",
        new_job_output_layout=request.param,
    )
    try:
        yield value
    finally:
        value.shutdown()


@pytest.mark.parametrize(
    ("platform", "url"),
    [(Platform.DOUYIN, "https://www.douyin.com/user/fixture-author"),
     (Platform.KUAISHOU, "https://www.kuaishou.com/profile/3xowner1")],
    ids=["douyin", "kuaishou"],
)
@pytest.mark.parametrize(
    "author", ["Fixture\ufff4Author", "Fixture\ud800Author", "a" + "\u0301" * 32,
               "中文作者", "Developer 👩\u200d💻"],
    ids=["unassigned", "surrogate", "combining-limit", "chinese", "emoji"],
)
def test_manager_creates_real_safe_author_folders_in_both_layouts(manager, platform, url, author):
    job = manager.create_job(url, cookie_browser=None, auto_start=False)
    destination = manager._prepare_output_directory(job, author)
    selected = Path(job.output_root)
    expected_parent = (
        selected / "Kuaishou"
        if platform == Platform.KUAISHOU and job.output_layout == OutputLayout.PLATFORM_AUTHOR
        else selected
    )
    assert destination == expected_parent / engine.safe_component(author)
    assert destination.is_dir()
    assert destination.parent == expected_parent
    assert maximum_decomposed_mark_run(destination.name) <= 31
    assert len(destination.name.encode("utf-8")) <= 120


@pytest.mark.parametrize("error_code", [92, errno.EACCES, errno.ENOSPC],
                         ids=["invalid-unicode", "permission", "storage-full"])
def test_local_directory_failure_keeps_errno_and_persists_local_issue(
    manager, monkeypatch, error_code
):
    job = manager.create_job(
        "https://www.douyin.com/user/fixture-author", cookie_browser=None, auto_start=False,
    )
    author = "Private Fixture Author"
    expected = Path(job.output_root) / author
    original_mkdir = Path.mkdir
    failures = []

    def denied_mkdir(directory, *args, **kwargs):
        if directory == expected:
            failure = OSError(error_code, "Synthetic private filesystem failure", str(directory))
            failures.append(failure)
            raise failure
        return original_mkdir(directory, *args, **kwargs)

    monkeypatch.setattr(Path, "mkdir", denied_mkdir)
    with pytest.raises(MediaDownloadError) as caught:
        manager._prepare_output_directory(job, author)
    assert caught.value.issue_code == SiteIssueCode.LOCAL_CONFIGURATION
    assert caught.value.__cause__ is failures[0]
    assert caught.value.__cause__.errno == error_code
    assert str(caught.value) == "The author download folder could not be prepared"
    manager._jobs[job.id].author = author
    manager._run_job(job.id, [], False, threading.Event())
    failed = manager.get_job(job.id)
    persisted = manager.store.get(job.id)
    assert failed.status == persisted.status == JobStatus.FAILED
    assert failed.issue_code == persisted.issue_code == SiteIssueCode.LOCAL_CONFIGURATION
    assert failed.error == persisted.error == str(caught.value)
    assert str(expected) not in failed.error
    assert author not in failed.error
    assert len(failures) == 2
    assert not expected.exists()


def test_generic_media_errors_are_not_reclassified_as_local_folder_errors():
    assert classify_site_issue(MediaDownloadError("Synthetic unknown media failure")) == SiteIssueCode.UNKNOWN
