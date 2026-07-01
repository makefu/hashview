{ lib
, stdenvNoCC
, makeWrapper
, patchedSrc
, python
, pythonDeps
, gzip
, gnutar
, openssl
, coreutils
}:

let
  pythonEnv = python.withPackages pythonDeps;
  # Runtime shell-outs: gzip/gunzip (rule+wordlist seeding, agent tarball),
  # tar (agent download), openssl (self-signed cert if the module opts into TLS).
  runtimePath = lib.makeBinPath [ gzip gnutar openssl coreutils ];
in
stdenvNoCC.mkDerivation {
  pname = "hashview-web";
  version = "0.8.2";

  src = patchedSrc;

  nativeBuildInputs = [ makeWrapper ];

  # No build step - copy the (already patched) app tree into the store, then
  # wrap the entrypoint. The app is NOT relocatable: it reads config/ssl/control
  # via both CWD-relative paths AND Flask's current_app.root_path (= the imported
  # package dir). So the wrapper runs "hashview.py" *relative* to the caller's
  # CWD (no PYTHONPATH into the store), forcing `import hashview` to resolve to
  # the working-tree copy the NixOS module stages - keeping root_path writable.
  installPhase = ''
    runHook preInstall

    mkdir -p $out/share/hashview
    cp -r hashview migrations install hashview.py $out/share/hashview/

    makeWrapper ${pythonEnv}/bin/python $out/bin/hashview-web \
      --add-flags "hashview.py" \
      --prefix PATH : "${runtimePath}"

    runHook postInstall
  '';

  # appDir is "$out/share/hashview"; consumers reference ${package}/share/hashview.
  passthru = { inherit pythonEnv; };

  meta = {
    description = "Hashview web server";
    mainProgram = "hashview-web";
  };
}
