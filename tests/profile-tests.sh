#!/usr/bin/env bash

test_profile_import_default_and_show() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'Profile test install succeeds'; return; }
  local source=$TEST_HOME/source/work.conf cli=$HOME/.local/bin/proxycode output password source_hash
  write_wireguard_config "$source"
  source_hash=$(/usr/bin/sha256sum "$source")

  output=$("$cli" profile import "$source" --name work --default) || { fail 'Profile import succeeds'; return; }
  assert_eq $'Imported Tunnel Profile: work\nDefault Tunnel Profile: work' "$output" 'Profile import output'
  assert_eq 'work' "$("$cli" profile list)" 'Profile list output'
  assert_eq $'Name: work\nDefault: yes\nProbe: cloudflare\nExpected location: any' "$("$cli" profile show work)" 'Profile show output'
  assert_eq 'HTTP port: 25345' "$("$cli" settings)" 'default listener settings'

  local profile=$XDG_DATA_HOME/proxycode/profiles/work
  assert_eq "$source_hash" "$(/usr/bin/sha256sum "$source")" 'import leaves the source unchanged'
  cmp -s "$source" "$profile/wireguard.conf" || fail 'import copies the source unchanged'
  [[ -e $HOME/proxycode-must-not-evaluate-input ]] && fail 'import evaluates WireGuard input'
  assert_mode "$XDG_CONFIG_HOME/proxycode" 700
  assert_mode "$XDG_CONFIG_HOME/proxycode/settings" 600
  assert_mode "$profile" 700
  assert_mode "$profile/wireguard.conf" 600
  assert_mode "$profile/wireproxy.conf" 600
  assert_mode "$profile/settings" 600
  assert_mode "$profile/proxy-credential" 600
  grep -q '^WGConfig = wireguard.conf$' "$profile/wireproxy.conf" || fail 'generated config uses the private copy'
  assert_eq 1 "$(grep -c '^\[' "$profile/wireproxy.conf")" 'generated config has one listener'
  grep -q '^BindAddress = 127.0.0.1:25345$' "$profile/wireproxy.conf" || fail 'HTTP listener is loopback-only'
  grep -q '^USERNAME=proxy-code$' "$profile/proxy-credential" || fail 'credential has the fixed username'
  password=$(sed -n 's/^PASSWORD=//p' "$profile/proxy-credential")
  [[ $password =~ ^[0-9a-f]{96}$ ]] || fail 'credential has a URL-safe generated password'
  grep -q '^Username = proxy-code$' "$profile/wireproxy.conf" || fail 'HTTP listener uses the fixed username'
  grep -q "^Password = $password$" "$profile/wireproxy.conf" || fail 'HTTP listener uses the stored password'
  [[ $output != *"$password"* ]] || fail 'import output exposes the credential'
}

test_profile_replacement_and_validation_rollback() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'replacement test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile before credential output status
  write_wireguard_config "$source"
  output=$(WIREPROXY_CONFIGTEST_FAIL=1 "$cli" profile import "$source" --name rejected 2>&1)
  status=$?
  assert_eq 1 "$status" 'new Profile validation failure status'
  [[ ! -e $XDG_DATA_HOME/proxycode/profiles/rejected ]] || fail 'failed validation leaves a new Profile behind'
  "$cli" profile import "$source" --name work --default >/dev/null || { fail 'baseline Profile import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work
  "$cli" profile settings work --probe mullvad --expect-location Singapore >/dev/null || { fail 'replacement setup preserves health settings'; return; }
  credential=$(<"$profile/proxy-credential")

  printf '\n# replacement\n' >>"$source"
  output=$("$cli" profile import "$source" --name work 2>&1)
  status=$?
  assert_eq 2 "$status" 'duplicate import requires replacement'
  [[ $output == *'use --replace'* ]] || fail 'duplicate import gives replacement guidance'

  output=$("$cli" profile import "$source" --name work --replace 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive replacement requires consent'
  before=$(/usr/bin/sha256sum "$profile/"*)
  output=$(WIREPROXY_CONFIGTEST_FAIL=1 "$cli" profile import "$source" --name work --replace --yes 2>&1)
  status=$?
  assert_eq 1 "$status" 'replacement validation failure status'
  [[ $output == *'validation failed'* ]] || fail 'replacement validation failure is safe and actionable'
  [[ $output != *'must-not-print'* ]] || fail 'replacement prints raw validation output'
  assert_eq "$before" "$(/usr/bin/sha256sum "$profile/"*)" 'failed replacement preserves the Profile'

  output=$("$cli" profile import "$source" --name work --replace --yes) || { fail 'confirmed replacement succeeds'; return; }
  assert_eq 'Replaced Tunnel Profile: work' "$output" 'replacement output'
  cmp -s "$source" "$profile/wireguard.conf" || fail 'replacement installs the new private copy'
  assert_eq "$credential" "$(<"$profile/proxy-credential")" 'replacement preserves the Proxy credential'
  assert_eq $'Probe: mullvad\nExpected location: Singapore' "$("$cli" profile settings work)" 'replacement preserves health settings'
  assert_eq 'work' "$(sed -n 's/^DEFAULT_PROFILE=//p' "$XDG_CONFIG_HOME/proxycode/settings")" 'replacement preserves the Default'
}

test_global_and_profile_settings() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'settings test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf profile output status config_before
  write_wireguard_config "$source"
  "$cli" profile import "$source" --name work >/dev/null || { fail 'settings test import succeeds'; return; }
  profile=$XDG_DATA_HOME/proxycode/profiles/work

  assert_eq $'Probe: cloudflare\nExpected location: any' "$("$cli" profile settings work)" 'default Profile probe settings'
  assert_eq $'Probe: mullvad\nExpected location: Singapore' "$("$cli" profile settings work --probe mullvad --expect-location Singapore)" 'Mullvad probe settings'
  assert_eq $'Probe: custom\nURL: https://example.test/health\nStatus: 204\nContains: configured' "$("$cli" profile settings work --probe custom --url https://example.test/health --status 204 --contains ready)" 'custom probe settings'
  grep -q '^CONTAINS=ready$' "$profile/settings" || fail 'custom literal is stored privately'

  output=$("$cli" profile settings work --probe cloudflare --expect-location Singapore 2>&1)
  status=$?
  assert_eq 2 "$status" 'invalid Cloudflare country status'
  [[ $output == *'two uppercase ASCII letters'* ]] || fail 'invalid Cloudflare country is explained'
  assert_eq $'Probe: custom\nURL: https://example.test/health\nStatus: 204\nContains: configured' "$("$cli" profile settings work)" 'invalid probe update changes nothing'
  output=$("$cli" profile settings work --probe custom --url http://example.test --status 200 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-HTTPS custom probe status'
  [[ $output == *'must use HTTPS'* ]] || fail 'non-HTTPS custom probe is explained'
  output=$("$cli" profile settings work --probe custom --url https://user@example.test --status 200 2>&1)
  status=$?
  assert_eq 2 "$status" 'credential-bearing custom probe status'
  [[ $output == *'no credentials'* ]] || fail 'credential-bearing custom probe is explained'
  for invalid_url in 'https://example.test/a b' https://example.test:99999; do
    output=$("$cli" profile settings work --probe custom --url "$invalid_url" --status 200 2>&1)
    status=$?
    assert_eq 2 "$status" "invalid custom probe URL status: $invalid_url"
  done

  config_before=$(/usr/bin/sha256sum "$profile/wireproxy.conf")
  assert_eq 'HTTP port: 31080' "$("$cli" settings --http-port 31080)" 'global port update'
  assert_eq "$config_before" "$(/usr/bin/sha256sum "$profile/wireproxy.conf")" 'port update leaves derived Profile config for activation to regenerate'
  ! grep -q '_PORT=' "$profile/settings" || fail 'Profile settings duplicate the global port'
  output=$("$cli" settings --http-port 65536 2>&1)
  status=$?
  assert_eq 2 "$status" 'out-of-range listener port status'
  output=$("$cli" settings --http-port 18446744073709551617 2>&1)
  status=$?
  assert_eq 2 "$status" 'overflowing listener port status'
  assert_eq 'HTTP port: 31080' "$("$cli" settings)" 'invalid port update changes nothing'
}

test_profile_default_name_validation_and_removal() {
  TESTS=$((TESTS + 1))
  new_home
  install_custom_binary >/dev/null || { fail 'removal test install succeeds'; return; }
  local cli=$HOME/.local/bin/proxycode source=$TEST_HOME/source/work.conf output status
  write_wireguard_config "$source"

  assert_status 2 'missing Profile show status' "$cli" profile show missing
  assert_status 2 'missing Profile settings show status' "$cli" profile settings missing
  assert_status 2 'missing Profile settings update status' "$cli" profile settings missing --probe cloudflare
  assert_status 2 'missing Profile default status' "$cli" profile default missing
  assert_status 2 'missing Profile removal status' "$cli" profile remove missing --yes
  assert_status 2 'unreadable import source status' "$cli" profile import "$TEST_HOME/missing.conf" --name missing

  "$cli" profile import "$source" --name work >/dev/null || { fail 'non-Default Profile import succeeds'; return; }
  assert_eq $'Name: work\nDefault: no\nProbe: cloudflare\nExpected location: any' "$("$cli" profile show work)" 'first Profile is not implicitly Default'
  assert_eq 'Default Tunnel Profile: work' "$("$cli" profile default work)" 'explicit Default selection'

  output=$("$cli" profile import "$source" --name ../escape 2>&1)
  status=$?
  assert_eq 2 "$status" 'unsafe Profile name status'
  [[ $output == *'invalid Tunnel Profile name'* ]] || fail 'unsafe Profile name is explained'
  [[ ! -e $XDG_DATA_HOME/proxycode/escape ]] || fail 'unsafe Profile name escapes the store'

  output=$("$cli" profile remove work 2>&1)
  status=$?
  assert_eq 2 "$status" 'non-interactive removal requires consent'
  [[ -d $XDG_DATA_HOME/proxycode/profiles/work ]] || fail 'unconfirmed removal changes the Profile'
  assert_eq 'Removed Tunnel Profile: work' "$("$cli" profile remove work --yes)" 'confirmed removal output'
  output=$("$cli" profile list)
  status=$?
  assert_eq 0 "$status" 'empty Profile list status'
  assert_eq '' "$output" 'removed Profile is absent from list'
  assert_eq '' "$(sed -n 's/^DEFAULT_PROFILE=//p' "$XDG_CONFIG_HOME/proxycode/settings")" 'removing Default clears it without choosing another'
  [[ -f $source ]] || fail 'Profile removal touches the source configuration'
}

