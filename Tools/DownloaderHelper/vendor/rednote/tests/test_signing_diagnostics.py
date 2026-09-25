from __future__ import annotations

import tempfile
from pathlib import Path

import pytest

import app.browser as browser
import app.douyin_signing as signing
from app.errors import (
    AuthenticationRequiredError,
    DiscoveryError,
    SiteIssueCode,
    TemporaryAccessError,
)


VIDEO_URL = "https://www.douyin.com/video/7649744769275263409"
SECRET_MARKERS = (
    "attacker.invalid",
    "private-path",
    "signature-secret",
    "sessionid=cookie-secret",
)
UNTRUSTED_DETAIL = (
    "https://attacker.invalid/private-path?signature=signature-secret "
    "Cookie: sessionid=cookie-secret"
)


IDENTITY_CASES = [
    ("Douyin SSR item requested a redirect", "ssr-redirect"),
    ("Douyin SSR returned an unknown aweme", "ssr-unknown-item"),
    ("Douyin SSR returned a different aweme", "ssr-item-mismatch"),
    ("Douyin SSR returned a different author", "ssr-author-mismatch"),
    (
        "Douyin SSR returned conflicting copies of the requested aweme",
        "ssr-conflicting-items",
    ),
    ("Douyin detail API returned a different aweme", "detail-item-mismatch"),
    ("Douyin detail API returned a different author", "detail-author-mismatch"),
    (
        "Douyin detail response redirected outside its bound endpoint",
        "detail-response-redirect",
    ),
]


@pytest.mark.parametrize(
    ("message", "expected_code"),
    [
        (message, "detail-metadata-incomplete")
        for message in (
            "Douyin detail API returned no aweme detail",
            "Douyin detail API returned no author",
            "Douyin detail API returned no author identity",
            "Douyin detail response returned no complete body",
        )
    ]
    + [
        (message, "ssr-metadata-incomplete")
        for message in (
            "Douyin SSR returned no page data",
            "Douyin SSR returned no item data",
            "Douyin SSR returned no aweme detail",
            "Douyin SSR item returned no author",
            "Douyin SSR returned no valid author identity",
        )
    ]
    + [
        (message, "signer-html-invalid")
        for message in (
            "Douyin HTML redirected outside the trusted origin",
            "Douyin HTML returned an invalid HTTP status",
            "Douyin HTML returned an invalid browser response",
            "Douyin HTML returned an invalid content length",
            "Douyin HTML response could not be decoded",
            "Douyin HTML response was unexpectedly large",
            "Douyin SecSDK HTML could not be parsed",
        )
    ]
    + [
        (message, "signer-script-invalid")
        for message in (
            "Douyin returned an untrusted SecSDK script URL",
            "Douyin SecSDK marker is missing",
            "Douyin returned nested SecSDK script tags",
            "Douyin returned an incomplete SecSDK script tag",
            "Douyin returned too many SecSDK glue tags",
            "Douyin SecSDK glue was unexpectedly large",
        )
    ],
)
def test_fixed_metadata_and_signer_failures_have_specific_codes(
    message: str, expected_code: str
) -> None:
    cause = signing._SigningFailure(message)
    cause.__cause__ = RuntimeError(UNTRUSTED_DETAIL)

    assert signing._signing_diagnostic_code(cause) == expected_code
    with pytest.raises(DiscoveryError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    error = captured.value
    assert type(error) is DiscoveryError
    assert error.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert error.__cause__ is cause
    assert f"Diagnostic code: {expected_code}." in str(error)
    assert error.diagnostic_code == expected_code
    assert signing.public_signing_diagnostic_code(error) == expected_code
    assert message not in str(error)
    for secret in SECRET_MARKERS:
        assert secret not in str(error)


@pytest.mark.parametrize(("message", "expected_code"), IDENTITY_CASES)
def test_identity_failure_has_a_stable_public_diagnostic(
    message: str, expected_code: str
) -> None:
    cause = signing._IdentitySigningFailure(message)

    assert signing._signing_diagnostic_code(cause) == expected_code
    with pytest.raises(DiscoveryError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    error = captured.value
    assert type(error) is DiscoveryError
    assert error.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert error.__cause__ is cause
    assert f"Diagnostic code: {expected_code}." in str(error)
    assert error.diagnostic_code == expected_code
    assert signing.public_signing_diagnostic_code(error) == expected_code
    assert message not in str(error)


@pytest.mark.parametrize(("message", "expected_code"), IDENTITY_CASES)
def test_diagnostics_require_exact_internal_messages(
    message: str, expected_code: str
) -> None:
    cause = signing._IdentitySigningFailure(f"{message}: {UNTRUSTED_DETAIL}")

    assert signing._signing_diagnostic_code(cause) == "signing-validation-failed"
    with pytest.raises(DiscoveryError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    error = captured.value
    assert error.__cause__ is cause
    assert error.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert "Diagnostic code: signing-validation-failed." in str(error)
    assert error.diagnostic_code == "signing-validation-failed"
    assert signing.public_signing_diagnostic_code(error) == "signing-validation-failed"
    assert f"Diagnostic code: {expected_code}." not in str(error)
    for secret in SECRET_MARKERS:
        assert secret not in str(error)


@pytest.mark.parametrize(
    ("exception_type", "expected_code"),
    [
        (signing._SigningFailure, "signing-validation-failed"),
        (signing._IdentitySigningFailure, "signing-validation-failed"),
        (RuntimeError, "signing-runtime-error"),
        (ValueError, "signing-runtime-error"),
    ],
)
def test_unknown_failures_do_not_expose_untrusted_exception_text(
    exception_type: type[Exception], expected_code: str
) -> None:
    cause = exception_type(UNTRUSTED_DETAIL)

    assert signing._signing_diagnostic_code(cause) == expected_code
    with pytest.raises(DiscoveryError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    error = captured.value
    assert type(error) is DiscoveryError
    assert error.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert error.__cause__ is cause
    assert f"Diagnostic code: {expected_code}." in str(error)
    assert error.diagnostic_code == expected_code
    assert signing.public_signing_diagnostic_code(error) == expected_code
    for secret in SECRET_MARKERS:
        assert secret not in str(error)


@pytest.mark.parametrize(("message", "unused_expected_code"), IDENTITY_CASES)
def test_unknown_exception_cannot_impersonate_a_known_internal_failure(
    message: str, unused_expected_code: str
) -> None:
    cause = RuntimeError(message)

    assert signing._signing_diagnostic_code(cause) == "signing-runtime-error"
    with pytest.raises(DiscoveryError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    assert captured.value.__cause__ is cause
    assert captured.value.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert "Diagnostic code: signing-runtime-error." in str(captured.value)
    assert captured.value.diagnostic_code == "signing-runtime-error"
    assert (
        signing.public_signing_diagnostic_code(captured.value)
        == "signing-runtime-error"
    )


@pytest.mark.parametrize(
    ("detail", "expected_code"),
    [
        (
            {"aweme_id": "7649744769275263408", "author": {"sec_uid": "expected"}},
            "detail-item-mismatch",
        ),
        (
            {
                "aweme_id": "7649744769275263409",
                "author": {"sec_uid": "another-author"},
            },
            "detail-author-mismatch",
        ),
    ],
)
def test_real_detail_identity_validation_preserves_diagnostic(
    detail: dict, expected_code: str
) -> None:
    response = {
        "httpStatus": 200,
        "payload": {"status_code": 0, "aweme_detail": detail},
    }

    with pytest.raises(signing._IdentitySigningFailure) as internal:
        signing._validate_detail_response(response, "7649744769275263409", "expected")
    with pytest.raises(DiscoveryError) as public:
        signing._raise_signing_error(VIDEO_URL, internal.value)

    assert public.value.__cause__ is internal.value
    assert public.value.issue_code == SiteIssueCode.SITE_RESPONSE_CHANGED
    assert f"Diagnostic code: {expected_code}." in str(public.value)
    assert public.value.diagnostic_code == expected_code
    assert signing.public_signing_diagnostic_code(public.value) == expected_code


@pytest.mark.parametrize(
    ("category", "expected_issue"),
    [
        ("http-429", SiteIssueCode.RATE_LIMITED),
        ("api-rate-limit", SiteIssueCode.RATE_LIMITED),
        ("http-403", SiteIssueCode.REQUEST_REJECTED),
        ("http-5xx", SiteIssueCode.SITE_UNAVAILABLE),
        ("network-timeout", SiteIssueCode.NETWORK_ERROR),
        ("network-error", SiteIssueCode.NETWORK_ERROR),
        ("signer-html", SiteIssueCode.SITE_RESPONSE_CHANGED),
    ],
)
def test_transient_failures_keep_their_existing_classification(
    category: str, expected_issue: SiteIssueCode
) -> None:
    cause = signing._TransientSigningFailure(UNTRUSTED_DETAIL, category=category)

    with pytest.raises(TemporaryAccessError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    error = captured.value
    assert error.issue_code == expected_issue
    assert error.__cause__ is cause
    assert f"Reason category: {category}." in str(error)
    assert "Diagnostic code:" not in str(error)
    for secret in SECRET_MARKERS:
        assert secret not in str(error)


@pytest.mark.parametrize(
    "issue_code", [SiteIssueCode.LOGIN_REQUIRED, SiteIssueCode.VERIFICATION_REQUIRED]
)
def test_authentication_failures_keep_verification_url_and_classification(
    issue_code: SiteIssueCode,
) -> None:
    cause = signing._AuthenticationSigningFailure(
        UNTRUSTED_DETAIL, issue_code=issue_code
    )

    with pytest.raises(AuthenticationRequiredError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)

    error = captured.value
    assert error.issue_code == issue_code
    assert error.__cause__ is cause
    assert error.verification_url == VIDEO_URL
    assert "Diagnostic code:" not in str(error)
    for secret in SECRET_MARKERS:
        assert secret not in str(error)


@pytest.mark.parametrize(
    ("cause", "expected_type", "expected_issue"),
    [
        (signing._NetworkFilterSigningFailure(UNTRUSTED_DETAIL), TemporaryAccessError, SiteIssueCode.NETWORK_ERROR),
        (signing._CookieAccessSigningFailure(UNTRUSTED_DETAIL), TemporaryAccessError, SiteIssueCode.COOKIE_UNAVAILABLE),
        (RuntimeError(f"network request timed out: {UNTRUSTED_DETAIL}"), TemporaryAccessError, SiteIssueCode.NETWORK_ERROR),
        (ImportError(f"Missing browser module: {UNTRUSTED_DETAIL}"), DiscoveryError, SiteIssueCode.LOCAL_CONFIGURATION),
    ],
)
def test_operational_errors_do_not_become_generic_integrity_failures(
    cause: Exception,
    expected_type: type[Exception],
    expected_issue: SiteIssueCode,
) -> None:
    with pytest.raises(expected_type) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)
    error = captured.value
    assert type(error) is expected_type
    assert error.issue_code == expected_issue
    assert error.__cause__ is cause
    assert "Diagnostic code:" not in str(error)
    for secret in SECRET_MARKERS:
        assert secret not in str(error)


def test_cookie_access_failure_includes_safe_diagnostic_code():
    cause = signing._CookieAccessSigningFailure(
        "Chrome cookies could not be read (diagnostic: cookie_permission_denied)"
    )
    with pytest.raises(Exception) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)
    message = str(captured.value)
    assert "Diagnostic: cookie_permission_denied." in message
    assert captured.value.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert captured.value.diagnostic_code == "cookie_permission_denied"
    assert "SECRET" not in message


class _ExplodingPath(type(Path())):
    """A path whose existence probes fail, to exercise the diagnostic's own I/O."""

    def is_dir(self):
        raise PermissionError("operation not permitted")

    def is_file(self):
        raise PermissionError("operation not permitted")


@pytest.mark.parametrize(
    ("cause_text", "expected"),
    [
        ("cookie could not be decrypted with the keychain key", "cookie_decryption_failed"),
        ("operation not permitted while reading cookies", "cookie_permission_denied"),
        ("access denied to the cookie store", "cookie_permission_denied"),
        ("database is locked", "cookie_database_locked"),
        ("sqlite resource busy", "cookie_database_locked"),
    ],
)
def test_cookie_diagnostic_classifies_synthetic_local_failures(cause_text, expected):
    """Only a fixed category is returned; the original text is never echoed."""
    secret = "/Users/someone/Library/Application Support/Google/Chrome/Default"
    assert browser.chrome_cookie_diagnostic(
        "Default", PermissionError(f"{cause_text} ({secret})")
    ) == expected


def test_cookie_diagnostic_swallows_its_own_directory_probe_error():
    """R6: an OSError while probing directories must not escape the helper."""
    with tempfile.TemporaryDirectory(prefix="cookie-diagnostic-") as name:
        original = browser.chrome_user_data_directory
        try:
            browser.chrome_user_data_directory = lambda *a, **k: _ExplodingPath(name)
            assert browser.chrome_cookie_diagnostic(
                "Default", RuntimeError("generic failure")
            ) == "cookie_access_unknown"
        finally:
            browser.chrome_user_data_directory = original


def test_cookie_diagnostic_swallows_its_own_database_probe_error(monkeypatch):
    """R6: an OSError while probing the cookie database must not escape either."""
    with tempfile.TemporaryDirectory(prefix="cookie-diagnostic-") as name:
        root = Path(name)
        (root / "Default").mkdir()
        monkeypatch.setattr(browser, "chrome_user_data_directory", lambda *a, **k: root)
        monkeypatch.setattr(
            Path, "is_file", _ExplodingPath.is_file, raising=True
        )
        assert browser.chrome_cookie_diagnostic(
            "Default", RuntimeError("generic failure")
        ) == "cookie_access_unknown"


@pytest.mark.parametrize("signal", [KeyboardInterrupt, SystemExit])
def test_cookie_diagnostic_does_not_swallow_control_signals(signal, monkeypatch):
    """R6: only OSError is caught, so cancellation and interpreter exit propagate."""

    def explode(self):
        raise signal()

    monkeypatch.setattr(Path, "is_dir", explode, raising=True)
    with pytest.raises(signal):
        browser.chrome_cookie_diagnostic("Default", RuntimeError("generic"))


@pytest.mark.parametrize("profile", [None, "Default", "Profile 3", "Profile 12"])
def test_cookie_diagnostic_reports_profile_and_database_states(profile, tmp_path, monkeypatch):
    """R6: the filesystem categories stay reachable and never leak a path."""
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda *a, **k: tmp_path)
    selected = tmp_path / (profile or "Default")
    assert browser.chrome_cookie_diagnostic(profile, RuntimeError("generic")) == (
        "chrome_profile_missing"
    )
    selected.mkdir()
    assert browser.chrome_cookie_diagnostic(profile, RuntimeError("generic")) == (
        "cookie_database_missing"
    )
    (selected / "Network").mkdir()
    (selected / "Network" / "Cookies").write_bytes(b"")
    assert browser.chrome_cookie_diagnostic(profile, RuntimeError("generic")) == (
        "cookie_access_unknown"
    )


def test_cookie_diagnostic_reports_missing_chrome_data_directory(tmp_path, monkeypatch):
    """R6: an absent Chrome root is reported distinctly from an absent profile."""
    missing = tmp_path / "no-chrome-here"
    monkeypatch.setattr(
        browser, "chrome_user_data_directory", lambda *a, **k: missing
    )
    assert browser.chrome_cookie_diagnostic("Default", None) == (
        "chrome_data_directory_missing"
    )
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda *a, **k: None)
    assert browser.chrome_cookie_diagnostic("Default", None) == (
        "chrome_data_directory_missing"
    )


def test_cookie_diagnostic_reports_an_invalid_profile_name(tmp_path, monkeypatch):
    """R6: a profile outside the allowed shape is rejected without leaking it."""
    monkeypatch.setattr(browser, "chrome_user_data_directory", lambda *a, **k: tmp_path)
    assert browser.chrome_cookie_diagnostic(
        "../../etc", RuntimeError("generic")
    ) == "chrome_profile_invalid"
    assert browser.chrome_cookie_diagnostic(
        "Default/Cookies", RuntimeError("generic")
    ) == "chrome_profile_invalid"


def test_cookie_diagnostic_never_returns_an_unlisted_code():
    """R6: every returned value is inside the public whitelist."""
    assert browser.chrome_cookie_diagnostic(None, None) in browser.COOKIE_DIAGNOSTIC_CODES
    assert browser.public_cookie_diagnostic_code("") == "cookie_access_unknown"
    assert browser.public_cookie_diagnostic_code(None) == "cookie_access_unknown"
    assert browser.public_cookie_diagnostic_code(
        "cookie_permission_denied"
    ) == "cookie_permission_denied"
    # An arbitrary exception suffix must not be echoed back as a category.
    hostile = "/Users/someone/Default/Cookies permission denied secret=value"
    assert browser.public_cookie_diagnostic_code(hostile) == "cookie_access_unknown"


@pytest.mark.parametrize(
    ("diagnostic", "expected"),
    [
        ("cookie_permission_denied", "cookie_permission_denied"),
        ("cookie_database_locked", "cookie_database_locked"),
        ("cookie_decryption_failed", "cookie_decryption_failed"),
        ("chrome_profile_missing", "chrome_profile_missing"),
        (None, "cookie_access_unknown"),
        ("/Users/someone/secret permission denied", "cookie_access_unknown"),
    ],
)
def test_signing_cookie_failure_carries_only_whitelisted_codes(diagnostic, expected):
    """R5/R6: the signing chain resolves one safe category, structured and textual."""
    suffix = f" (diagnostic: {diagnostic})" if diagnostic else ""
    cause = signing._CookieAccessSigningFailure(
        f"Chrome cookies could not be read{suffix}"
    )
    if diagnostic in browser.COOKIE_DIAGNOSTIC_CODES:
        cause.cookie_diagnostic_code = diagnostic
    with pytest.raises(TemporaryAccessError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)
    error = captured.value
    assert error.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert error.diagnostic_code == expected
    assert f"Diagnostic: {expected}." in str(error)
    assert "/Users/someone" not in str(error)
    assert error.__cause__ is cause


def test_cookie_failure_is_not_relabelled_as_a_signing_integrity_failure():
    """R6: a cookie read failure must not become site_response_changed."""
    cause = signing._CookieAccessSigningFailure(
        "Chrome cookies could not be read (diagnostic: cookie_database_locked)",
        cookie_diagnostic_code="cookie_database_locked",
    )
    with pytest.raises(TemporaryAccessError) as captured:
        signing._raise_signing_error(VIDEO_URL, cause)
    error = captured.value
    assert error.issue_code == SiteIssueCode.COOKIE_UNAVAILABLE
    assert error.issue_code != SiteIssueCode.SITE_RESPONSE_CHANGED
    assert "identity or integrity validation" not in str(error)
    assert "verification page is not required" in str(error)
    assert signing.public_signing_diagnostic_code(error) == "signing-validation-failed"
