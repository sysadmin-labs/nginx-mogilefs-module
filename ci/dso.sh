#!/bin/sh
#
# Load the module the way the FreeBSD port loads it, with load_module, and
# read a configuration that uses it.
#
# This is not a duplicate of the static build.  Up to and including the
# 1.0.4 release the module walked the ngx_modules array to create the
# location configurations for the spare locations behind mogilefs_pass.
# A dynamically loaded module is not in that array, so its own slot in
# ctx->loc_conf stayed empty and the next dereference of it took nginx
# down with SIGSEGV before it had printed a single line -- a configuration
# test exited 139 with no output at all.  Built into the binary the same
# source works, which is why nobody caught it: every test that mattered
# was a static one.
#
# usage: ci/dso.sh <nginx version>

set -eu

NGINX=${1:?nginx version missing}

SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}
PREFIX=$WORK/dso-$NGINX

"$SRC/ci/build.sh" "$NGINX" "$PREFIX" dynamic

mkdir -p "$PREFIX/conf" "$PREFIX/logs"

cat > "$PREFIX/conf/nginx.conf" <<EOF
load_module modules/ngx_http_mogilefs_module.so;
daemon off;
error_log $PREFIX/logs/error.log info;
events { worker_connections 64; }
http {
    access_log off;

    server {
        listen 127.0.0.1:18080;

        # mogilefs_pass builds spare locations behind the scenes, which is
        # the code path that used to go down here
        location /download/ {
            mogilefs_tracker 127.0.0.1:7001;
            mogilefs_domain  test;
            mogilefs_pass {
                proxy_pass \$mogilefs_path;
                proxy_hide_header Content-Type;
            }
        }

        # the same again with the write methods, so create_open and
        # create_close get their spare locations too
        location /upload/ {
            mogilefs_tracker 127.0.0.1:7001;
            mogilefs_domain  test;
            mogilefs_methods GET PUT DELETE;
            mogilefs_pass {
                proxy_pass \$mogilefs_path;
            }
        }
    }
}
EOF

echo "--- configuration test, module loaded with load_module ---"

# No pipe here on purpose.  A pipeline reports the exit status of its last
# command, so "nginx -t | head" would have turned the segmentation fault
# into a pass.
set +e
"$PREFIX/sbin/nginx" -p "$PREFIX" -c conf/nginx.conf -t > "$WORK/dso-$NGINX.out" 2>&1
status=$?
set -e

cat "$WORK/dso-$NGINX.out"

if [ "$status" -ne 0 ]; then
	echo "ci/dso.sh: nginx exited $status with the module loaded dynamically" >&2
	if [ "$status" -ge 128 ]; then
		echo "ci/dso.sh: that is signal $((status - 128)) -- the module crashed" >&2
	fi
	exit 1
fi

grep -q 'test is successful' "$WORK/dso-$NGINX.out" || {
	echo "ci/dso.sh: nginx exited 0 but did not confirm the configuration" >&2
	exit 1
}

echo "ci/dso.sh: ok, the module reads its own configuration when loaded dynamically"
