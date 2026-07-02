final: prev:
let
  lib = final.lib;

  # Hashview source, shared by the packages and every test tier.
  #
  # All the environment/headless/test hooks and the command-injection fix that
  # used to be injected here now live directly in the source tree as individual
  # commits (proposed upstream), so this is a plain clean checkout.
  patchedSrc = lib.cleanSource ../.;

  hashviewPython = final.python3.override {
    self = hashviewPython;
    packageOverrides = import ./python-deps.nix { inherit lib; };
  };

  runtimePyDeps = ps: with ps; [
    flask
    flask-wtf
    flask-sqlalchemy
    flask-login
    flask-mail
    flask-migrate
    flask-apscheduler
    wtforms-sqlalchemy
    email-validator
    packaging
    authlib
    requests
    mysql-connector
    bcrypt-flask
    transliterate
  ];

  agentPyDeps = ps: with ps; [ psutil requests ];

  testPyDeps = ps: (runtimePyDeps ps) ++ (with ps; [
    pytest
    pytest-base-url
    pytest-playwright
    playwright
  ]);

in
{
  inherit patchedSrc hashviewPython;

  hashviewRuntimePython = hashviewPython.withPackages runtimePyDeps;
  hashviewTestPython = hashviewPython.withPackages testPyDeps;

  hashview-web = final.callPackage ./hashview-web.nix {
    inherit patchedSrc;
    python = hashviewPython;
    pythonDeps = runtimePyDeps;
  };

  hashview-agent = final.callPackage ./hashview-agent.nix {
    inherit patchedSrc;
    python = hashviewPython;
    pythonDeps = agentPyDeps;
  };
}
