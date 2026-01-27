set -euxo pipefail
echo "RUNCOMMAND_OK"
sudo systemctl status fastapi --no-pager || true
sudo ss -lntp | grep 8000 || true
curl -sS -m 3 http://127.0.0.1:8000/health || true
