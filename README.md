# nginx-mogilefs-module

[![Build & Test][build-test-badge]][build-test-link]
[![Function][mogtest-badge]][mogtest-link]
[![Dynamic load][dso-badge]][dso-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/build-test.yml
[mogtest-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/mogtest.yml/badge.svg
[mogtest-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/mogtest.yml
[dso-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/dso.yml/badge.svg
[dso-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/dso.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/freebsd.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-mogilefs-module/actions/workflows/lint.yml

A MogileFS client for nginx. It asks a MogileFS tracker where a key lives
and hands the answer to `proxy_pass`, so nginx serves the file straight
from the storage node that has it. Writing and deleting through the
tracker work as well.

## Requirements

nginx 1.28 or newer. Older releases are not built against; 1.9.11 is the
hard floor in the source, because that is where the module list moved into
the cycle.

A MogileFS installation to talk to — a tracker, and storage nodes that
serve over HTTP. For the test suite neither is needed: `t/tracker.pl`
speaks the protocol, and nginx itself stands in for a storage node.

## Building

Into the binary:

```sh
./configure --add-module=/path/to/nginx-mogilefs-module
make && make install
```

As a loadable module:

```sh
./configure --add-dynamic-module=/path/to/nginx-mogilefs-module
make && make install
```

```nginx
load_module modules/ngx_http_mogilefs_module.so;
```

## Quick start

```nginx
location /download/ {
    mogilefs_tracker 192.168.2.2;
    mogilefs_domain  example_domain;

    mogilefs_pass {
        proxy_pass $mogilefs_path;
        proxy_hide_header Content-Type;
        proxy_buffering off;
    }
}
```

A request for `/download/example.jpg` asks the tracker for the key
`example.jpg` and serves what comes back.

Writing and deleting belong in a location of their own, because they are
not something to expose:

```nginx
location /upload/ {
    allow 192.168.2.0/24;
    deny all;

    mogilefs_tracker 192.168.2.2;
    mogilefs_domain  example_domain;
    mogilefs_methods GET PUT DELETE;

    mogilefs_pass {
        proxy_pass $mogilefs_path;
        proxy_hide_header Content-Type;
    }
}
```

## What the tracker's answers turn into

|Tracker said|nginx answers|
|---|---|
|`unknown_key`|404|
|`domain_not_found`|404|
|`no_devices`|503|
|`no_key`|400|
|`unreg_class`|400|

## Variables

`$mogilefs_path` holds the URL of the file on the storage node with the
highest priority. `$mogilefs_path1` to `$mogilefs_path9` hold the
remaining copies, in the order the tracker gave them, so
`proxy_next_upstream` can walk them.

## Directives

### mogilefs\_pass

|Syntax |`mogilefs_pass [key] { ... }`|
|-------|---|
|Default|none|
|Context|server, location, limit\_except|

The key to ask the tracker for, and the block that fetches it.

Leave the key out and what remains of the request URI after the matched
location prefix is used. The key may contain variables.

The block needs a `proxy_pass $mogilefs_path`. nginx reaches it through a
hidden internal location that the module creates while reading the
configuration.

### mogilefs\_tracker

|Syntax |`mogilefs_tracker address`|
|-------|---|
|Default|none|
|Context|main, server, location|

The tracker to ask: an address, an address with a port, or the name of an
`upstream` block. May contain variables.

### mogilefs\_domain

|Syntax |`mogilefs_domain name`|
|-------|---|
|Default|`default`|
|Context|main, server, location|

The MogileFS domain to look in. May contain variables.

### mogilefs\_class

|Syntax |`mogilefs_class class ...`|
|-------|---|
|Default|none|
|Context|main, server, location|

The class to create a resource in. Every argument is evaluated and the
first that is not empty is used, so a fallback can be written as a second
argument. May contain variables.

### mogilefs\_methods

|Syntax |`mogilefs_methods method ...`|
|-------|---|
|Default|`GET`|
|Context|main, server, location|

Which methods reach MogileFS: `GET` fetches, `PUT` creates or replaces,
`DELETE` removes. `HEAD` follows `GET`.

### mogilefs\_noverify

|Syntax |`mogilefs_noverify on \| off`|
|-------|---|
|Default|`off`|
|Context|main, server, location|

Send `noverify=1` to the tracker, which lets it answer without checking
that the paths it hands out are reachable. Faster, and wrong more often.

### mogilefs\_connect\_timeout

|Syntax |`mogilefs_connect_timeout time`|
|-------|---|
|Default|`60s`|
|Context|main, server, location|

Cannot be longer than 75 seconds.

### mogilefs\_send\_timeout

|Syntax |`mogilefs_send_timeout time`|
|-------|---|
|Default|`60s`|
|Context|main, server, location|

### mogilefs\_read\_timeout

|Syntax |`mogilefs_read_timeout time`|
|-------|---|
|Default|`60s`|
|Context|main, server, location|

## Testing

```sh
ci/build.sh 1.30.6 /tmp/nginx-test     # build it
ci/mogtest.sh 1.30.6                   # fetch, fail over, write, delete
ci/dso.sh 1.30.6                       # the same module, loaded dynamically
```

`ci/mogtest.sh` starts `t/tracker.pl` and an nginx that is both the client
and the stand-in storage node, then walks the paths that matter: a key
that exists, one that does not, each error the tracker can return, a key
stored three times where only the third copy is actually there, and a
write followed by a read and a delete. It fails on an alert in the error
log as well, because a worker that was restarted mid-run still answers
every request.

## License

BSD 3-Clause, Valery Kholodkov's original terms. See `LICENSE`.
