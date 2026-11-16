# Changelog

## 1.1.1

First release from this repository. It continues Valery Kholodkov's
module, whose history is intact here: everything up to `020937f` is his.

Two more faults turned up in review, both reachable from a tracker
response, so this replaces 1.1.0: its archive also still carried files
that had been removed from the tree after the tag was cut.

The starting point was his last commit, not the 1.0.4 tarball that
distributions have been building, and both turned out to be broken in
different ways.

### Fixed

- **A tracker response with "&&" in it spun the worker for ever.** The
  parameter loop stepped over the separator only when the parameter
  before it was not empty, so for an empty one it stayed where it was:
  `OK a=1&&b=2`, or a leading `&`, put the worker at full CPU with
  nothing written to the error log, and nothing it was serving answered
  again. `t/tracker.pl` can send such a line now and `ci/mogtest.sh`
  asks for it; the ceiling inside its `check` is what catches a worker
  that never answers.
- **A parameter with no "=" wrote past the end of the upstream buffer.**
  `ngx_strchr` has no bound and the buffer carries what the network
  delivered, unterminated: where it found an `=` beyond the line, the
  length computed from it went negative, became a very large `size_t`,
  and `ngx_unescape_uri` then decoded over that length back into the
  same place. `ngx_strlchr` with the parameter's own end now, and the
  line is refused.
- **The parameter loop had no bound either.** It walked to the first LF
  with no end to stop at. Bounded to the line the caller handed over.
- **An unchecked allocation on the write path.** `uri.data` was taken
  from `ngx_palloc` and copied into without a check, and
  `ngx_array_init` for the source list was not checked either.

- **The module crashed when loaded with `load_module`.** The hidden
  locations behind `mogilefs_pass` were created by walking `ngx_modules`,
  the array of statically linked modules. A dynamically loaded module is
  not in it, so its own slot in the location configuration stayed empty
  and the next dereference took nginx down: `nginx -t` exited on signal
  11 without printing a line. Built into the binary the same source is
  fine, which is why this survived fifteen years — and why the FreeBSD
  port, which builds it as a loadable module, has not worked at all.
  The module list now comes from `cf->cycle->modules`. Gate: `ci/dso.sh`.

- **A write never finished, and a tracker error cost sixty seconds.**
  `input_filter_init` returned without setting `u->length`, so nginx went
  on reading from the tracker after the one line it answers with, until
  end of file or `mogilefs_read_timeout`. A `GET` got away with it
  because the `X-Accel-Redirect` sends the request elsewhere anyway. A
  `PUT` did not: `create_open` was answered, the module then sat in the
  timeout, and `create_close` was never sent, so the file reached the
  storage node and the tracker never heard that it had. Every tracker
  error other than a 404 held its worker for a minute behind an answer
  the client had already received. Gates: the write checks and the
  response-time ceiling in `ci/mogtest.sh`.

- **Writes leaked a request each.** `020937f`, the last commit the
  original author made, is a merge, and it took the `r->main->count++`
  from both of its parents — leaving two of them in the `FETCH` branch of
  the write handler. The count never came back down, so every write left
  its request and its connection in the worker until
  `worker_connections` ran out. Twenty writes left twenty of them. One
  increment per step now. The 1.0.4 tarball has the opposite fault: both
  parents came after the tag, so it has no increment at all and a write
  is simply never answered. Gate: the `stub_status` count in
  `ci/mogtest.sh`.

### Changed

- `config` uses the `auto/module` form, so the module can be built
  statically or as a loadable object. The pre-1.9.11 form it carried
  could only be built in. This was a downstream patch in FreeBSD.
- `u->peer.lock` is gone; the field left nginx in 1.9. Also a downstream
  patch in FreeBSD.
- `nginx_version >= 8011` guards removed. Every release this builds
  against has been newer than 0.8.11 for fifteen years, and 1.9.11 is the
  hard floor now in any case.
- The error and success paths say what they mean on the upstream
  structure: a body length of zero and a buffer moved past the line that
  was read, as `ngx_http_memcached_module.c` does. With `input_filter_init`
  fixed this changes no measured behaviour; it is here so that a later
  change to the filter cannot revive the sixty-second wait by itself.
- `pclcf` in `create_spare_location` was set and never read. Removed.
- Sources moved to `src/`, `LICENCE` renamed to `LICENSE`, the author's
  HTML manual folded into `README.md`.

### Changed

- `u->keepalive = 1` is gone from the two error paths that set it. In
  nginx that field is read by `ngx_http_upstream_free_keepalive_peer`,
  and this module has no keepalive directive, so it always takes the
  round-robin peer, which ignores it: dead code, set on two paths out of
  three, and not mentioned in the comment that explains the two lines
  next to it.
- The sanitizer workflow builds with `-DNGX_DEBUG_PALLOC=1` and collects
  the reports through `log_path`. nginx redirects its own stderr onto the
  error log file as soon as `error_log` names one, and Test::Nginx always
  names one, so reports written to stderr were lost: ASan was noticed
  only through the worker dying, and UBSan not at all.
- Two test titles in `t/00-directives.t` said more than their body
  checked. One claimed nginx refuses a connect timeout above 75 seconds,
  which nginx does not do at all -- the 75 seconds are the default for
  `keepalive_timeout` and nothing else -- while the body asserted that
  the configuration is accepted.

### Added

- `t/tracker.pl`, a MogileFS tracker with just enough of the protocol for
  the tests, with the shapes taken from `MogileFS::Worker::Query` rather
  than guessed.
- `ci/mogtest.sh`, which walks a read, each error the tracker can return,
  a key stored three times, a write, a read-back and a delete, then counts
  what is left open in the worker.
- `ci/dso.sh`, which loads the module the way the FreeBSD port loads it.
- `t/00-directives.t` for what the directives accept and refuse.
- Continuous integration against nginx 1.28, 1.30 and 1.31, statically
  and dynamically, with sanitizers, valgrind, CodeQL and a FreeBSD run.

## 1.0.4 and earlier

Valery Kholodkov's releases. See the commit history.
