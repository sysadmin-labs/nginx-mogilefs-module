# Every directive parses, and the configurations that are wrong are
# refused rather than quietly accepted.
#
# None of this needs a tracker: nginx reads the configuration, and
# mogilefs_pass builds its hidden locations while it does, which is the
# part that used to take the whole process down when the module was
# loaded dynamically.  ci/dso.sh covers that case; this one covers what
# the directives themselves accept.

use Test::Nginx::Socket 'no_plan';

repeat_each(1);
run_tests();

__DATA__

=== TEST 1: every directive at once
--- config
    location /download/ {
        mogilefs_tracker         127.0.0.1:7001;
        mogilefs_domain          testdomain;
        mogilefs_class           normal;
        mogilefs_methods         GET PUT DELETE;
        mogilefs_noverify        on;
        mogilefs_connect_timeout 5s;
        mogilefs_send_timeout    10s;
        mogilefs_read_timeout    15s;

        mogilefs_pass {
            proxy_pass $mogilefs_path;
            proxy_hide_header Content-Type;
        }
    }
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok
--- error_code: 200



=== TEST 2: mogilefs_pass with the key spelled out
--- config
    location /download/ {
        mogilefs_tracker 127.0.0.1:7001;
        mogilefs_pass thekey {
            proxy_pass $mogilefs_path;
        }
    }
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok



=== TEST 3: a key built from variables
--- config
    location /download/ {
        mogilefs_tracker 127.0.0.1:7001;
        mogilefs_domain  $arg_domain;
        mogilefs_pass    "prefix-$arg_k" {
            proxy_pass $mogilefs_path;
        }
    }
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok



=== TEST 4: the spare path variables exist to be used
--- config
    location /download/ {
        mogilefs_tracker 127.0.0.1:7001;
        mogilefs_pass {
            proxy_pass $mogilefs_path;
            add_header X-Copy-2 $mogilefs_path1 always;
            add_header X-Copy-9 $mogilefs_path9 always;
        }
    }
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok
--- no_error_log
unknown "mogilefs_path1" variable



=== TEST 5: mogilefs_pass without a tracker is refused
--- config
    location /download/ {
        mogilefs_pass {
            proxy_pass $mogilefs_path;
        }
    }
--- must_die
--- error_log
no tracker defined



=== TEST 6: two mogilefs_pass blocks in one location are refused
--- config
    location /download/ {
        mogilefs_tracker 127.0.0.1:7001;
        mogilefs_pass {
            proxy_pass $mogilefs_path;
        }
        mogilefs_pass {
            proxy_pass $mogilefs_path;
        }
    }
--- must_die
--- error_log
is duplicate



=== TEST 7: an unknown method is refused
--- config
    location /download/ {
        mogilefs_tracker 127.0.0.1:7001;
        mogilefs_methods GET POST;
        mogilefs_pass {
            proxy_pass $mogilefs_path;
        }
    }
--- must_die
--- error_log
invalid value



=== TEST 8: a tracker named through an upstream block
--- http_config
    upstream trackers {
        server 127.0.0.1:7001;
        server 127.0.0.1:7002 backup;
    }
--- config
    location /download/ {
        mogilefs_tracker trackers;
        mogilefs_pass {
            proxy_pass $mogilefs_path;
        }
    }
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok



=== TEST 9: a connect timeout larger than the default is accepted
--- config
    location /download/ {
        mogilefs_tracker         127.0.0.1:7001;
        mogilefs_connect_timeout 80s;
        mogilefs_pass {
            proxy_pass $mogilefs_path;
        }
    }
    location /t { return 200 "ok\n"; }
--- request
GET /t
--- response_body
ok
