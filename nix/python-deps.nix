# Python package-set overrides: add the two runtime deps that are absent from
# nixpkgs. Everything else (Flask stack, SQLAlchemy 2.x, mysql-connector) comes
# straight from nixpkgs - the app is upgraded to match those versions rather
# than pinned to its historical requirements.txt.
self: super: {

  bcrypt-flask = self.buildPythonPackage rec {
    pname = "Bcrypt-Flask";
    version = "1.0.2";
    format = "setuptools";
    src = self.fetchPypi {
      inherit pname version;
      sha256 = "689044bbc7654e5b3db6928e54851be2b519e76a6851dfa344a9a18ab39fc1f2";
    };
    propagatedBuildInputs = [ self.bcrypt self.flask ];
    doCheck = false;
    pythonImportsCheck = [ "flask_bcrypt" ];
  };

  transliterate = self.buildPythonPackage rec {
    pname = "transliterate";
    version = "1.10.2";
    format = "setuptools";
    src = self.fetchPypi {
      inherit pname version;
      sha256 = "bc608e0d48e687db9c2b1d7ea7c381afe0d1849cad216087d8e03d8d06a57c85";
    };
    propagatedBuildInputs = [ self.six ];
    doCheck = false;
    pythonImportsCheck = [ "transliterate" ];
  };
}
