use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

$ENV{TEST_NGINX_NXSOCK} ||= html_dir();

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: response.set_raw_body() sets raw body
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
        }
        header_filter_by_lua_block {
            ngx.status = 200
            ngx.header["Content-Length"] = nil
        }
        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            pdk.response.set_raw_body("Hello, World!\n")
        }
    }
--- request
GET /t
--- response_body
Hello, World!
--- no_error_log
[error]
