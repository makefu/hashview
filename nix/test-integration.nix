# Integration tier: run the upstream Playwright e2e suite (tests/e2e/*) against
# a live, module-managed Hashview server (real MySQL), headless chromium.
{ pkgs, self }:

pkgs.testers.runNixOSTest {
  name = "hashview-integration";

  nodes.machine = { ... }: {
    imports = [ self.nixosModules.default ];

    services.hashview = {
      enable = true;
      # Local agent not needed for the Playwright suite; keep it off to speed up.
      agent.enable = false;
      database = {
        createLocally = true;
        passwordFile = "/etc/hashview/db-password";
      };
    };

    environment.etc."hashview/db-password".text = "integrationtestpw";

    virtualisation.memorySize = 4096;
    virtualisation.diskSize = 8192;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("mysql.service")
    machine.wait_for_unit("hashview-web.service")
    machine.wait_for_open_port(5000)
    # create_app boots the schema (alembic) + seeds defaults before app.run;
    # wait until the login page actually answers.
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:5000/login", timeout=180)

    machine.succeed("cp -r ${pkgs.patchedSrc} /tmp/src && chmod -R u+w /tmp/src")

    print(machine.succeed(
        "cd /tmp/src && "
        "HOME=/tmp "
        # test_agent_sim spawns `python tests/agent/sim.py`, so put the test
        # python env on PATH.
        "PATH=${pkgs.hashviewTestPython}/bin:$PATH "
        "HASHVIEW_E2E_BASE_URL=http://127.0.0.1:5000 "
        "PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers} "
        "PLAYWRIGHT_SKIP_VALIDATE_HOST_REQUIREMENTS=1 "
        "${pkgs.hashviewTestPython}/bin/python -m pytest -m e2e -p no:cacheprovider "
        # These three upstream tests use an ambiguous get_by_role('button',
        # name='Next') locator on the hashfile-upload page, which legitimately
        # has two 'Next' buttons (paste-hashes vs existing-hashfile forms) -> a
        # Playwright strict-mode violation unrelated to packaging.
        "--deselect 'tests/e2e/test_quality.py::test_hashfile_upload_example_file' "
        "--deselect 'tests/e2e/test_quality.py::test_hashfile_upload_example_pwdump' "
        "--deselect 'tests/e2e/test_quality.py::test_hashfile_validation_rejects_invalid_hash' "
        "tests/e2e -vv --no-header 2>&1",
        timeout=300,
    ))
  '';
}
