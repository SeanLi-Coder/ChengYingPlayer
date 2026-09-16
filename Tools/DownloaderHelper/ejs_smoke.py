"""Solve synthetic n/signature challenges through the real bundled yt-dlp EJS path."""

from __future__ import annotations

from js_runtime import NODE_VERSION, node_path

# Original test fixture, not downloaded player code. Its structure exercises the
# actual parser, solver extraction, Node permission mode, and output decoding.
PLAYER = """
(function() {
  function Token() { this.values = {}; }
  Token.prototype.set = function(key, value) { this.values[key] = value; };
  Token.prototype.get = function(key) { return this.values[key]; };
  Token.prototype.finish = function() {
    for (var key of ['n', 's']) {
      if (typeof this.values[key] === 'string')
        this.values[key] = this.values[key].split('').reverse().join('');
    }
  };
  function fixture(url, key, signature) {
    var token = new Token();
    token.set(key, signature);
    token.set('alr', 'yes');
    return token;
  }
}).call(this);
"""


def verify_ejs_runtime() -> str:
    from yt_dlp import YoutubeDL
    from yt_dlp.extractor.youtube import YoutubeIE
    from yt_dlp.extractor.youtube.jsc._builtin.node import NodeJCP
    from yt_dlp.extractor.youtube.jsc.provider import (
        JsChallengeRequest,
        JsChallengeType,
        NChallengeInput,
        SigChallengeInput,
    )
    from yt_dlp.extractor.youtube.pot._director import YoutubeIEContentProviderLogger

    class OfflineYoutubeDL(YoutubeDL):
        def urlopen(self, *args, **kwargs):
            raise RuntimeError("EJS bundle verification must not access the network")

    class FixtureYoutubeIE(YoutubeIE):
        def _load_player(self, video_id, player_url, fatal=True):
            return PLAYER

    path = str(node_path())
    with OfflineYoutubeDL(
        {
            "quiet": True,
            "no_warnings": True,
            "cachedir": False,
            "js_runtimes": {"node": {"path": path}},
            "remote_components": [],
        }
    ) as downloader:
        runtime = downloader._js_runtimes["node"].info
        if runtime is None or not runtime.supported or runtime.version != NODE_VERSION:
            raise RuntimeError(
                "The bundled Node runtime does not match its source lock"
            )
        ie = FixtureYoutubeIE(downloader)
        provider = NodeJCP(ie, YoutubeIEContentProviderLogger(ie, "bundle-ejs"), {})
        requests = [
            JsChallengeRequest(
                JsChallengeType.N,
                NChallengeInput("fixture:offline", ["abc123", "xyz987"]),
            ),
            JsChallengeRequest(
                JsChallengeType.SIG,
                SigChallengeInput("fixture:offline", ["sig123", "helloXYZ"]),
            ),
        ]
        responses = list(provider.bulk_solve(requests))
        if len(responses) != len(requests):
            raise RuntimeError("EJS did not solve every offline challenge")
        for request, response in zip(requests, responses, strict=True):
            expected = {value: value[::-1] for value in request.input.challenges}
            if (
                response.error
                or response.response is None
                or response.response.output.results != expected
            ):
                raise RuntimeError(
                    f"The bundled Node EJS solver failed: {response.error}"
                )
        return runtime.version
