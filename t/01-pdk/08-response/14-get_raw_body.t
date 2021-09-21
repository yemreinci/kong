use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

$ENV{TEST_NGINX_NXSOCK} ||= html_dir();

plan tests => repeat_each() * (blocks() * 3);

run_tests();

__DATA__

=== TEST 1: response.get_raw_body() gets raw body
--- http_config eval: $t::Util::HttpConfig
--- config
    location = /t {
        content_by_lua_block {
            ngx.say("Hello, Content by Lua Block")
        }
        body_filter_by_lua_block {
            local PDK = require "kong.pdk"
            local pdk = PDK.new()

            local body = pdk.response.get_raw_body()
            if body then
                pdk.response.set_raw_body(body .. "Enhanced by Body Filter\n")
            end
        }
    }
--- request
GET /t
--- response_body
Hello, Content by Lua Block
Enhanced by Body Filter
--- no_error_log
[error]
