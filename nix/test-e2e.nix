# E2E tier: install the module in its default shape and crack MD5("root")
# end-to-end (web + local agent + local MySQL), driven entirely over HTTP with
# curl. Proves the packaged app, module wiring, and agent/hashcat path all work.
{ pkgs, self }:

let
  md5root = "63a9f0ea7bb98050796b649e85481845"; # md5("root")

  # The whole crack flow as one curl script (cookie jar + flask-wtf CSRF).
  crackFlow = pkgs.writeShellScript "hashview-crack-flow" ''
    # NOTE: no `pipefail` on purpose - the scrape helpers use `grep ... | head`,
    # and a no-match grep in a pipeline must yield an empty string (so retry
    # loops and `test -n` guards run) rather than aborting under `set -e`.
    set -eu
    curl=${pkgs.curl}/bin/curl
    B=http://127.0.0.1:5000
    J=$(mktemp)
    P=$(mktemp)
    ADMIN_PW=cracktheplanet1   # >= 14 chars (setup form requires it)

    get() { "$curl" -s -c "$J" -b "$J" "$B$1" -o "$P"; }
    csrf() { grep -oP 'name="csrf_token"[^>]*value="\K[^"]+' "$P" | head -1; }
    # POST form; echoes the resulting redirect Location (empty if none).
    post() { local path="$1"; shift; "$curl" -s -c "$J" -b "$J" -o /dev/null \
      -w '%{redirect_url}' -X POST "$B$path" "$@"; }

    echo "[*] first-run: admin password"
    get /setup/admin-pass
    post /setup/admin-pass \
      --data-urlencode "first_name=Admin" \
      --data-urlencode "last_name=User" \
      --data-urlencode "email_address=admin@example.com" \
      --data-urlencode "password=$ADMIN_PW" \
      --data-urlencode "confirm_password=$ADMIN_PW" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Update" >/dev/null

    echo "[*] first-run: settings"
    get /setup/settings
    post /setup/settings \
      --data-urlencode "retention_period=30" \
      --data-urlencode "max_runtime_tasks=0" \
      --data-urlencode "max_runtime_jobs=0" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Save" >/dev/null

    echo "[*] login"
    get /login
    post /login \
      --data-urlencode "email=admin@example.com" \
      --data-urlencode "password=$ADMIN_PW" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Crack the planet!" >/dev/null

    echo "[*] upload tiny wordlist containing root"
    printf 'root\npassword\n123456\n' > /tmp/e2eroot.txt
    get /wordlists/add
    post /wordlists/add \
      -F "name=e2eroot" \
      -F "wordlist=@/tmp/e2eroot.txt" \
      -F "csrf_token=$(csrf)" \
      -F "submit=upload" >/dev/null

    echo "[*] create MD5 dictionary task pointed at that wordlist"
    get /tasks/add
    WLID=$(grep -oP 'value="\K[0-9]+(?=">e2eroot<)' "$P" | head -1)
    test -n "$WLID" || { echo "FAIL: wordlist id not found"; exit 1; }
    # wl_id_2 is a SelectField with choices and no Optional validator, so it
    # must carry a valid value even for a straight (attackmode 0) task.
    post /tasks/add \
      --data-urlencode "name=e2etask" \
      --data-urlencode "hc_attackmode=0" \
      --data-urlencode "wl_id=$WLID" \
      --data-urlencode "wl_id_2=$WLID" \
      --data-urlencode "rule_id=None" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Create" >/dev/null

    echo "[*] create job (+ new customer)"
    get /jobs/add
    loc=$(post /jobs/add \
      --data-urlencode "name=e2ejob" \
      --data-urlencode "priority=3" \
      --data-urlencode "customer_id=add_new" \
      --data-urlencode "customer_name=e2ecust" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Next")
    JID=$(echo "$loc" | grep -oP '/jobs/\K[0-9]+')
    test -n "$JID" || { echo "FAIL: job id not found"; exit 1; }
    echo "    job id=$JID"

    echo "[*] add hashfile with md5(root)"
    get "/jobs/$JID/assigned_hashfile/"
    # The unused per-format hash_type selects still validate; pass an empty
    # value (the valid --SELECT-- choice) so validate_on_submit accepts the form.
    loc=$(post "/jobs/$JID/assigned_hashfile/" \
      -F "file_type=hash_only" \
      -F "hash_type=0" \
      -F "shadow_hash_type=" \
      -F "pwdump_hash_type=" \
      -F "netntlm_hash_type=" \
      -F "kerberos_hash_type=" \
      -F "name=e2ehashes" \
      -F "hashfilehashes=${md5root}" \
      -F "csrf_token=$(csrf)" \
      -F "submit=Next")
    HFID=$(echo "$loc" | grep -oP '/assigned_hashfile/\K[0-9]+')
    test -n "$HFID" || { echo "FAIL: hashfile not created"; exit 1; }
    echo "    hashfile id=$HFID"

    echo "[*] notifications (none)"
    get "/jobs/$JID/notifications"
    post "/jobs/$JID/notifications" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Next" >/dev/null

    echo "[*] assign task by name"
    get "/jobs/$JID/tasks"
    TID=$(grep -oP "/jobs/$JID/assign_task/\K[0-9]+(?=\">e2etask<)" "$P" | head -1)
    test -n "$TID" || { echo "FAIL: task assign link not found"; exit 1; }
    get "/jobs/$JID/assign_task/$TID"

    echo "[*] finalize (summary)"
    get "/jobs/$JID/summary"
    post "/jobs/$JID/summary" \
      --data-urlencode "csrf_token=$(csrf)" \
      --data-urlencode "submit=Complete" >/dev/null

    echo "[*] wait for agent to register, then authorize it"
    AID=""
    for i in $(seq 1 40); do
      get /agents
      AID=$(grep -oP '/agents/\K[0-9]+(?=/authorize)' "$P" | head -1 || true)
      [ -n "$AID" ] && break
      sleep 3
    done
    test -n "$AID" || { echo "FAIL: agent never registered"; exit 1; }
    # Authorize every pending agent (there should be exactly one).
    for a in $(grep -oP '/agents/\K[0-9]+(?=/authorize)' "$P"); do
      echo "    authorizing agent $a"
      get "/agents/$a/authorize"
    done

    echo "[*] start the job"
    get "/jobs/start/$JID"

    echo "[*] poll search until plaintext 'root' is recovered"
    for i in $(seq 1 50); do
      # Search by the ciphertext; the results table hex-decodes the plaintext,
      # so a recovered hash renders 'root' in a cell.
      get /search
      "$curl" -s -c "$J" -b "$J" -o "$P" -X POST "$B/search" \
        --data-urlencode "search_type=hash" \
        --data-urlencode "query=${md5root}" \
        --data-urlencode "export_type=Colon" \
        --data-urlencode "csrf_token=$(csrf)" \
        --data-urlencode "submit=Search"
      # The plaintext cell renders 'root' on its own line (grep is line-based).
      if grep -qiE '^[[:space:]]*root[[:space:]]*$' "$P"; then
        echo "[+] SUCCESS: cracked root"
        exit 0
      fi
      sleep 5
    done
    echo "FAIL: hash not cracked in time"
    exit 1
  '';

in
pkgs.testers.runNixOSTest {
  name = "hashview-e2e";

  # Exercise the minimal running configuration (socket auth, no passwordFile).
  nodes.machine = { ... }: {
    imports = [ self.nixosModules.default ./minimal.nix ];
    virtualisation.memorySize = 4096;
    virtualisation.cores = 4;
    virtualisation.diskSize = 8192;
  };

  testScript = ''
    machine.start()
    machine.wait_for_unit("hashview-web.service")
    machine.wait_for_unit("hashview-agent.service")
    machine.wait_until_succeeds("curl -sf http://127.0.0.1:5000/login", timeout=180)
    status, out = machine.execute("${crackFlow} 2>&1", timeout=400)
    print(out)
    if status != 0:
        print(machine.succeed("journalctl -u hashview-agent -u hashview-web --no-pager | tail -n 60"))
        raise Exception("crack flow failed (status %d)" % status)
  '';
}
