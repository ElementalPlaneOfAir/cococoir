{...}: {
  flake.modules.nixos.ratholeVars = {pkgs, ...}: {
    clan.core.vars.generators.rathole-tokens = {
      share = true;
      files.tokens = {};
      script = ''
        TOKEN_HTTP=$(openssl rand -hex 32)
        TOKEN_HTTPS=$(openssl rand -hex 32)
        cat > $out/tokens <<EOF
[client.services.http]
token = "$TOKEN_HTTP"
[client.services.https]
token = "$TOKEN_HTTPS"
[server.services.http]
token = "$TOKEN_HTTP"
[server.services.https]
token = "$TOKEN_HTTPS"
EOF
      '';
      runtimeInputs = [ pkgs.openssl ];
    };
  };
}
