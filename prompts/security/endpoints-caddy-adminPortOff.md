Prompt:

list endpoints, and architectuer, and we disable caddy admin

----
why->

admin 0.0.0.0:2019 in both Caddyfiles — Caddy's admin API, which can load arbitrary config, bound to every interface in the container network. Turning it off:

