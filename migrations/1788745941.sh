echo "Move Kitty defaults into the system config and restrict remote control to its local socket"

kitty_config="$HOME/.config/kitty/kitty.conf"
# config/kitty/kitty.conf as shipped after 008f3a22 (Kitty cwd lookup).
stock_sha="856cd466bf568d091cb775c5b90d1852178090a419f492fde02a4eaef6407bf9"
unrestricted='^[[:space:]]*allow_remote_control[[:space:]]+(yes|y|true)[[:space:]]*$'

if [[ -f $kitty_config ]]; then
  changed=false

  if [[ $(sha256sum "$kitty_config" | cut -d ' ' -f 1) == $stock_sha ]]; then
    omarchy-refresh-config kitty/kitty.conf
    changed=true
  elif grep -qE "$unrestricted" "$kitty_config"; then
    # Preserve customizations and ordering. An otherwise stock line can be an
    # intentional override of an earlier include or mapping.
    backup=$(mktemp "$kitty_config.bak.XXXXXX")
    cp -p "$kitty_config" "$backup"
    sed --follow-symlinks -i -E "s/$unrestricted/# &/" "$kitty_config"
    echo "Commented out unrestricted Kitty remote control. Saved backup as $backup."
    changed=true
  fi

  if [[ $changed == "true" ]]; then
    # Kitty reads allow_remote_control at startup; config reload is insufficient.
    echo "Close and reopen all Kitty windows to apply the remote-control restriction."
  fi
fi
