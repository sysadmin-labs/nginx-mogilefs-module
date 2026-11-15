# Changelog

## 1.1.0

First release from this repository. It continues Valery Kholodkov's
module, whose history is intact here: everything up to `020937f` is his.

The starting point was his last commit, not the 1.0.4 tarball that
distributions have been building, and both turned out to be broken in
different ways.

### Fixed

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
