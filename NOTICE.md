# Provenance and attribution

This repository documents and implements a Windows-oriented compatibility
workflow for `naipi11/Codex-Control-other-devices-Windows`. It combines the
public runtime technique credited below with read-only inspection of the locally
installed Codex Desktop `26.721.4979.0` package and a successful end-to-end test
on Windows 11.

The root-cause identification and runtime technique were published in
hunterbeach's public Gist,
[`dc4b74bda0e045e33f308099182b4f80`](https://gist.github.com/hunterbeach/dc4b74bda0e045e33f308099182b4f80),
which identified the inverted Statsig gate and the missing Windows device-key
backend. That Gist states that its main-process approach was derived from
[`zdaar/codex-hacks`](https://github.com/zdaar/codex-hacks/blob/main/patch_codex_remote_control.py)
and that its renderer injection pattern was adapted from
[brunolemos' feature-override Gist](https://gist.github.com/brunolemos/7466058059eae140a57a7c6a42f235ae).

The runtime source distributed in `src/runtime` is an isolated clean-room
implementation of a functional contract. Its implementer was prohibited from
reading the earlier derived prototype, the credited Gist source, or other online
workaround source. Only required behavior, API fields, and the locally installed
application's calling contract were provided. The record is in
`docs/CLEANROOM.md`.

The original engineering contributions made in this repository include that
independent code expression, a dependency-free streaming sentinel check, random
loopback ports, automatic failure rollback, verified main-Inspector shutdown, a
versioned and legacy-compatible DPAPI key store, recoverable cleanup, source
validation, and bilingual documentation. These additions must not be confused
with the upstream bug discovery or runtime technique.

The MIT license in this repository covers the independently written code and
original documentation contributed here. Referenced upstream works remain
subject to their own rights and license terms; their source text is not
redistributed here. No Codex executable, `app.asar`, OpenAI asset, or other file
from the installed application is redistributed.

OpenAI, ChatGPT, and Codex are trademarks of OpenAI. This project is unofficial
and is not endorsed by or affiliated with OpenAI.
