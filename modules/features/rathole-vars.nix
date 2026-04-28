{...}: {
  flake.modules.nixos.ratholeVars = {pkgs, ...}: {
    clan.core.vars.generators.rathole-tokens = {
      share = true;
      files.client-tokens = {};
      files.server-tokens = {};
      script = ''
        TOKEN_HTTP=$(openssl rand -hex 32)
        TOKEN_HTTPS=$(openssl rand -hex 32)
        TOKEN_HTTPS_UDP=$(openssl rand -hex 32)
        TOKEN_SMTP=$(openssl rand -hex 32)
        TOKEN_SUBMISSION=$(openssl rand -hex 32)
        TOKEN_IMAPS=$(openssl rand -hex 32)
        cat > $out/client-tokens <<EOF
[client.services.http]
token = "$TOKEN_HTTP"
[client.services.https]
token = "$TOKEN_HTTPS"
[client.services.https_udp]
token = "$TOKEN_HTTPS_UDP"
[client.services.smtp]
token = "$TOKEN_SMTP"
[client.services.submission]
token = "$TOKEN_SUBMISSION"
[client.services.imaps]
token = "$TOKEN_IMAPS"
EOF
        cat > $out/server-tokens <<EOF
[server.services.http]
token = "$TOKEN_HTTP"
[server.services.https]
token = "$TOKEN_HTTPS"
[server.services.https_udp]
token = "$TOKEN_HTTPS_UDP"
[server.services.smtp]
token = "$TOKEN_SMTP"
[server.services.submission]
token = "$TOKEN_SUBMISSION"
[server.services.imaps]
token = "$TOKEN_IMAPS"
EOF
      '';
      runtimeInputs = [ pkgs.openssl ];
    };
  };
}
