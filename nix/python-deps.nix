# Python package-set overrides: add the runtime deps that are absent from
# nixpkgs. Everything else (Flask stack, SQLAlchemy 2.x, mysql-connector) comes
# straight from nixpkgs - the app is upgraded to match those versions rather
# than pinned to its historical requirements.txt.
self: super: {

  # flask-apscheduler only entered nixpkgs after the 25.05/26.05 releases, so
  # package it here to keep the module buildable on those stable channels.
  flask-apscheduler = self.buildPythonPackage rec {
    pname = "Flask-APScheduler";
    version = "1.13.1";
    format = "setuptools";
    src = self.fetchPypi {
      inherit pname version;
      sha256 = "1nh7ssdr8dqdplamfqh8dmfbfy6sfpyf9c30cfvkkcvg09pq8adr";
    };
    propagatedBuildInputs = with self; [ flask apscheduler python-dateutil ];
    doCheck = false;
    pythonImportsCheck = [ "flask_apscheduler" ];
  };

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
