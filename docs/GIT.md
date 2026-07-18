
Git
Initialisation
cd /root/saas_factory
bash scripts/git-init-safe.sh
Ajouter un remote GitHub
cd /root/saas_factory
git remote add origin git@github.com:Krohler06/saas-factory-agents.git
git branch -M main
git push -u origin main
Ne jamais commiter
exports/
.env
.env.private
credentials.encrypted.json
credentials.decrypted.json
*.tgz
logs/
data/
Vérification avant commit
bash scripts/scan-secrets.sh

