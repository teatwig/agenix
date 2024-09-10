{
  config,
  options,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.age;

  isDarwin = lib.attrsets.hasAttrByPath ["environment" "darwinConfig"] options;

  ageBin = config.age.ageBin;

  users = config.users.users;

  mountCommand =
    if isDarwin
    then ''
      if ! diskutil info "${cfg.secretsMountPoint}" &> /dev/null; then
          num_sectors=1048576
          dev=$(hdiutil attach -nomount ram://"$num_sectors" | sed 's/[[:space:]]*$//')
          newfs_hfs -v agenix "$dev"
          mount -t hfs -o nobrowse,nodev,nosuid,-m=0751 "$dev" "${cfg.secretsMountPoint}"
      fi
    ''
    else ''
      grep -q "${cfg.secretsMountPoint} ramfs" /proc/mounts ||
        mount -t ramfs none "${cfg.secretsMountPoint}" -o nodev,nosuid,mode=0751
    '';
  # `basename ""` (empty quotes in case readLink fails) always exits with 0, which means the "echo 0" is never called
  # this is an issue in the original agenix, but doesn't matter since the line after immediately increments it, and `(( ++emptyVal ))` works as if emptyVal was 0
  newGeneration = ''
    _prev_generation="$(basename "$(readlink "${cfg.secretsDir}" || echo 0)")"
    _agenix_generation=$(( _prev_generation + 1 ))
    echo "[agenix] creating new generation in ${cfg.secretsMountPoint}/$_agenix_generation"
    mkdir -p "${cfg.secretsMountPoint}"
    chmod 0751 "${cfg.secretsMountPoint}"
    ${mountCommand}
    mkdir -p "${cfg.secretsMountPoint}/$_agenix_generation"
    chmod 0751 "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  chownGroup =
    if isDarwin
    then "admin"
    else "keys";
  # chown the secrets mountpoint and the current generation to the keys group
  # instead of leaving it root:root.
  chownMountPoint = ''
    chown :${chownGroup} "${cfg.secretsMountPoint}" "${cfg.secretsMountPoint}/$_agenix_generation"
  '';

  setTruePath = secretType: ''
    ${
      if secretType.symlink
      # question: do we just inherit $_agenix_generation from newGeneration despite it being a separate activation script?
      # looks like it...
      then ''
        _truePath="${cfg.secretsMountPoint}/$_agenix_generation/${secretType.name}"
        _prevTruePath="${cfg.secretsMountPoint}/$_prev_generation/${secretType.name}"
      ''
      else ''
        _truePath="${secretType.path}"
        _prevTruePath="${secretType.path}"
      ''
    }
  '';

  # empty if either file doesn't exist
  setHash = file: truePath: let
    hashFiles = files:
      lib.concatMapStrings (f: ''$(md5sum "${f}" 2>/dev/null | cut -d' ' -f1)'') files;
  in ''
    _hash=""
    if [ -f "${file}" ] && [ -f "${truePath}" ]; then
      _hash="${hashFiles [ file truePath ]}"
    fi
  '';

  decryptToNewGeneration = secretType: ''
    echo "[agenix] decrypting '${secretType.file}' to '$_truePath'..."
    TMP_FILE="$_truePath.tmp"

    IDENTITIES=()
    for identity in ${toString cfg.identityPaths}; do
      test -r "$identity" || continue
      test -s "$identity" || continue
      IDENTITIES+=(-i)
      IDENTITIES+=("$identity")
    done

    test "''${#IDENTITIES[@]}" -eq 0 && echo "[agenix] WARNING: no readable identities found!"

    mkdir -p "$(dirname "$_truePath")"
    [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && mkdir -p "$(dirname "${secretType.path}")"
    (
      umask u=r,g=,o=
      test -f "${secretType.file}" || echo '[agenix] WARNING: encrypted file ${secretType.file} does not exist!'
      test -d "$(dirname "$TMP_FILE")" || echo "[agenix] WARNING: $(dirname "$TMP_FILE") does not exist!"
      LANG=${config.i18n.defaultLocale or "C"} ${ageBin} --decrypt "''${IDENTITIES[@]}" -o "$TMP_FILE" "${secretType.file}"
    )
    chmod ${secretType.mode} "$TMP_FILE"
    mv -f "$TMP_FILE" "$_truePath"
  '';

  # other interesting question: since the files are in ramfs and get generated on activation, does it ask for the ssh passphrase after reboot?
  installSecret = secretType: ''
    ${setTruePath secretType}
    ${setHash secretType.file "$_prevTruePath"}

    # if the file contains the hash it automatically means both encrypted and decrypted file must exist
    # (unless someone tampered with the hash list to only contain single file hashes, we'll ignore this for now but should maybe verify the hash length as well)
    # it might make sense to put the hash list in /var/lib/agenix so at least symlink=false files don't have to be decrypted again (if they aren't on ramfs)
    if [ -n "$_hash" ] && (grep -q -x -F "$_hash" "${cfg.secretsMountPoint}/hashes-$_prev_generation"); then
      ${if secretType.symlink then ''
        # no -f because the file SHOULD NOT exist (since we ignore symlink=false)
        echo "[agenix] copying unchanged decrypted file from '$_prevTruePath' to '$_truePath'"
        cp "$_prevTruePath" "$_truePath"
      '' else ''
        echo "[agenix] keeping unchanged decrypted file: $_truePath"
      ''}
    else
      ${decryptToNewGeneration secretType}
      ${setHash secretType.file "$_truePath"}
    fi

    ${optionalString secretType.symlink ''
      [ "${secretType.path}" != "${cfg.secretsDir}/${secretType.name}" ] && ln -sfT "${cfg.secretsDir}/${secretType.name}" "${secretType.path}"
    ''}

    if [ -n "$_hash" ]; then
      echo "$_hash" >> "${cfg.secretsMountPoint}/hashes-$_agenix_generation"
    fi
  '';

  testIdentities =
    map
    (path: ''
      test -f ${path} || echo '[agenix] WARNING: config.age.identityPaths entry ${path} not present!'
    '')
    cfg.identityPaths;

  cleanupAndLink = ''
    echo "[agenix] symlinking new secrets to ${cfg.secretsDir} (generation $_agenix_generation)..."
    ln -sfT "${cfg.secretsMountPoint}/$_agenix_generation" ${cfg.secretsDir}

    (( _agenix_generation > 1 )) && {
      echo "[agenix] removing old secrets (generation $_prev_generation)..."
      rm -rf "${cfg.secretsMountPoint}/$_prev_generation"
      rm -rf "${cfg.secretsMountPoint}/hashes-$_prev_generation"
    }
  '';

  installSecrets = builtins.concatStringsSep "\n" (
    ["echo '[agenix] decrypting secrets...'"]
    ++ testIdentities
    ++ (map installSecret (builtins.attrValues cfg.secrets))
    ++ [cleanupAndLink]
  );

  chownSecret = secretType: ''
    ${setTruePath secretType}
    chown ${secretType.owner}:${secretType.group} "$_truePath"
  '';

  chownSecrets = builtins.concatStringsSep "\n" (
    ["echo '[agenix] chowning...'"]
    ++ [chownMountPoint]
    ++ (map chownSecret (builtins.attrValues cfg.secrets))
  );

  secretType = types.submodule ({config, ...}: {
    options = {
      name = mkOption {
        type = types.str;
        default = config._module.args.name;
        defaultText = literalExpression "config._module.args.name";
        description = ''
          Name of the file used in {option}`age.secretsDir`
        '';
      };
      file = mkOption {
        type = types.path;
        description = ''
          Age file the secret is loaded from.
        '';
      };
      path = mkOption {
        type = types.str;
        default = "${cfg.secretsDir}/${config.name}";
        defaultText = literalExpression ''
          "''${cfg.secretsDir}/''${config.name}"
        '';
        description = ''
          Path where the decrypted secret is installed.
        '';
      };
      mode = mkOption {
        type = types.str;
        default = "0400";
        description = ''
          Permissions mode of the decrypted secret in a format understood by chmod.
        '';
      };
      owner = mkOption {
        type = types.str;
        default = "0";
        description = ''
          User of the decrypted secret.
        '';
      };
      group = mkOption {
        type = types.str;
        default = users.${config.owner}.group or "0";
        defaultText = literalExpression ''
          users.''${config.owner}.group or "0"
        '';
        description = ''
          Group of the decrypted secret.
        '';
      };
      symlink = mkEnableOption "symlinking secrets to their destination" // {default = true;};
    };
  });
in {
  imports = [
    (mkRenamedOptionModule ["age" "sshKeyPaths"] ["age" "identityPaths"])
  ];

  options.age = {
    ageBin = mkOption {
      type = types.str;
      default = "${pkgs.age}/bin/age";
      defaultText = literalExpression ''
        "''${pkgs.age}/bin/age"
      '';
      description = ''
        The age executable to use.
      '';
    };
    secrets = mkOption {
      type = types.attrsOf secretType;
      default = {};
      description = ''
        Attrset of secrets.
      '';
    };
    secretsDir = mkOption {
      type = types.path;
      default = "/run/agenix";
      description = ''
        Folder where secrets are symlinked to
      '';
    };
    secretsMountPoint = mkOption {
      type =
        types.addCheck types.str
        (s:
          (builtins.match "[ \t\n]*" s)
          == null # non-empty
          && (builtins.match ".+/" s) == null) # without trailing slash
        // {description = "${types.str.description} (with check: non-empty without trailing slash)";};
      default = "/run/agenix.d";
      description = ''
        Where secrets are created before they are symlinked to {option}`age.secretsDir`
      '';
    };
    identityPaths = mkOption {
      type = types.listOf types.path;
      default =
        if (config.services.openssh.enable or false)
        then map (e: e.path) (lib.filter (e: e.type == "rsa" || e.type == "ed25519") config.services.openssh.hostKeys)
        else if isDarwin
        then [
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_rsa_key"
        ]
        else [];
      defaultText = literalExpression ''
        if (config.services.openssh.enable or false)
        then map (e: e.path) (lib.filter (e: e.type == "rsa" || e.type == "ed25519") config.services.openssh.hostKeys)
        else if isDarwin
        then [
          "/etc/ssh/ssh_host_ed25519_key"
          "/etc/ssh/ssh_host_rsa_key"
        ]
        else [];
      '';
      description = ''
        Path to SSH keys to be used as identities in age decryption.
      '';
    };
  };

  config = mkIf (cfg.secrets != {}) (mkMerge [
    {
      assertions = [
        {
          assertion = cfg.identityPaths != [];
          message = "age.identityPaths must be set.";
        }
      ];
    }

    (optionalAttrs (!isDarwin) {
      # Create a new directory full of secrets for symlinking (this helps
      # ensure removed secrets are actually removed, or at least become
      # invalid symlinks).
      system.activationScripts.agenixNewGeneration = {
        text = newGeneration;
        deps = [
          "specialfs"
        ];
      };

      system.activationScripts.agenixInstall = {
        text = installSecrets;
        deps = [
          "agenixNewGeneration"
          "specialfs"
        ];
      };

      # So user passwords can be encrypted.
      system.activationScripts.users.deps = ["agenixInstall"];

      # Change ownership and group after users and groups are made.
      system.activationScripts.agenixChown = {
        text = chownSecrets;
        deps = [
          "users"
          "groups"
        ];
      };

      # So other activation scripts can depend on agenix being done.
      system.activationScripts.agenix = {
        text = "";
        deps = ["agenixChown"];
      };
    })
    (optionalAttrs isDarwin {
      launchd.daemons.activate-agenix = {
        script = ''
          set -e
          set -o pipefail
          export PATH="${pkgs.gnugrep}/bin:${pkgs.coreutils}/bin:@out@/sw/bin:/usr/bin:/bin:/usr/sbin:/sbin"
          ${newGeneration}
          ${installSecrets}
          ${chownSecrets}
          exit 0
        '';
        serviceConfig = {
          RunAtLoad = true;
          KeepAlive.SuccessfulExit = false;
        };
      };
    })
  ]);
}
