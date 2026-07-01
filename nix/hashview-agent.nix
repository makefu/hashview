{ lib
, stdenvNoCC
, makeWrapper
, patchedSrc
, python
, pythonDeps
, gzip
, coreutils
}:

let
  pythonEnv = python.withPackages pythonDeps;
  # Agent shells out to gunzip/mv/tee for rule+wordlist sync; hashcat itself is
  # referenced by absolute path (HC_BIN_PATH) from the module, not via PATH.
  runtimePath = lib.makeBinPath [ gzip coreutils ];
in
stdenvNoCC.mkDerivation {
  pname = "hashview-agent";
  version = "0.8.2";

  src = patchedSrc;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p $out/share
    cp -r install/hashview-agent $out/share/hashview-agent

    makeWrapper ${pythonEnv}/bin/python $out/bin/hashview-agent \
      --add-flags "$out/share/hashview-agent/hashview-agent.py" \
      --prefix PATH : "${runtimePath}" \
      --prefix PYTHONPATH : "$out/share/hashview-agent"

    runHook postInstall
  '';

  passthru = { inherit pythonEnv; };

  meta = {
    description = "Hashview cracking agent";
    mainProgram = "hashview-agent";
  };
}
